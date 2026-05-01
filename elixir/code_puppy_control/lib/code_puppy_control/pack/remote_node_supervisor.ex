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

  # ── Child Spec ──────────────────────────────────────────────────────────

  @doc false
  def child_spec(node_name) when is_atom(node_name) do
    %{
      id: {:remote_node, node_name},
      start: {__MODULE__, :start_link, [node_name]},
      type: :supervisor,
      restart: :transient
    }
  end

  def child_spec(opts) when is_list(opts) do
    node_name = Keyword.fetch!(opts, :node_name)
    start_opts = Keyword.delete(opts, :node_name)

    %{
      id: {:remote_node, node_name},
      start: {__MODULE__, :start_link, [node_name, start_opts]},
      type: :supervisor,
      restart: :transient
    }
  end

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Starts a `RemoteNodeSupervisor` for the given remote node.

  `node_name` is an Erlang node atom, e.g. `:"pup_worker@host"`.

  ## Options

  - `:proxy_opts` — keyword list of extra options forwarded to
    `RemoteNodeProxy.start_link/1` (e.g., `handshake_fn`, `monitor_fn`
    for testing). The `:node_name` key is always set to `node_name`.
  - `:name` — override the supervisor registration name (for testing
    without a Registry)
  """
  @spec start_link(node(), keyword()) :: Supervisor.on_start()
  def start_link(node_name, opts \\ []) when is_atom(node_name) and is_list(opts) do
    name = Keyword.get(opts, :name, via_name(node_name))
    Supervisor.start_link(__MODULE__, {node_name, opts}, name: name)
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
  def init({node_name, opts}) when is_atom(node_name) and is_list(opts) do
    proxy_opts =
      opts
      |> Keyword.get(:proxy_opts, [])
      |> Keyword.put(:node_name, node_name)

    children = [
      %{
        id: :remote_node_proxy,
        start: {RemoteNodeProxy, :start_link, [proxy_opts]},
        type: :worker,
        restart: :transient,
        shutdown: 5_000
      }
    ]

    supervisor_opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5
    ]

    Supervisor.init(children, supervisor_opts)
  end
end
