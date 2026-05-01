defmodule CodePuppyControl.Pack.RemoteNodeSupervisor do
  @moduledoc """
  One-for-one Supervisor wrapping a single `RemoteNodeProxy` child.

  Each remote worker node gets its own `RemoteNodeSupervisor` instance,
  started under the `DistributedSupervisor` DynamicSupervisor. If the
  proxy crashes, only it is restarted. The node must be reconnected via
  `NodeMonitor` to restore the connection.

  ## Strategy

  `:one_for_one` — if the proxy GenServer crashes, only it is restarted.
  The proxy's `:transient` restart means it won't restart on normal
  termination (e.g., clean disconnect), only on abnormal exits.

  ## Restart Limits

  - `max_restarts: 3`
  - `max_seconds: 5`

  If the proxy crashes more than 3 times in 5 seconds, this supervisor
  itself crashes, and the `DistributedSupervisor` or operator handles
  recovery.

  ## References

  - Design doc §5.1: Leader-side supervision tree
  - Design doc §5.3: RemoteNodeSupervisor child spec
  """

  use Supervisor

  alias CodePuppyControl.Pack.RemoteNodeProxy

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Starts a `RemoteNodeSupervisor` for the given remote node.

  `node_name` is an Erlang node atom, e.g. `:"pup_worker@host"`.
  """
  @spec start_link(node()) :: Supervisor.on_start()
  def start_link(node_name) when is_atom(node_name) do
    Supervisor.start_link(__MODULE__, node_name, name: via_name(node_name))
  end

  @doc """
  Returns the via tuple for Registry-based supervisor lookup.
  """
  @spec via_name(node()) :: {:via, Registry, {module(), node()}}
  def via_name(node_name) do
    {:via, Registry, {__MODULE__.Registry, node_name}}
  end

  # ── Supervisor Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(node_name) when is_atom(node_name) do
    children = [
      %{
        id: :remote_node_proxy,
        start: {RemoteNodeProxy, :start_link, [[node_name: node_name]]},
        type: :worker,
        restart: :transient,
        shutdown: 5_000
      }
    ]

    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5
    ]

    Supervisor.init(children, opts)
  end
end
