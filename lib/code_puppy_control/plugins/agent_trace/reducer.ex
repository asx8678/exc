defmodule CodePuppyControl.Plugins.AgentTrace.Reducer do
  @moduledoc "Event reducer that folds trace events into an immutable TraceState."

  alias CodePuppyControl.Plugins.AgentTrace.Schema

  @empty_usage %{
    input_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    cached_tokens: 0,
    accounting: :unknown,
    estimated_input: nil,
    estimated_output: nil,
    reconciled: false
  }

  @doc "Create an empty trace state."
  @spec new(String.t()) :: map()
  def new(trace_id) do
    %{
      trace_id: trace_id,
      spans: %{},
      span_order: [],
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cost_usd: 0.0,
      pending_reconciliation: MapSet.new(),
      created_at: Schema.now_iso()
    }
  end

  @doc "Reduce an event into the current state (pure function)."
  @spec reduce_event(map(), Schema.trace_event()) :: map()
  def reduce_event(state, event) do
    case event.event_type do
      :span_started -> reduce_span_started(state, event)
      :span_ended -> reduce_span_ended(state, event)
      :usage_reported -> reduce_usage_reported(state, event)
      :usage_reconciled -> reduce_usage_reconciled(state, event)
      _ -> state
    end
  end

  @doc "Replay a list of events to reconstruct state."
  @spec replay_trace([Schema.trace_event()]) :: map()
  def replay_trace([]), do: new("")

  def replay_trace(events) do
    state = new(hd(events).trace_id)
    Enum.reduce(events, state, &reduce_event(&2, &1))
  end

  @doc "Get active (running) spans."
  @spec active_spans(map()) :: [map()]
  def active_spans(state),
    do: state.spans |> Map.values() |> Enum.filter(&(&1.status == "running"))

  defp reduce_span_started(state, event) do
    node = event.node || %{}

    span = %{
      span_id: event.span_id,
      node_id: node[:id] || "",
      kind: node[:kind] || :unknown,
      name: node[:name],
      status: "running",
      parent_span_id: event.parent_span_id,
      parent_node_id: node[:parent_node_id],
      started_at: :erlang.system_time(:millisecond) / 1000,
      ended_at: nil,
      duration_ms: nil,
      usage: @empty_usage,
      error: nil,
      child_span_ids: []
    }

    spans = Map.put(state.spans, event.span_id, span)
    spans = update_parent_children(spans, event.parent_span_id, event.span_id)
    %{state | spans: spans, span_order: state.span_order ++ [event.span_id]}
  end

  defp reduce_span_ended(state, event) do
    if event.span_id && Map.has_key?(state.spans, event.span_id) do
      span = state.spans[event.span_id]
      ended_at = :erlang.system_time(:millisecond) / 1000
      duration = (ended_at - span.started_at) * 1000
      status = if event.node, do: event.node[:status] || "done", else: "done"
      error = event.extra[:error]
      duration_ms = if event.metrics, do: event.metrics[:duration_ms] || duration, else: duration

      %{
        state
        | spans:
            Map.put(state.spans, event.span_id, %{
              span
              | status: status,
                ended_at: ended_at,
                duration_ms: duration_ms,
                error: error
            })
      }
    else
      state
    end
  end

  defp reduce_usage_reported(state, event) do
    if event.span_id && Map.has_key?(state.spans, event.span_id) do
      span = state.spans[event.span_id]
      usage = event.extra[:usage] || %{}

      new_usage = %{
        span.usage
        | input_tokens: usage[:input_tokens] || span.usage.input_tokens,
          output_tokens: usage[:output_tokens] || span.usage.output_tokens,
          reasoning_tokens: usage[:reasoning_tokens] || span.usage.reasoning_tokens,
          cached_tokens: usage[:cached_tokens] || span.usage.cached_tokens
      }

      cost = if event.metrics, do: event.metrics[:cost_usd] || 0.0, else: 0.0

      %{
        state
        | spans: Map.put(state.spans, event.span_id, %{span | usage: new_usage}),
          total_input_tokens: state.total_input_tokens + (usage[:input_tokens] || 0),
          total_output_tokens: state.total_output_tokens + (usage[:output_tokens] || 0),
          total_cost_usd: state.total_cost_usd + cost
      }
    else
      state
    end
  end

  defp reduce_usage_reconciled(state, event) do
    if event.span_id && Map.has_key?(state.spans, event.span_id) do
      span = state.spans[event.span_id]
      recon = event.extra[:reconciliation] || %{}
      exact = recon[:exact] || %{}

      new_usage = %{
        span.usage
        | input_tokens: exact[:input_tokens] || span.usage.input_tokens,
          output_tokens: exact[:output_tokens] || span.usage.output_tokens,
          reasoning_tokens: exact[:reasoning_tokens] || span.usage.reasoning_tokens,
          cached_tokens: exact[:cached_tokens] || span.usage.cached_tokens,
          accounting: :reconciled,
          reconciled: true
      }

      drift = recon[:drift] || %{}

      %{
        state
        | spans: Map.put(state.spans, event.span_id, %{span | usage: new_usage}),
          total_input_tokens: state.total_input_tokens + (drift[:input_tokens] || 0),
          total_output_tokens: state.total_output_tokens + (drift[:output_tokens] || 0),
          pending_reconciliation: MapSet.delete(state.pending_reconciliation, event.span_id)
      }
    else
      state
    end
  end

  defp update_parent_children(spans, nil, _), do: spans

  defp update_parent_children(spans, parent_id, child_id) do
    if Map.has_key?(spans, parent_id) do
      parent = spans[parent_id]
      Map.put(spans, parent_id, %{parent | child_span_ids: parent.child_span_ids ++ [child_id]})
    else
      spans
    end
  end
end
