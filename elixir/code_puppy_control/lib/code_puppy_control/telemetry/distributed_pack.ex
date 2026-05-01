defmodule CodePuppyControl.Telemetry.DistributedPack do
  @moduledoc """
  Telemetry helpers for distributed pack events.

  Emits events defined in `docs/distributed-packs.md §14` for node lifecycle,
  dispatch lifecycle, and capability changes in the multi-node pack cluster.

  These functions were extracted from `CodePuppyControl.Telemetry` to keep
  the parent module under the 600-line cap. The parent module delegates to
  these functions for backward compatibility.

  ## Events

  ### Node Lifecycle

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :distributed_pack, :node, :connected]` | `system_time`, `monotonic_time` | `node`, `capabilities` |
  | `[:code_puppy, :distributed_pack, :node, :disconnected]` | `system_time`, `monotonic_time` | `node`, `active_runs`, `reason` |
  | `[:code_puppy, :distributed_pack, :node, :reconnected]` | `system_time`, `monotonic_time` | `node`, `grace_period_ms` |

  ### Dispatch Lifecycle

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :distributed_pack, :dispatch, :start]` | `system_time`, `monotonic_time` | `run_id`, `sub_agent`, `target_node` |
  | `[:code_puppy, :distributed_pack, :dispatch, :stop]` | `duration_ms`, `system_time` | `run_id`, `status`, `duration_ms` |
  | `[:code_puppy, :distributed_pack, :dispatch, :exception]` | `system_time`, `monotonic_time` | `run_id`, `error` |

  ### Capability Events

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :distributed_pack, :capabilities, :updated]` | `system_time`, `monotonic_time` | `node`, `capabilities` |
  """

  @event_prefix [:code_puppy, :distributed_pack]

  # ============================================================================
  # Node Lifecycle Events
  # ============================================================================

  @doc """
  Emits a node-connected event when a worker node joins the cluster.

  ## Examples

      Telemetry.DistributedPack.node_connected(Node.self(), %{sub_agents: [:terrier]})
  """
  @spec node_connected(node(), map()) :: :ok
  def node_connected(node, capabilities) do
    :telemetry.execute(
      @event_prefix ++ [:node, :connected],
      base_measurements(),
      %{node: node, capabilities: capabilities}
    )
  end

  @doc """
  Emits a node-disconnected event when a worker node leaves the cluster.

  Includes the list of active run IDs that were in-flight on that node.

  ## Examples

      Telemetry.DistributedPack.node_disconnected(Node.self(), ["run-1"], :nodedown)
  """
  @spec node_disconnected(node(), [String.t()], term()) :: :ok
  def node_disconnected(node, active_runs, reason) do
    :telemetry.execute(
      @event_prefix ++ [:node, :disconnected],
      base_measurements(),
      %{node: node, active_runs: active_runs, reason: reason}
    )
  end

  @doc """
  Emits a node-reconnected event when a previously-disconnected worker reconnects.

  ## Examples

      Telemetry.DistributedPack.node_reconnected(Node.self(), 30_000)
  """
  @spec node_reconnected(node(), non_neg_integer()) :: :ok
  def node_reconnected(node, grace_period_ms) do
    :telemetry.execute(
      @event_prefix ++ [:node, :reconnected],
      base_measurements(),
      %{node: node, grace_period_ms: grace_period_ms}
    )
  end

  # ============================================================================
  # Dispatch Lifecycle Events
  # ============================================================================

  @doc """
  Emits a dispatch-start event when the leader dispatches a sub-agent to a worker.

  ## Examples

      Telemetry.DistributedPack.dispatch_start("run-123", :terrier, Node.self())
  """
  @spec dispatch_start(String.t(), atom(), node()) :: :ok
  def dispatch_start(run_id, sub_agent, target_node) do
    :telemetry.execute(
      @event_prefix ++ [:dispatch, :start],
      base_measurements(),
      %{run_id: run_id, sub_agent: sub_agent, target_node: target_node}
    )
  end

  @doc """
  Emits a dispatch-stop event when a dispatched sub-agent completes.

  ## Examples

      Telemetry.DistributedPack.dispatch_stop("run-123", :ok, 1_500)
  """
  @spec dispatch_stop(String.t(), atom(), non_neg_integer()) :: :ok
  def dispatch_stop(run_id, status, duration_ms) do
    :telemetry.execute(
      @event_prefix ++ [:dispatch, :stop],
      %{duration_ms: duration_ms, system_time: System.system_time(:millisecond)},
      %{run_id: run_id, status: status, duration_ms: duration_ms}
    )
  end

  @doc """
  Emits a dispatch-exception event when a dispatched sub-agent crashes.

  ## Examples

      Telemetry.DistributedPack.dispatch_exception("run-123", "unsupported_sub_agent")
  """
  @spec dispatch_exception(String.t(), String.t()) :: :ok
  def dispatch_exception(run_id, error) do
    :telemetry.execute(
      @event_prefix ++ [:dispatch, :exception],
      base_measurements(),
      %{run_id: run_id, error: error}
    )
  end

  # ============================================================================
  # Capability Events
  # ============================================================================

  @doc """
  Emits a capabilities-updated event when a worker advertises new capabilities.

  ## Examples

      Telemetry.DistributedPack.capabilities_updated(Node.self(), %{sub_agents: [:terrier]})
  """
  @spec capabilities_updated(node(), map()) :: :ok
  def capabilities_updated(node, capabilities) do
    :telemetry.execute(
      @event_prefix ++ [:capabilities, :updated],
      base_measurements(),
      %{node: node, capabilities: capabilities}
    )
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @spec base_measurements() :: map()
  defp base_measurements do
    %{
      system_time: System.system_time(:millisecond),
      monotonic_time: System.monotonic_time(:millisecond)
    }
  end
end
