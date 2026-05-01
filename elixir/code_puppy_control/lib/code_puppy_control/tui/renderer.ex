defmodule CodePuppyControl.TUI.Renderer do
  @moduledoc """
  Streaming terminal renderer backed by Owl.

  Subscribes to EventBus PubSub topics and renders canonical Stream.Event
  structs (and legacy EventBus maps) to the terminal with styled output:
  live streaming text, tool-call spinners, thinking blocks, and completion
  stats.

  ## Architecture

  The Renderer is a GenServer that subscribes to one or more PubSub topics
  (session, run, or global). It buffers text/thinking deltas and flushes
  them on newlines or size thresholds for responsive output — mirroring
  the Python StreamRenderer's buffering strategy.

  Rendering logic is split into focused submodules:

    * `Renderer.OwlOutput` — safe Owl.IO.puts, banners, spinners
    * `Renderer.EventMapper` — canonical wire format + legacy conversion
    * `Renderer.Buffer` — text/thinking buffer flush logic

  ## Usage

      # Start a renderer for a specific session
      {:ok, pid} = Renderer.start_link(session_id: "sess-123")

      # Or attach to a run
      {:ok, pid} = Renderer.start_link(run_id: "run-456")

      # Manually push a canonical Stream.Event struct
      Renderer.push(pid, %Event.TextDelta{index: 0, text: "Hello"})

      # Clean up
      Renderer.stop(pid)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.TUI.Markdown
  alias CodePuppyControl.TUI.Renderer.{Buffer, EventMapper, OwlOutput}

  # ── Constants ─────────────────────────────────────────────────────────────

  # Rate update throttle (5 Hz → 200ms)
  @rate_update_interval_ms 200

  # Default character count threshold before buffer is flushed to terminal
  @default_flush_threshold 20

  # ── State ──────────────────────────────────────────────────────────────────

  defstruct [
    :session_id,
    :run_id,
    :topics,
    # Tracking which part indices are active
    streaming_parts: MapSet.new(),
    thinking_parts: MapSet.new(),
    text_parts: MapSet.new(),
    tool_parts: MapSet.new(),
    # Track which indices have had banners printed
    banner_printed: MapSet.new(),
    # Buffered text per part index
    text_buffer: %{},
    # Buffered thinking per part index
    thinking_buffer: %{},
    # Token counting / rate
    token_count: 0,
    start_time: nil,
    # Spinner state
    spinner_ids: %{},
    loading_index: 0,
    # Rate throttle
    last_rate_update: 0,
    # Flush buffered text when it exceeds this character count
    flush_threshold: @default_flush_threshold
  ]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          topics: [String.t()],
          streaming_parts: MapSet.t(),
          thinking_parts: MapSet.t(),
          text_parts: MapSet.t(),
          tool_parts: MapSet.t(),
          banner_printed: MapSet.t(),
          text_buffer: %{non_neg_integer() => iolist()},
          thinking_buffer: %{non_neg_integer() => iolist()},
          token_count: non_neg_integer(),
          start_time: monotonic_time() | nil,
          spinner_ids: %{non_neg_integer() => reference()},
          loading_index: non_neg_integer(),
          last_rate_update: non_neg_integer(),
          flush_threshold: non_neg_integer()
        }

  @type monotonic_time :: integer()

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the renderer GenServer.

  ## Options

    * `:session_id` — subscribe to session topic
    * `:run_id` — subscribe to run topic
    * `:name` — GenServer name registration
    * `:subscribe_global` — subscribe to global topic when no session/run id
    * `:flush_threshold` — character count threshold before buffer is
       flushed to terminal (default: `#{@default_flush_threshold}`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Pushes a canonical Stream.Event struct directly into the renderer.
  """
  @spec push(GenServer.server(), Event.canonical()) :: :ok
  def push(server \\ __MODULE__, event) do
    GenServer.cast(server, {:push, event})
  end

  @doc """
  Signals that the streaming session is complete.

  Flushes remaining buffers and prints completion stats.
  """
  @spec finalize(GenServer.server()) :: :ok
  def finalize(server \\ __MODULE__) do
    GenServer.call(server, :finalize)
  end

  @doc """
  Resets internal state for a new streaming session.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc """
  Stops the renderer gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__) do
    GenServer.stop(server, :normal)
  end

  # ── Supervision ────────────────────────────────────────────────────────────

  @doc """
  Returns a child spec suitable for a Supervisor.

  The renderer is `:transient` — it won't restart unless it crashes
  abnormally.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :id, __MODULE__)
    init_args = Keyword.delete(opts, :id)

    %{
      id: id,
      start: {__MODULE__, :start_link, [init_args]},
      restart: :transient,
      type: :worker
    }
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id)
    run_id = Keyword.get(opts, :run_id)
    subscribe_global = Keyword.get(opts, :subscribe_global, false)

    state = %__MODULE__{
      session_id: session_id,
      run_id: run_id,
      start_time: System.monotonic_time(:millisecond),
      topics: [],
      flush_threshold: Keyword.get(opts, :flush_threshold, @default_flush_threshold)
    }

    state =
      state
      |> maybe_subscribe_session(session_id)
      |> maybe_subscribe_run(run_id)
      |> maybe_subscribe_global(subscribe_global, session_id, run_id)

    {:ok, state}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    state = handle_stream_event(event, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:event, event}, state) when is_map(event) do
    state =
      case EventMapper.event_to_canonical(event) do
        {:ok, canonical} -> handle_stream_event(canonical, state)
        :skip -> handle_eventbus_event(event, state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:finalize, _from, state) do
    state = do_finalize(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    Enum.each(state.spinner_ids, fn {_idx, ref} ->
      OwlOutput.stop_spinner(ref)
    end)

    {:reply, :ok,
     %__MODULE__{
       session_id: state.session_id,
       run_id: state.run_id,
       topics: state.topics,
       start_time: System.monotonic_time(:millisecond),
       flush_threshold: state.flush_threshold
     }}
  end

  # ── Stream.Event Handlers ─────────────────────────────────────────────────

  defp handle_stream_event(%Event.TextStart{index: idx}, state) do
    state = %{
      state
      | streaming_parts: MapSet.put(state.streaming_parts, idx),
        text_parts: MapSet.put(state.text_parts, idx),
        text_buffer: Map.put(state.text_buffer, idx, []),
        banner_printed: MapSet.put(state.banner_printed, idx)
    }

    OwlOutput.print_banner("AGENT RESPONSE", :blue, "💬")
    state
  end

  defp handle_stream_event(%Event.TextDelta{index: idx, text: text}, state) do
    state = %{state | token_count: state.token_count + 1}

    existing = Map.get(state.text_buffer, idx, [])
    state = %{state | text_buffer: Map.put(state.text_buffer, idx, existing ++ [text])}

    chunks = Map.get(state.text_buffer, idx, [])
    buf = IO.iodata_to_binary(chunks)

    if String.contains?(buf, "\n") or byte_size(buf) > state.flush_threshold do
      OwlOutput.owl_puts(Markdown.render(buf))
      state = %{state | text_buffer: Map.put(state.text_buffer, idx, [])}
      update_rate(state)
    else
      state
    end
  end

  defp handle_stream_event(%Event.TextEnd{index: idx}, state) do
    state = %{state | text_buffer: Buffer.flush_text_buffer(state.text_buffer, idx)}
    cleanup_part(state, idx)
  end

  defp handle_stream_event(%Event.ThinkingStart{index: idx}, state) do
    state = %{
      state
      | streaming_parts: MapSet.put(state.streaming_parts, idx),
        thinking_parts: MapSet.put(state.thinking_parts, idx),
        thinking_buffer: Map.put(state.thinking_buffer, idx, []),
        banner_printed: MapSet.put(state.banner_printed, idx)
    }

    OwlOutput.print_banner("THINKING", :yellow, "⚡")
    state
  end

  defp handle_stream_event(%Event.ThinkingDelta{index: idx, text: text}, state) do
    existing = Map.get(state.thinking_buffer, idx, [])
    %{state | thinking_buffer: Map.put(state.thinking_buffer, idx, existing ++ [text])}
  end

  defp handle_stream_event(%Event.ThinkingEnd{index: idx}, state) do
    chunks = Map.get(state.thinking_buffer, idx, [])

    if chunks != [] do
      text = IO.iodata_to_binary(chunks)
      OwlOutput.owl_puts(Owl.Data.tag(Markdown.render(text), :faint))
    end

    state = %{state | thinking_buffer: Map.put(state.thinking_buffer, idx, nil)}
    cleanup_part(state, idx)
  end

  defp handle_stream_event(%Event.ToolCallStart{index: idx, name: name}, state) do
    state = %{
      state
      | streaming_parts: MapSet.put(state.streaming_parts, idx),
        tool_parts: MapSet.put(state.tool_parts, idx),
        banner_printed: MapSet.put(state.banner_printed, idx)
    }

    OwlOutput.print_tool_banner(name)

    case OwlOutput.start_tool_spinner(state.loading_index, idx) do
      {ref, new_loading_index} ->
        %{
          state
          | spinner_ids: Map.put(state.spinner_ids, idx, ref),
            loading_index: new_loading_index
        }

      nil ->
        state
    end
  end

  defp handle_stream_event(%Event.ToolCallArgsDelta{}, state) do
    state
  end

  defp handle_stream_event(%Event.ToolCallEnd{index: idx, name: name}, state) do
    spinner_ids = OwlOutput.stop_tool_spinner(state.spinner_ids, idx)
    state = %{state | spinner_ids: spinner_ids}

    OwlOutput.owl_puts(Owl.Data.tag(" ✔ #{name}", :green))

    cleanup_part(state, idx)
  end

  defp handle_stream_event(%Event.UsageUpdate{}, state) do
    state
  end

  defp handle_stream_event(%Event.Done{}, state) do
    state
    |> Map.update!(:text_buffer, &Buffer.flush_all_text_buffers/1)
    |> Map.update!(:thinking_buffer, &Buffer.flush_all_thinking_buffers/1)
    |> then(fn s ->
      %{s | spinner_ids: OwlOutput.stop_all_spinners(s.spinner_ids)}
    end)
  end

  defp handle_stream_event(_event, state), do: state

  # ── EventBus Map Handlers ─────────────────────────────────────────────────

  defp handle_eventbus_event(%{type: "text", content: content}, state) do
    OwlOutput.owl_puts(Markdown.render(content))
    state
  end

  defp handle_eventbus_event(%{type: "agent_run_failed", error: error}, state) do
    OwlOutput.owl_puts(Owl.Data.tag("\u2716 Error: #{error}", :red))
    state
  end

  defp handle_eventbus_event(%{type: "status", status: status}, state) do
    OwlOutput.owl_puts(Owl.Data.tag(" #{status}", :faint))
    state
  end

  defp handle_eventbus_event(%{type: "thinking", content: content}, state) do
    OwlOutput.owl_puts(Owl.Data.tag(content, :faint))
    state
  end

  defp handle_eventbus_event(_event, state), do: state

  # ── Part Cleanup ──────────────────────────────────────────────────────────

  defp cleanup_part(state, idx) do
    %{
      state
      | streaming_parts: MapSet.delete(state.streaming_parts, idx),
        thinking_parts: MapSet.delete(state.thinking_parts, idx),
        text_parts: MapSet.delete(state.text_parts, idx),
        tool_parts: MapSet.delete(state.tool_parts, idx)
    }
  end

  # ── Rate Tracking ─────────────────────────────────────────────────────────

  defp update_rate(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.last_rate_update >= @rate_update_interval_ms do
      # TODO(prg-3): Phase 2 — wire rate to a status bar / Owl.LiveScreen block
      %{state | last_rate_update: now}
    else
      state
    end
  end

  # ── Finalization ──────────────────────────────────────────────────────────

  defp do_finalize(state) do
    text_buffer = Buffer.flush_all_text_buffers(state.text_buffer)
    thinking_buffer = Buffer.flush_all_thinking_buffers(state.thinking_buffer)
    spinner_ids = OwlOutput.stop_all_spinners(state.spinner_ids)

    state = %{
      state
      | text_buffer: text_buffer,
        thinking_buffer: thinking_buffer,
        spinner_ids: spinner_ids
    }

    elapsed = System.monotonic_time(:millisecond) - (state.start_time || 0)

    if elapsed > 0 and state.token_count > 0 do
      elapsed_s = elapsed / 1000
      rate = state.token_count / elapsed_s

      OwlOutput.owl_puts(
        Owl.Data.tag(
          "\nCompleted: #{state.token_count} tokens in #{Float.round(elapsed_s, 1)}s (#{Float.round(rate, 1)} t/s avg)",
          :faint
        )
      )
    end

    state
  end

  # ── PubSub Subscription ───────────────────────────────────────────────────

  defp maybe_subscribe_session(state, nil), do: state

  defp maybe_subscribe_session(state, session_id) do
    topic = EventBus.session_topic(session_id)
    :ok = EventBus.subscribe_session(session_id)
    %{state | topics: [topic | state.topics]}
  end

  defp maybe_subscribe_run(state, nil), do: state

  defp maybe_subscribe_run(state, run_id) do
    topic = EventBus.run_topic(run_id)
    :ok = EventBus.subscribe_run(run_id)
    %{state | topics: [topic | state.topics]}
  end

  # When no session_id or run_id is provided but subscribe_global is true,
  # subscribe to the global EventBus topic so the renderer isn't dead.
  defp maybe_subscribe_global(state, true, nil, nil) do
    topic = EventBus.global_topic()
    :ok = EventBus.subscribe_global()
    %{state | topics: [topic | state.topics]}
  end

  defp maybe_subscribe_global(state, _subscribe_global, _session_id, _run_id), do: state
end
