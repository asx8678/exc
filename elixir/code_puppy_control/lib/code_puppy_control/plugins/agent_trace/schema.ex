defmodule CodePuppyControl.Plugins.AgentTrace.Schema do
  @moduledoc """
  Schema definitions for agent trace events (V2).

  Defines the core data structures: NodeKind, TransferKind, EventType,
  TraceEvent, and supporting structs. These are the atoms of the
  execution graph that the reducer assembles into TraceState.
  """

  @type node_kind ::
          :user | :session | :agent_run | :model_call | :tool_call | :memory_snapshot | :artifact
  @type transfer_kind ::
          :user_prompt
          | :system_instructions
          | :history_context
          | :retrieved_context
          | :model_input
          | :model_output
          | :tool_args
          | :tool_result
          | :delegate_prompt
          | :delegate_response
          | :memory_append
          | :artifact_write
          | :artifact_read
  @type token_class ::
          :input_tokens
          | :output_tokens
          | :reasoning_tokens
          | :cached_tokens
          | :estimated_tokens
          | :billable_tokens
  @type accounting_state :: :estimated_live | :provider_reported_exact | :reconciled | :unknown
  @type event_type ::
          :span_started
          | :span_updated
          | :span_ended
          | :transfer_started
          | :transfer_chunk
          | :transfer_completed
          | :usage_reported
          | :usage_reconciled
          | :artifact_created
          | :artifact_read

  @type trace_event :: %{
          event_id: String.t(),
          trace_id: String.t(),
          event_type: event_type(),
          timestamp: String.t(),
          span_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          run_id: String.t() | nil,
          session_id: String.t() | nil,
          node: map() | nil,
          transfer: map() | nil,
          metrics: map() | nil,
          extra: map()
        }

  @doc "Generate a unique event ID."
  @spec make_event_id() :: String.t()
  def make_event_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc "Get current UTC timestamp in ISO format."
  @spec now_iso() :: String.t()
  def now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc "Create a span ID."
  @spec make_span_id() :: String.t()
  def make_span_id do
    "span-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
  end

  @doc "Create a node ID with a meaningful prefix."
  @spec make_node_id(atom(), String.t() | nil) :: String.t()
  def make_node_id(kind, name \\ nil) do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    if name do
      safe_name = name |> String.replace(~r/[^a-zA-Z0-9]/, "-") |> String.slice(0, 20)
      "#{kind}-#{safe_name}-#{suffix}"
    else
      "#{kind}-#{suffix}"
    end
  end

  @doc "Create a span.started event."
  @spec span_started(String.t(), atom(), keyword()) :: trace_event()
  def span_started(trace_id, kind, opts \\ []) do
    span_id = Keyword.get(opts, :span_id, make_span_id())
    name = Keyword.get(opts, :name)
    parent_span_id = Keyword.get(opts, :parent_span_id)
    session_id = Keyword.get(opts, :session_id)
    run_id = Keyword.get(opts, :run_id)
    parent_node_id = Keyword.get(opts, :parent_node_id)
    node_id = make_node_id(kind, name)

    %{
      event_id: make_event_id(),
      trace_id: trace_id,
      event_type: :span_started,
      timestamp: now_iso(),
      span_id: span_id,
      parent_span_id: parent_span_id,
      run_id: run_id,
      session_id: session_id,
      node: %{
        id: node_id,
        kind: kind,
        name: name,
        status: "running",
        parent_node_id: parent_node_id
      },
      transfer: nil,
      metrics: nil,
      extra: %{}
    }
  end

  @doc "Create a span.ended event."
  @spec span_ended(String.t(), String.t(), String.t(), atom(), keyword()) :: trace_event()
  def span_ended(trace_id, span_id, node_id, kind, opts \\ []) do
    name = Keyword.get(opts, :name)
    success = Keyword.get(opts, :success, true)
    error = Keyword.get(opts, :error)
    duration_ms = Keyword.get(opts, :duration_ms)
    session_id = Keyword.get(opts, :session_id)

    %{
      event_id: make_event_id(),
      trace_id: trace_id,
      event_type: :span_ended,
      timestamp: now_iso(),
      span_id: span_id,
      parent_span_id: nil,
      run_id: nil,
      session_id: session_id,
      node: %{
        id: node_id,
        kind: kind,
        name: name,
        status: if(success, do: "done", else: "failed")
      },
      transfer: nil,
      metrics: if(duration_ms, do: %{duration_ms: duration_ms}, else: nil),
      extra: if(error, do: %{error: to_string(error)}, else: %{})
    }
  end

  @doc "Create a usage.reconciled event."
  @spec usage_reconciled(String.t(), String.t(), String.t(), keyword()) :: trace_event()
  def usage_reconciled(trace_id, span_id, node_id, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    est_input = Keyword.get(opts, :estimated_input)
    est_output = Keyword.get(opts, :estimated_output)
    exact_input = Keyword.get(opts, :exact_input)
    exact_output = Keyword.get(opts, :exact_output)
    exact_reasoning = Keyword.get(opts, :exact_reasoning)
    exact_cached = Keyword.get(opts, :exact_cached)
    cost_usd = Keyword.get(opts, :cost_usd)

    reconciliation = %{
      node_id: node_id,
      estimated: %{input_tokens: est_input, output_tokens: est_output},
      exact: %{
        input_tokens: exact_input,
        output_tokens: exact_output,
        reasoning_tokens: exact_reasoning,
        cached_tokens: exact_cached
      },
      drift: %{
        input_tokens: if(exact_input && est_input, do: exact_input - est_input),
        output_tokens: if(exact_output && est_output, do: exact_output - est_output)
      }
    }

    %{
      event_id: make_event_id(),
      trace_id: trace_id,
      event_type: :usage_reconciled,
      timestamp: now_iso(),
      span_id: span_id,
      parent_span_id: nil,
      run_id: nil,
      session_id: session_id,
      node: nil,
      transfer: %{
        kind: :model_output,
        source_node_id: node_id,
        token_count: exact_output,
        token_class: :output_tokens,
        accounting: :reconciled
      },
      metrics: if(cost_usd, do: %{cost_usd: cost_usd}, else: nil),
      extra: %{reconciliation: reconciliation}
    }
  end

  @doc "Serialize a trace event to JSON."
  @spec to_json(trace_event()) :: String.t()
  def to_json(event) do
    Jason.encode!(event)
  end

  @doc "Deserialize a trace event from JSON."
  @spec from_json(String.t()) :: trace_event()
  def from_json(json_str) do
    Jason.decode!(json_str, keys: :atoms)
  end
end
