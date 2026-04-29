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

  ## Usage

      # Start a renderer for a specific session
      {:ok, pid} = Renderer.start_link(session_id: "sess-123")

      # Or attach to a run
      {:ok, pid} = Renderer.start_link(run_id: "run-456")

      # Manually push a canonical Stream.Event struct
      Renderer.push(pid, %Event.TextDelta{index: 0, text: "Hello"})

      # Clean up
      Renderer.stop(pid)

  ## Owl Integration

  - `Owl.Data.tag/2` for styled text (colors, bold, dim)
  - `Owl.Box.new/2` for banner blocks
  - `Owl.Spinner` for tool-call progress indicators
  - `Owl.IO.puts/2` for terminal output above live blocks

  ## Phase 1

  Basic streaming, banners, spinners, and completion stats.
  Phase 2 will add syntax highlighting and advanced markdown rendering.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.TUI.Markdown

  # ── Constants ─────────────────────────────────────────────────────────────

  # Flush buffered text when it exceeds this character count
  @flush_threshold 20

  # Spinner frame rate (ms)
  @spinner_refresh_ms 100

  # Rate update throttle (5 Hz → 200ms)
  @rate_update_interval_ms 200

  # Puppy-themed loading messages (mirroring Python StreamRenderer)
  @loading_messages [
    "Sniffing around...",
    "Wagging tail...",
    "Digging up results...",
    "Chewing on it...",
    "Puppy pondering...",
    "Bounding through data...",
    "Howling at the code..."
  ]

  # Banner style map: config_name → {label, color, icon}
  # Mirrors the Python TOOL_BANNER_MAP
  @tool_banner_styles %{
    "read_file" => {"READ FILE", :cyan, "📖"},
    "write_file" => {"WRITE FILE", :green, "✏️"},
    "replace_in_file" => {"EDIT FILE", :yellow, "🔧"},
    "delete_file" => {"DELETE FILE", :red, "🗑️"},
    "list_files" => {"LIST FILES", :cyan, "📁"},
    "grep" => {"GREP", :magenta, "🔍"},
    "run_shell_command" => {"SHELL", :blue, "💻"},
    "create_file" => {"CREATE FILE", :green, "📝"},
    "agent_run" => {"AGENT", :blue, "🤖"},
    "mcp_tool_call" => {"MCP TOOL", :magenta, "🔧"}
  }

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
    last_rate_update: 0
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
          last_rate_update: non_neg_integer()
        }

  @type monotonic_time :: integer()

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the renderer GenServer.

  ## Options

    * `:session_id` — subscribe to session topic
    * `:run_id` — subscribe to run topic
    * `:name` — GenServer name registration

  At least one of `:session_id` or `:run_id` must be provided.
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
  abnormally. Add it to your supervision tree like so:

      children = [
        {Renderer, session_id: "sess-123"}
      ]

  ## Options

    * `:id` — custom child id (default `__MODULE__`)
    * All other options are forwarded to `start_link/1`.
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
      topics: []
    }

    # Subscribe to relevant PubSub topics
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
    # EventBus broadcast — convert to canonical if possible
    state =
      case event_to_canonical(event) do
        {:ok, canonical} -> handle_stream_event(canonical, state)
        :skip -> handle_eventbus_event(event, state)
      end

    {:noreply, state}
  end

  # Ignore unknown messages
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
    # Stop any active spinners
    Enum.each(state.spinner_ids, fn {_idx, ref} ->
      stop_spinner(ref)
    end)

    {:reply, :ok,
     %__MODULE__{
       session_id: state.session_id,
       run_id: state.run_id,
       topics: state.topics,
       start_time: System.monotonic_time(:millisecond)
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

    print_banner(state, "AGENT RESPONSE", :blue, "💬")
  end

  defp handle_stream_event(%Event.TextDelta{index: idx, text: text}, state) do
    state = %{state | token_count: state.token_count + 1}

    # Append to buffer
    existing = Map.get(state.text_buffer, idx, [])
    state = %{state | text_buffer: Map.put(state.text_buffer, idx, existing ++ [text])}

    # Flush on newlines or when buffer exceeds threshold
    chunks = Map.get(state.text_buffer, idx, [])
    buf = IO.iodata_to_binary(chunks)

    if String.contains?(buf, "\n") or byte_size(buf) > @flush_threshold do
      owl_puts(Markdown.render(buf))
      state = %{state | text_buffer: Map.put(state.text_buffer, idx, [])}
      update_rate(state)
    else
      state
    end
  end

  defp handle_stream_event(%Event.TextEnd{index: idx}, state) do
    # Flush remaining buffer
    state = flush_text_buffer(state, idx)
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

    print_banner(state, "THINKING", :yellow, "⚡")
  end

  defp handle_stream_event(%Event.ThinkingDelta{index: idx, text: text}, state) do
    existing = Map.get(state.thinking_buffer, idx, [])
    %{state | thinking_buffer: Map.put(state.thinking_buffer, idx, existing ++ [text])}
  end

  defp handle_stream_event(%Event.ThinkingEnd{index: idx}, state) do
    # Flush thinking buffer (rendered dimmed)
    chunks = Map.get(state.thinking_buffer, idx, [])

    if chunks != [] do
      text = IO.iodata_to_binary(chunks)
      owl_puts(Owl.Data.tag(Markdown.render(text), :faint))
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

    state = print_tool_banner(state, name)
    start_tool_spinner(state, idx, name)
  end

  defp handle_stream_event(%Event.ToolCallArgsDelta{}, state) do
    # Tool args deltas are not displayed in the TUI
    state
  end

  defp handle_stream_event(%Event.ToolCallEnd{index: idx, name: name}, state) do
    state = stop_tool_spinner(state, idx)

    # Print tool completion indicator
    owl_puts(Owl.Data.tag(" ✔ #{name}", :green))

    cleanup_part(state, idx)
  end

  defp handle_stream_event(%Event.UsageUpdate{}, state) do
    # Usage updates are displayed at finalization
    state
  end

  defp handle_stream_event(%Event.Done{}, state) do
    # Flush all remaining buffers
    state
    |> flush_all_text_buffers()
    |> flush_all_thinking_buffers()
    |> stop_all_spinners()
  end

  # Catch-all for unrecognized events
  defp handle_stream_event(_event, state), do: state

  # ── EventBus Map Handlers ─────────────────────────────────────────────────

  # EventBus events that can't be converted to canonical Stream.Events
  defp handle_eventbus_event(%{type: "text", content: content}, state) do
    # EventBus.broadcast_text/4 emits these — render as plain text
    owl_puts(Markdown.render(content))
    state
  end

  defp handle_eventbus_event(%{type: "agent_run_failed", error: error}, state) do
    owl_puts(Owl.Data.tag("\u2716 Error: #{error}", :red))
    state
  end

  defp handle_eventbus_event(%{type: "status", status: status}, state) do
    owl_puts(Owl.Data.tag(" #{status}", :faint))
    state
  end

  defp handle_eventbus_event(%{type: "thinking", content: content}, state) do
    owl_puts(Owl.Data.tag(content, :faint))
    state
  end

  defp handle_eventbus_event(_event, state), do: state

  # ── Event Conversion ──────────────────────────────────────────────────────

  # Try canonical wire format first (string-keyed maps matching
  # Stream.Event.to_wire/1), then fall back to legacy EventBus maps.
  defp event_to_canonical(%{"type" => _} = wire_event) do
    case Event.from_wire(wire_event) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, :unknown_type} -> legacy_event_to_canonical(wire_event)
    end
  end

  defp event_to_canonical(%{type: _} = event) do
    # Legacy atom-keyed EventBus maps
    legacy_event_to_canonical(event)
  end

  defp event_to_canonical(_), do: :skip

  # Legacy EventBus event conversion (atom-keyed maps)
  defp legacy_event_to_canonical(%{type: "agent_llm_stream", chunk: chunk}) do
    {:ok, %Event.TextDelta{index: 0, text: chunk}}
  end

  defp legacy_event_to_canonical(%{type: "agent_tool_call_start", tool_name: name, tool_call_id: id}) do
    {:ok, %Event.ToolCallStart{index: 0, id: id, name: name}}
  end

  defp legacy_event_to_canonical(%{type: "agent_tool_call_end", tool_name: name, tool_call_id: id}) do
    {:ok, %Event.ToolCallEnd{index: 0, id: id || "", name: name, arguments: ""}}
  end

  defp legacy_event_to_canonical(%{type: "agent_run_completed"}), do: {:ok, %Event.Done{}}

  defp legacy_event_to_canonical(_), do: :skip

  # ── Buffer Management ─────────────────────────────────────────────────────

  defp flush_text_buffer(state, idx) do
    chunks = Map.get(state.text_buffer, idx, [])

    if chunks != [] do
      text = IO.iodata_to_binary(chunks)
      owl_puts(Markdown.render(text))
    end

    %{state | text_buffer: Map.put(state.text_buffer, idx, [])}
  end

  defp flush_all_text_buffers(state) do
    state.text_buffer
    |> Enum.each(fn {_idx, chunks} ->
      if chunks != [] do
        text = IO.iodata_to_binary(chunks)
        owl_puts(Markdown.render(text))
      end
    end)

    %{state | text_buffer: %{}}
  end

  defp flush_all_thinking_buffers(state) do
    state.thinking_buffer
    |> Enum.each(fn {_idx, chunks} ->
      if chunks != [] do
        text = IO.iodata_to_binary(chunks)
        owl_puts(Owl.Data.tag(Markdown.render(text), :faint))
      end
    end)

    %{state | thinking_buffer: %{}}
  end

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

  # ── Banner Rendering ──────────────────────────────────────────────────────

  defp print_banner(state, label, color, icon) do
    tag = Owl.Data.tag(" #{label} ", [:white, color_background(color)])
    icon_str = if icon && icon != "", do: " #{icon}", else: ""
    owl_puts(["\n", tag, icon_str])
    state
  end

  defp print_tool_banner(state, tool_name) do
    {label, color, icon} = Map.get(@tool_banner_styles, tool_name, {tool_name, :blue, "🔧"})
    print_banner(state, label, color, icon)
  end

  defp color_background(:cyan), do: :cyan_background
  defp color_background(:green), do: :green_background
  defp color_background(:yellow), do: :yellow_background
  defp color_background(:red), do: :red_background
  defp color_background(:blue), do: :blue_background
  defp color_background(:magenta), do: :magenta_background
  defp color_background(_), do: :blue_background

  # ── Spinner Management ────────────────────────────────────────────────────

  defp start_tool_spinner(state, idx, _tool_name) do
    # Pick a loading message based on current index
    msg_idx = rem(state.loading_index, length(@loading_messages))
    label = Enum.at(@loading_messages, msg_idx)

    ref = make_ref()

    spinner_opts = [
      id: ref,
      refresh_every: @spinner_refresh_ms,
      labels: [processing: Owl.Data.tag(label, :faint)]
    ]

    case Owl.Spinner.start(spinner_opts) do
      {:ok, _pid} ->
        %{
          state
          | spinner_ids: Map.put(state.spinner_ids, idx, ref),
            loading_index: state.loading_index + 1
        }

      {:error, reason} ->
        Logger.debug("TUI.Renderer: spinner start failed: #{inspect(reason)}")
        state
    end
  end

  defp stop_tool_spinner(state, idx) do
    case Map.get(state.spinner_ids, idx) do
      nil ->
        state

      ref ->
        stop_spinner(ref)
        %{state | spinner_ids: Map.delete(state.spinner_ids, idx)}
    end
  end

  defp stop_spinner(ref) do
    try do
      Owl.Spinner.stop(id: ref, resolution: :ok)
    catch
      :exit, _ -> :ok
    end
  end

  defp stop_all_spinners(state) do
    Enum.each(state.spinner_ids, fn {_idx, ref} ->
      stop_spinner(ref)
    end)

    %{state | spinner_ids: %{}}
  end

  # ── Rate Tracking ─────────────────────────────────────────────────────────

  defp update_rate(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.last_rate_update >= @rate_update_interval_ms do
      elapsed = now - (state.start_time || now)

      if elapsed > 0 do
        _rate = state.token_count / (elapsed / 1000)
        # TODO(prg-3): Phase 2 — wire rate to a status bar / Owl.LiveScreen block
      end

      %{state | last_rate_update: now}
    else
      state
    end
  end

  # ── Finalization ──────────────────────────────────────────────────────────

  defp do_finalize(state) do
    # Flush remaining buffers
    state =
      state
      |> flush_all_text_buffers()
      |> flush_all_thinking_buffers()
      |> stop_all_spinners()

    # Print completion stats
    elapsed = System.monotonic_time(:millisecond) - (state.start_time || 0)

    if elapsed > 0 and state.token_count > 0 do
      elapsed_s = elapsed / 1000
      rate = state.token_count / elapsed_s

      owl_puts(
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

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp owl_puts(data) do
    try do
      Owl.IO.puts(data)
    catch
      # :io.put_chars throws :terminated when the IO device is
      # closed/captured (e.g., ExUnit.CaptureIO released the group
      # leader).  A terminal write failure must never crash the
      # Renderer GenServer — silently skip, matching the defensive
      # pattern already used for finalize in Dispatch.
      :error, :terminated -> :ok
      :exit, :terminated -> :ok
    end
  end
end
