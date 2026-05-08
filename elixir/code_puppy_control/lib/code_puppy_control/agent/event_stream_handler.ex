defmodule CodePuppyControl.Agent.EventStreamHandler do
  @moduledoc """
  UI streaming bridge for the main agent.

  Processes canonical stream events from an agent run, publishing them
  to the EventBus for TUI/WebSocket consumers and firing `stream_event`
  callbacks for plugins.

  ## Design

  This GenServer replaces the Python `event_stream_handler.py`'s
  async function with an Elixir-native process. Key differences:

  - **EventBus replaces Rich console** — Instead of writing to a Rich
    Console, events are published via PubSub so TUI and WebSocket
    subscribers receive them.
  - **Process state replaces module globals** — Stream state (line count,
    banner tracking, text buffers) lives in the GenServer state rather
    than module-level variables.
  - **Batched callback delivery** — Events are batched before firing
    `stream_event` callbacks to reduce process message overhead.

  ## Usage

      # Start a handler for an agent run
      {:ok, pid} = EventStreamHandler.start_link(
        run_id: "run-123",
        session_id: "session-456"
      )

      # Feed canonical stream events
      EventStreamHandler.push(pid, %TextDelta{index: 0, text: "Hello"})
      EventStreamHandler.push(pid, %TextEnd{index: 0, id: nil})

      # Drain remaining events and stop
      EventStreamHandler.drain(pid)

  Port of `code_puppy/agents/event_stream_handler.py`.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.{Callbacks, EventBus}
  alias CodePuppyControl.Stream.{Event, EventNormalizer}

  # Flush the callback batch when it reaches this size
  @stream_flush_interval 50
  # Flush text content when buffer exceeds this many characters
  @text_flush_char_threshold 80

  # ── State ──────────────────────────────────────────────────────────

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          session_id: String.t() | nil,
          # Part tracking
          streaming_parts: MapSet.t(non_neg_integer()),
          thinking_parts: MapSet.t(non_neg_integer()),
          text_parts: MapSet.t(non_neg_integer()),
          tool_parts: MapSet.t(non_neg_integer()),
          banner_printed: MapSet.t(non_neg_integer()),
          # Text buffering: index → list of chunks
          text_buffers: %{non_neg_integer() => [String.t()]},
          # Tool tracking: index → token count
          token_count: %{non_neg_integer() => non_neg_integer()},
          # Tool tracking: index → tool name
          tool_names: %{non_neg_integer() => String.t()},
          # Stream state for UI coordination
          did_stream_text: boolean(),
          streamed_line_count: non_neg_integer(),
          # Batched callback events
          pending_events: [{String.t(), map(), String.t() | nil}]
        }

  defstruct [
    :run_id,
    :session_id,
    streaming_parts: MapSet.new(),
    thinking_parts: MapSet.new(),
    text_parts: MapSet.new(),
    tool_parts: MapSet.new(),
    banner_printed: MapSet.new(),
    text_buffers: %{},
    token_count: %{},
    tool_names: %{},
    did_stream_text: false,
    streamed_line_count: 0,
    pending_events: []
  ]

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Starts the event stream handler.

  ## Options

    * `:run_id` — Run identifier for EventBus routing
    * `:session_id` — Session identifier for EventBus routing
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Pushes a canonical stream event to the handler for processing.
  """
  @spec push(pid(), Event.canonical()) :: :ok
  def push(pid, event) do
    GenServer.cast(pid, {:push, event})
  end

  @doc """
  Returns the current stream state and resets it.

  Returns `{did_stream, line_count}` for coordination with the
  message renderer — the renderer uses line_count to erase
  streamed lines before re-rendering as markdown.
  """
  @spec get_stream_state(pid()) :: {boolean(), non_neg_integer()}
  def get_stream_state(pid) do
    GenServer.call(pid, :get_stream_state)
  end

  @doc """
  Drains any pending batched callback events and stops the handler.
  """
  @spec drain(pid()) :: :ok
  def drain(pid) do
    GenServer.call(pid, :drain)
  end

  @doc """
  Sets the streaming console reference (no-op in Elixir — kept for API
  compatibility; UI rendering happens via EventBus subscribers).
  """
  @spec set_streaming_console(pid(), term()) :: :ok
  def set_streaming_console(_pid, _console), do: :ok

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %__MODULE__{
      run_id: Keyword.get(opts, :run_id),
      session_id: Keyword.get(opts, :session_id)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    state = process_event(event, state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_stream_state, _from, state) do
    result = {state.did_stream_text, state.streamed_line_count}
    state = %{state | did_stream_text: false, streamed_line_count: 0}
    {:reply, result, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    # Flush any remaining batched events
    state = flush_pending_events(state)
    {:stop, :normal, :ok, state}
  end

  # ── Event Processing ────────────────────────────────────────────────

  defp process_event(%Event.TextStart{index: idx} = event, state) do
    fire_callback(
      "part_start",
      %{
        "index" => idx,
        "part_type" => "TextPart",
        "part" => event
      },
      state
    )

    state
    |> add_to_set(:streaming_parts, idx)
    |> add_to_set(:text_parts, idx)
    |> put_text_buffer(idx, [])
    |> maybe_emit_thinking_banner(event, "TextPart")
  end

  defp process_event(%Event.TextDelta{index: idx, text: text} = _event, state) do
    fire_callback(
      "part_delta",
      %{
        "index" => idx,
        "delta_type" => "TextPartDelta",
        "delta" => %{content_delta: text}
      },
      state
    )

    # Only process if this is a tracked text part
    if MapSet.member?(state.text_parts, idx) do
      state
      |> maybe_emit_response_banner(idx)
      |> append_text_buffer(idx, text)
      |> maybe_flush_text_buffer(idx)
    else
      state
    end
  end

  defp process_event(%Event.TextEnd{index: idx} = _event, state) do
    fire_callback(
      "part_end",
      %{
        "index" => idx,
        "next_part_kind" => nil
      },
      state
    )

    # Flush any remaining buffered content
    state = flush_remaining_text_buffer(state, idx)

    # Add trailing newline if we printed a banner (i.e., had content)
    state =
      if MapSet.member?(state.banner_printed, idx) do
        %{state | streamed_line_count: state.streamed_line_count + 1}
      else
        state
      end

    # Publish text end via EventBus for UI subscribers
    if MapSet.member?(state.banner_printed, idx) do
      EventBus.broadcast_text(
        state.run_id || "",
        state.session_id,
        "\n",
        chunk: true,
        store: false
      )
    end

    cleanup_part(state, idx)
  end

  defp process_event(%Event.ThinkingStart{index: idx} = event, state) do
    fire_callback(
      "part_start",
      %{
        "index" => idx,
        "part_type" => "ThinkingPart",
        "part" => event
      },
      state
    )

    state
    |> add_to_set(:streaming_parts, idx)
    |> add_to_set(:thinking_parts, idx)
    |> emit_thinking_event()
  end

  defp process_event(%Event.ThinkingDelta{index: idx, text: text} = _event, state) do
    fire_callback(
      "part_delta",
      %{
        "index" => idx,
        "delta_type" => "ThinkingPartDelta",
        "delta" => %{content_delta: text}
      },
      state
    )

    if MapSet.member?(state.thinking_parts, idx) do
      emit_thinking_delta_event(state, text)
    else
      state
    end
  end

  defp process_event(%Event.ThinkingEnd{index: idx} = _event, state) do
    fire_callback(
      "part_end",
      %{
        "index" => idx,
        "next_part_kind" => nil
      },
      state
    )

    # Print newline after thinking (if banner was printed)
    state =
      if MapSet.member?(state.banner_printed, idx) do
        %{state | streamed_line_count: state.streamed_line_count + 1}
      else
        state
      end

    cleanup_part(state, idx)
  end

  defp process_event(%Event.ToolCallStart{index: idx, name: name} = event, state) do
    fire_callback(
      "part_start",
      %{
        "index" => idx,
        "part_type" => "ToolCallPart",
        "tool_name" => name,
        "part" => event
      },
      state
    )

    state
    |> add_to_set(:streaming_parts, idx)
    |> add_to_set(:tool_parts, idx)
    |> add_to_set(:banner_printed, idx)
    |> put_tool_name(idx, name || "")
    |> put_token_count(idx, 0)
    |> emit_tool_call_start_event(name)
  end

  defp process_event(%Event.ToolCallArgsDelta{index: idx, arguments: args} = _event, state) do
    fire_callback(
      "part_delta",
      %{
        "index" => idx,
        "delta_type" => "ToolCallArgsDelta",
        "delta" => %{args_delta: args}
      },
      state
    )

    if MapSet.member?(state.tool_parts, idx) do
      # Estimate tokens from args content: rough heuristic, 4 chars ≈ 1 token
      estimated_tokens = max(1, div(byte_size(args || ""), 4))
      current = Map.get(state.token_count, idx, 0)
      new_count = current + estimated_tokens

      tool_name = Map.get(state.tool_names, idx, "")

      # Publish progress via EventBus
      EventBus.broadcast_status(
        state.run_id || "",
        state.session_id,
        "tool_calling",
        metadata: %{
          tool_name: tool_name,
          token_count: new_count,
          index: idx
        }
      )

      %{state | token_count: Map.put(state.token_count, idx, new_count)}
    else
      state
    end
  end

  defp process_event(%Event.ToolCallEnd{index: idx, name: name} = event, state) do
    fire_callback(
      "part_end",
      %{
        "index" => idx,
        "next_part_kind" => nil,
        "tool_name" => name
      },
      state
    )

    # Publish tool call completion via EventBus
    EventBus.broadcast_tool_result(
      state.run_id || "",
      state.session_id,
      name || "",
      %{"completed" => true, "index" => idx},
      tool_call_id: event.id
    )

    cleanup_part(state, idx)
  end

  defp process_event(%Event.UsageUpdate{} = usage, state) do
    fire_callback(
      "usage_update",
      %{
        "prompt_tokens" => usage.prompt_tokens,
        "completion_tokens" => usage.completion_tokens,
        "total_tokens" => usage.total_tokens
      },
      state
    )

    state
  end

  defp process_event(%Event.Done{} = done, state) do
    state =
      fire_callback(
        "done",
        %{
          "id" => done.id,
          "model" => done.model,
          "finish_reason" => done.finish_reason
        },
        state
      )

    # Flush any remaining batched events
    flush_pending_events(state)
  end

  defp process_event(_unknown, state) do
    state
  end

  # ── Part Cleanup ───────────────────────────────────────────────────

  defp cleanup_part(state, idx) do
    state
    |> remove_from_set(:streaming_parts, idx)
    |> remove_from_set(:thinking_parts, idx)
    |> remove_from_set(:text_parts, idx)
    |> remove_from_set(:tool_parts, idx)
    |> remove_from_set(:banner_printed, idx)
    |> then(fn s -> %{s | token_count: Map.delete(s.token_count, idx)} end)
    |> then(fn s -> %{s | tool_names: Map.delete(s.tool_names, idx)} end)
    |> then(fn s -> %{s | text_buffers: Map.delete(s.text_buffers, idx)} end)
  end

  # ── Set Helpers ─────────────────────────────────────────────────────

  defp add_to_set(state, field, idx) do
    Map.update!(state, field, &MapSet.put(&1, idx))
  end

  defp remove_from_set(state, field, idx) do
    Map.update!(state, field, &MapSet.delete(&1, idx))
  end

  # ── Text Buffering ──────────────────────────────────────────────────

  defp put_text_buffer(state, idx, buf) do
    %{state | text_buffers: Map.put(state.text_buffers, idx, buf)}
  end

  defp append_text_buffer(state, idx, text) do
    buffers = Map.update(state.text_buffers, idx, [text], &(&1 ++ [text]))
    %{state | text_buffers: buffers}
  end

  defp maybe_flush_text_buffer(state, idx) do
    case Map.get(state.text_buffers, idx) do
      nil ->
        state

      chunks ->
        buf = Enum.join(chunks)

        if String.contains?(buf, "\n") or byte_size(buf) > @text_flush_char_threshold do
          # Publish the buffered content via EventBus
          EventBus.broadcast_text(
            state.run_id || "",
            state.session_id,
            buf,
            chunk: true,
            store: false
          )

          # Count newlines
          line_count = state.streamed_line_count + count_newlines(buf)

          # Reset buffer
          %{
            state
            | streamed_line_count: line_count,
              text_buffers: Map.put(state.text_buffers, idx, [])
          }
        else
          state
        end
    end
  end

  defp flush_remaining_text_buffer(state, idx) do
    case Map.get(state.text_buffers, idx) do
      nil ->
        state

      [] ->
        state

      chunks ->
        buf = Enum.join(chunks)

        if buf != "" do
          EventBus.broadcast_text(
            state.run_id || "",
            state.session_id,
            buf,
            chunk: true,
            store: false
          )

          line_count = state.streamed_line_count + count_newlines(buf)

          %{
            state
            | streamed_line_count: line_count,
              text_buffers: Map.put(state.text_buffers, idx, [])
          }
        else
          state
        end
    end
  end

  defp count_newlines(str) do
    String.graphemes(str)
    |> Enum.count(&(&1 == "\n"))
  end

  # ── Banner Emission ────────────────────────────────────────────────

  defp maybe_emit_response_banner(state, idx) do
    if MapSet.member?(state.banner_printed, idx) do
      state
    else
      # First content for this text part — emit the response banner
      EventBus.broadcast_status(
        state.run_id || "",
        state.session_id,
        "agent_response",
        metadata: %{banner: true}
      )

      state
      |> add_to_set(:banner_printed, idx)
      |> Map.put(:did_stream_text, true)
      |> Map.put(:streamed_line_count, state.streamed_line_count + 2)
    end
  end

  # TextStart might have initial content — but we defer banner to first delta
  defp maybe_emit_thinking_banner(state, _event, _part_type), do: state

  defp emit_thinking_event(state) do
    # Publish thinking status via EventBus
    EventBus.broadcast_thinking(
      state.run_id || "",
      state.session_id,
      ""
    )

    state
  end

  defp emit_thinking_delta_event(state, text) do
    EventBus.broadcast_thinking(
      state.run_id || "",
      state.session_id,
      text
    )

    state
  end

  defp emit_tool_call_start_event(state, name) do
    EventBus.broadcast_tool_call(
      state.run_id || "",
      state.session_id,
      name || "",
      %{},
      tool_call_id: nil
    )

    state
  end

  # ── Tool Tracking ──────────────────────────────────────────────────

  defp put_tool_name(state, idx, name) do
    %{state | tool_names: Map.put(state.tool_names, idx, name)}
  end

  defp put_token_count(state, idx, count) do
    %{state | token_count: Map.put(state.token_count, idx, count)}
  end

  # ── Callback Firing ────────────────────────────────────────────────

  defp fire_callback(event_type, event_data, state) do
    # Normalize event data for consistent processing by downstream consumers
    normalized_data = EventNormalizer.normalize(event_type, event_data)
    session_id = state.session_id

    entry = {event_type, normalized_data, session_id}
    pending = state.pending_events ++ [entry]

    state = %{state | pending_events: pending}

    # Flush on part_end or when batch threshold reached
    if event_type == "part_end" or length(pending) >= @stream_flush_interval do
      flush_pending_events(state)
    else
      state
    end
  end

  defp flush_pending_events(%{pending_events: []} = state), do: state

  defp flush_pending_events(state) do
    batch = state.pending_events
    state = %{state | pending_events: []}

    # Fire callbacks asynchronously — don't block the handler
    spawn(fn ->
      Enum.each(batch, fn {event_type, event_data, session_id} ->
        try do
          Callbacks.trigger(:stream_event, [event_type, event_data, session_id])
        rescue
          e ->
            Logger.debug("Error flushing stream event: #{inspect(e)}")
        end
      end)
    end)

    state
  end
end
