defmodule CodePuppyControl.Plugins.AgentTrace do
  @moduledoc "Agent Trace plugin - tracks execution graph and token usage. Ported from code_puppy/plugins/agent_trace/."

  use CodePuppyControl.Plugins.PluginBehaviour
  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Plugins.AgentTrace.{Schema, Store, Reducer}
  require Logger

  @impl true
  def name, do: "agent_trace"
  @impl true
  def description, do: "Tracks agent execution graph and token usage"

  @impl true
  def register do
    Callbacks.register(:startup, &__MODULE__.on_startup/0)
    Callbacks.register(:agent_run_start, &__MODULE__.on_agent_run_start/3)
    Callbacks.register(:stream_event, &__MODULE__.on_stream_event/3)
    Callbacks.register(:pre_tool_call, &__MODULE__.on_pre_tool_call/3)
    Callbacks.register(:post_tool_call, &__MODULE__.on_post_tool_call/5)
    Callbacks.register(:agent_run_end, &__MODULE__.on_agent_run_end/7)
    Callbacks.register(:custom_command_help, &__MODULE__.custom_help/0)
    Callbacks.register(:custom_command, &__MODULE__.handle_trace_command/2)
    :ok
  end

  @impl true
  def startup, do: :ok
  @impl true
  def shutdown, do: :ok

  @spec get_state(String.t()) :: map() | nil
  def get_state(trace_id), do: Process.get({__MODULE__, trace_id})

  @spec reset() :: :ok
  def reset, do: :ok

  @doc false
  def on_startup, do: :ok

  @doc false
  def on_agent_run_start(agent_name, _model, session_id) do
    trace_id = "trace-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

    event =
      Schema.span_started(trace_id, :agent_run,
        name: agent_name,
        session_id: session_id || "default"
      )

    state = Reducer.new(trace_id) |> Reducer.reduce_event(event)
    Store.append(event)
    Process.put({__MODULE__, :current_trace_id}, trace_id)
    Process.put({__MODULE__, :agent_span_id}, event.span_id)
    Process.put({__MODULE__, :agent_node_id}, event.node[:id])
    Process.put({__MODULE__, trace_id}, state)
    :ok
  end

  @doc false
  def on_stream_event(_, _, _), do: :ok

  @doc false
  def on_pre_tool_call(tool_name, _args, _ctx) do
    trace_id = Process.get({__MODULE__, :current_trace_id})
    agent_span = Process.get({__MODULE__, :agent_span_id})

    if trace_id && agent_span do
      event =
        Schema.span_started(trace_id, :tool_call, name: tool_name, parent_span_id: agent_span)

      state = get_state(trace_id) || Reducer.new(trace_id)
      state = Reducer.reduce_event(state, event)
      Store.append(event)
      Process.put({__MODULE__, trace_id}, state)
      Process.put({__MODULE__, :current_tool_span_id}, event.span_id)
    end

    nil
  end

  @doc false
  def on_post_tool_call(tool_name, _args, _result, duration_ms, _ctx) do
    trace_id = Process.get({__MODULE__, :current_trace_id})
    tool_span = Process.get({__MODULE__, :current_tool_span_id})

    if trace_id && tool_span do
      state = get_state(trace_id) || Reducer.new(trace_id)
      node_id = (state.spans[tool_span] || %{})[:node_id] || ""

      event =
        Schema.span_ended(trace_id, tool_span, node_id, :tool_call,
          name: tool_name,
          success: true,
          duration_ms: duration_ms
        )

      state = Reducer.reduce_event(state, event)
      Store.append(event)
      Process.put({__MODULE__, trace_id}, state)
    end

    nil
  end

  @doc false
  def on_agent_run_end(agent_name, _model, _session, success, error, _response_text, _metadata) do
    trace_id = Process.get({__MODULE__, :current_trace_id})
    agent_span = Process.get({__MODULE__, :agent_span_id})

    if trace_id && agent_span do
      state = get_state(trace_id) || Reducer.new(trace_id)
      node_id = (state.spans[agent_span] || %{})[:node_id] || ""

      event =
        Schema.span_ended(trace_id, agent_span, node_id, :agent_run,
          name: agent_name,
          success: success,
          error: error
        )

      state = Reducer.reduce_event(state, event)
      Store.append(event)
      Process.put({__MODULE__, trace_id}, state)

      if state.total_input_tokens + state.total_output_tokens > 500 do
        Logger.info(
          "Trace #{trace_id}: #{state.total_input_tokens} in, #{state.total_output_tokens} out, #{map_size(state.spans)} spans"
        )
      end
    end

    :ok
  end

  @doc false
  def custom_help, do: [{"trace", "Agent trace: /trace status|list|show|clear"}]

  @doc false
  def handle_trace_command(command, name) do
    if name != "trace", do: nil, else: do_handle(command)
  end

  defp do_handle(command) do
    parts = String.split(command)
    sub = if length(parts) > 1, do: Enum.at(parts, 1), else: "status"

    case sub do
      "status" ->
        IO.puts("Trace system active")

      "list" ->
        IO.puts("Traces: #{Enum.join(Enum.take(Store.list_traces(), 10), ", ")}")

      "show" ->
        tid =
          if length(parts) > 2,
            do: Enum.at(parts, 2),
            else: Process.get({__MODULE__, :current_trace_id})

        IO.puts(
          if tid, do: "Trace #{tid}: #{length(Store.read(tid))} events", else: "No active trace"
        )

      "clear" ->
        Process.delete({__MODULE__, :current_trace_id})
        IO.puts("Trace state cleared")

      _ ->
        IO.puts("Usage: /trace status|list|show [id]|clear")
    end

    true
  end
end
