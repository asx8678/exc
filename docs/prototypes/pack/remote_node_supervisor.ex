defmodule CodePuppyControl.Pack.RemoteNodeSupervisor do
  @moduledoc """
  Supervisor for a single remote pack worker node.

  Manages one `RemoteNodeProxy` GenServer child. The proxy holds the
  connection state for a remote Erlang node and provides the dispatch API.

  ## Strategy

  `:one_for_one` — if the proxy crashes, only it is restarted. The node
  must be reconnected via `NodeMonitor` to get a fresh proxy.

  ## Restart

  `:transient` — this supervisor is NOT automatically restarted by
  `DistributedSupervisor` on disconnect. The `NodeMonitor` heartbeat
  loop handles reconnection.

  ## References

  - Design doc §5.1: Leader-side supervision tree
  - Design doc §5.3: RemoteNodeSupervisor child spec
  """

  use Supervisor

  alias CodePuppyControl.Pack.RemoteNodeProxy

  @doc """
  Starts a RemoteNodeSupervisor for the given remote node.

  The node_name is an Erlang node atom, e.g. `:"pup_worker@host"`.
  """
  @spec start_link(node()) :: Supervisor.on_start()
  def start_link(node_name) when is_atom(node_name) do
    Supervisor.start_link(__MODULE__, node_name, name: via_name(node_name))
  end

  @doc """
  Returns the :via tuple for registering this supervisor under a unique name.
  """
  @spec via_name(node()) :: {:via, Registry, {:remote_node_supervisors, node()}}
  def via_name(node_name) do
    {:via, Registry, {:remote_node_supervisors, node_name}}
  end

  @impl true
  def init(node_name) when is_atom(node_name) do
    children = [
      %{
        id: :remote_node_proxy,
        start: {RemoteNodeProxy, :start_link, [node_name]},
        type: :worker,
        restart: :transient,
        shutdown: 5_000
      }
    ]

    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5,
      name: via_name(node_name)
    ]

    Supervisor.init(children, opts)
  end
end
