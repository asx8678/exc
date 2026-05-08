defmodule CodePuppyControl.Agent.SubagentStreamHandler do
  @moduledoc """
  Silent event stream handler for sub-agents.

  Processes canonical stream events from a sub-agent run without producing
  any console output. Updates metrics (token counts, tool call counts,
  status changes) and publishes them via EventBus so the parent agent's
  TUI can display sub-agent progress.

  ## Design

  This GenServer replaces the Python `subagent_stream_handler.py`'s
  async function with an Elixir-native process. Key differences:

  - **No console output** — The Python version suppressed Rich console
    output for sub-agents. This version never produces any.
  - **EventBus replaces SubAgentConsoleManager** — Instead of calling
    `manager.update_agent()`, we broadcast status events via PubSub.
    The TUI subscribes to these events to display sub-agent progress.
  - **Callback firing** — Stream events are normalized and fired via
    the `Callbacks` system for plugin consumers (e.g., Agent Trace).

  ## Usage

      # Start a handler for a sub-agent run
      {:ok, pid} = SubagentStreamHandler.start_link(
        run_id: "run-456",
        session_id: "session-789",
        parent_session_id: "session-456"
      )

      # Feed canonical stream events
      SubagentStreamHandler.push(pid, %TextDelta{index: 0, text: "Computing..."})
      SubagentStreamHandler.push(pid, %TextEnd{index: 0, id: nil})

      # Drain remaining events and stop
      SubagentStreamHandler.drain(pid)

  Port of `code_puppy/agents/subagent_stream_handler.py`.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.{Callbacks, EventBus}
  alias CodePuppyControl.MessageCore.TokenEstimator
  alias CodePuppyControl.Stream.{Event, EventNormalizer}

  # ── State ──────────────────────────────────────────────────────────

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          session_id: String.t() | nil,
          parent_session_id: String.t() | nil,
          # Metrics
          token_count: non_neg_integer(),
          tool_call_count: non_neg_integer(),
          # Active tool call indices (for tracking tool parts)
          active_tool_parts: MapSet.t(non_neg_integer()),
          # Current tool name for status updates
          current_tool: String.t() | nil
        }

  defstruct [
    :run_id,
    :session_id,
    :parent_session_id,
    token_count: 0,
    tool_call_count: 0,
    active_tool_parts: MapSet.new(),
    current_tool: nil
  ]

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Starts the sub-agent stream handler.

  ## Options

    * `:run_id` — Run identifier for EventBus routing
    * `:session_id` — Sub-agent session identifier
    * `:parent_session_id` — Parent agent's session identifier
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
  Returns the current metrics from the handler.
  """
  @spec get_metrics(pid()) :: %{
          token_count: non_neg_integer(),
          tool_call_count: non_neg_integer(),
          current_tool: String.t() | nil
        }
  def get_metrics(pid) do
    GenServer.call(pid, :get_metrics)
  end

  @doc """
  Drains any remaining events and stops the handler.
  """
  @spec drain(pid()) :: :ok
  def drain(pid) do
    GenServer.call(pid, :drain)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %__MODULE__{
      run_id: Keyword.get(opts, :run_id),
      session_id: Keyword.get(opts, :session_id),
      parent_session_id: Keyword.get(opts, :parent_session_id)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    state = process_event(event, state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply,
     %{
       token_count: state.token_count,
       tool_call_count: state.tool_call_count,
       current_tool: state.current_tool
     }, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    # Publish final status
    publish_status(state, "completed")
    {:stop, :normal, :ok, state}
  end

  # ── Event Processing ────────────────────────────────────────────────

  # TextStart — track initial content tokens
  defp process_event(%Event.TextStart{index: idx} = _event, state) do
    fire_callback(
      "part_start",
      %{
        "index" => idx,
        "part_type" => "TextPart"
      },
      state
    )

    state
  end

  # TextDelta — count tokens from content delta
  defp process_event(%Event.TextDelta{index: idx, text: text} = _event, state) do
    fire_callback(
      "part_delta",
      %{
        "index" => idx,
        "delta_type" => "TextPartDelta",
        "content_delta" => text
      },
      state
    )

    tokens = estimate_tokens(text)
    new_count = state.token_count + tokens

    state = %{state | token_count: new_count}
    publish_status(state, "running")
    state
  end

  # TextEnd — no special action
  defp process_event(%Event.TextEnd{index: idx} = _event, state) do
    fire_callback(
      "part_end",
      %{
        "index" => idx,
        "next_part_kind" => nil
      },
      state
    )

    state
  end

  # ThinkingStart — track initial content tokens
  defp process_event(%Event.ThinkingStart{index: idx} = _event, state) do
    fire_callback(
      "part_start",
      %{
        "index" => idx,
        "part_type" => "ThinkingPart"
      },
      state
    )

    publish_status(state, "thinking")
    state
  end

  # ThinkingDelta — count tokens from thinking content
  defp process_event(%Event.ThinkingDelta{index: idx, text: text} = _event, state) do
    fire_callback(
      "part_delta",
      %{
        "index" => idx,
        "delta_type" => "ThinkingPartDelta",
        "content_delta" => text
      },
      state
    )

    tokens = estimate_tokens(text)
    new_count = state.token_count + tokens

    state = %{state | token_count: new_count}
    publish_status(state, "thinking")
    state
  end

  # ThinkingEnd — reset to running
  defp process_event(%Event.ThinkingEnd{index: idx} = _event, state) do
    fire_callback(
      "part_end",
      %{
        "index" => idx,
        "next_part_kind" => nil
      },
      state
    )

    publish_status(state, "running")
    state
  end

  # ToolCallStart — increment tool call count, track active tool
  defp process_event(%Event.ToolCallStart{index: idx, name: name} = event, state) do
    fire_callback(
      "part_start",
      %{
        "index" => idx,
        "part_type" => "ToolCallPart",
        "tool_name" => name,
        "tool_call_id" => event.id
      },
      state
    )

    new_tool_count = state.tool_call_count + 1
    active = MapSet.put(state.active_tool_parts, idx)

    state = %{
      state
      | tool_call_count: new_tool_count,
        active_tool_parts: active,
        current_tool: name
    }

    publish_status(state, "tool_calling")
    state
  end

  # ToolCallArgsDelta — count tokens from args delta
  defp process_event(%Event.ToolCallArgsDelta{index: idx, arguments: args} = _event, state) do
    fire_callback(
      "part_delta",
      %{
        "index" => idx,
        "delta_type" => "ToolCallArgsDelta",
        "args_delta" => args
      },
      state
    )

    tokens = estimate_tokens(args)
    new_count = state.token_count + tokens

    state = %{state | token_count: new_count}
    publish_status(state, "tool_calling")
    state
  end

  # ToolCallEnd — deactivate tool part, reset status if no active tools
  defp process_event(%Event.ToolCallEnd{index: idx, name: name} = _event, state) do
    fire_callback(
      "part_end",
      %{
        "index" => idx,
        "next_part_kind" => nil,
        "tool_name" => name
      },
      state
    )

    active = MapSet.delete(state.active_tool_parts, idx)

    state = %{state | active_tool_parts: active}

    # If no more active tool parts after removal, reset to running
    state =
      if MapSet.size(active) == 0 do
        %{state | current_tool: nil}
      else
        state
      end

    status = if MapSet.size(active) == 0, do: "running", else: "tool_calling"
    publish_status(state, status)
    state
  end

  # UsageUpdate — informational, no metrics change needed
  defp process_event(%Event.UsageUpdate{} = _usage, state) do
    state
  end

  # Done — final event
  defp process_event(%Event.Done{} = done, state) do
    fire_callback(
      "done",
      %{
        "id" => done.id,
        "model" => done.model,
        "finish_reason" => done.finish_reason
      },
      state
    )

    state
  end

  defp process_event(_unknown, state) do
    state
  end

  # ── Token Estimation ────────────────────────────────────────────────

  # Delegates to the shared TokenEstimator heuristic (1 token per ~2.5 chars)
  # matching the Python `token_utils.estimate_token_count` formula.
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  defp estimate_tokens(content) when is_binary(content) and byte_size(content) > 0 do
    TokenEstimator.estimate_tokens(content)
  end

  defp estimate_tokens(_), do: 0

  # ── Status Publishing ──────────────────────────────────────────────

  defp publish_status(state, status) do
    EventBus.broadcast_status(
      state.run_id || "",
      state.parent_session_id || state.session_id,
      status,
      metadata: %{
        token_count: state.token_count,
        tool_call_count: state.tool_call_count,
        current_tool: state.current_tool,
        subagent_session_id: state.session_id
      }
    )
  end

  # ── Callback Firing ────────────────────────────────────────────────

  defp fire_callback(event_type, event_data, state) do
    # Normalize event data for consistent processing by downstream consumers
    normalized_data = EventNormalizer.normalize(event_type, event_data)
    session_id = state.session_id

    # Fire callback non-blocking — spawn a task to avoid blocking the handler
    spawn(fn ->
      try do
        Callbacks.trigger(:stream_event, [event_type, normalized_data, session_id])
      rescue
        e ->
          Logger.debug("Error firing stream event callback: #{inspect(e)}")
      end
    end)

    :ok
  end
end
