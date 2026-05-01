defmodule CodePuppyControl.Pack.DistributedSupervisor do
  @moduledoc """
  DynamicSupervisor for remote pack worker nodes.

  Manages one `RemoteNodeSupervisor` child per configured remote Erlang node.
  When a node connects, a child supervisor is started; when it disconnects,
  the child is shut down (transient restart strategy).

  ## Architecture

  ```
  DistributedSupervisor (DynamicSupervisor)
  ├── RemoteNodeSupervisor(:worker_a)    # Child for node :pup_worker_a@host
  │   └── RemoteNodeProxy                # GenServer holding connection state + dispatch
  ├── RemoteNodeSupervisor(:worker_b)    # Child for node :pup_worker_b@host
  │   └── RemoteNodeProxy
  └── ...
  ```

  ## Lifecycle

  1. `add_node/1` is called by `NodeMonitor` when a remote node connects.
  2. A `RemoteNodeSupervisor` is started under this DynamicSupervisor.
  3. `RemoteNodeSupervisor` starts a `RemoteNodeProxy` GenServer.
  4. On node disconnection, `NodeMonitor` calls `remove_node/1`.
  5. The `RemoteNodeSupervisor` and its children are shut down.
  6. On reconnection, a fresh `RemoteNodeSupervisor` is started.

  ## Protocol

  Dispatch to a remote worker via `dispatch/3`:

      DistributedSupervisor.dispatch(:pup_worker@host, :terrier, %{
        worktree_path: "../worktrees/feature-x",
        branch: "feature-x",
        task_description: "Create worktree for feature X"
      })

  ## Design Decisions

  - **DynamicSupervisor** is used instead of a static list so nodes can
    come and go without supervision tree restarts.
  - **Transient restart** on `RemoteNodeSupervisor` means disconnected nodes
    are NOT automatically reconnected — `NodeMonitor` handles reconnection
    on the heartbeat interval.
  - **One supervisor per node** isolates crashes: if one remote node's proxy
    state becomes corrupted, it doesn't affect other nodes.

  ## References

  - Design doc: [docs/distributed-packs.md](../../../../docs/distributed-packs.md)
  - §5.1 Leader-side additions
  - §8.1 Remote Node Disconnection
  """

  use DynamicSupervisor

  require Logger

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the DistributedSupervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a remote node to the cluster.

  Called by `NodeMonitor` when a node connects. Starts a
  `RemoteNodeSupervisor` child for the given node atom.

  Returns `{:ok, pid}` on success, `{:error, {:already_present, pid}}` if the
  node is already tracked, or `{:error, reason}` on failure.

  ## Examples

      iex> DistributedSupervisor.add_node(:pup_worker_01@myhost)
      {:ok, #PID<0.123.0>}
  """
  @spec add_node(node()) :: {:ok, pid()} | {:error, term()}
  def add_node(node_name) when is_atom(node_name) do
    child_spec = %{
      id: {:remote_node_supervisor, node_name},
      start: {CodePuppyControl.Pack.RemoteNodeSupervisor, :start_link, [node_name]},
      type: :supervisor,
      restart: :transient,
      shutdown: 5_000
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info(
          "DistributedPack: added remote node #{inspect(node_name)} (pid: #{inspect(pid)})"
        )

        :telemetry.execute(
          [:code_puppy, :distributed_pack, :node, :supervised],
          %{count: DynamicSupervisor.count_children(__MODULE__).active},
          %{node: node_name}
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug(
          "DistributedPack: node #{inspect(node_name)} already supervised (pid: #{inspect(pid)})"
        )

        {:error, {:already_present, pid}}

      {:error, reason} ->
        Logger.warning(
          "DistributedPack: failed to add node #{inspect(node_name)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Removes a remote node from the cluster.

  Called by `NodeMonitor` when a node disconnects. Shuts down the
  `RemoteNodeSupervisor` and its `RemoteNodeProxy`. In-flight runs on the
  disconnected node are marked as failed.

  ## Examples

      iex> DistributedSupervisor.remove_node(:pup_worker_01@myhost)
      :ok
  """
  @spec remove_node(node()) :: :ok | {:error, :not_found}
  def remove_node(node_name) when is_atom(node_name) do
    child_id = {:remote_node_supervisor, node_name}

    case DynamicSupervisor.terminate_child(__MODULE__, child_id) do
      :ok ->
        Logger.info("DistributedPack: removed remote node #{inspect(node_name)}")

        :telemetry.execute(
          [:code_puppy, :distributed_pack, :node, :removed],
          %{count: DynamicSupervisor.count_children(__MODULE__).active},
          %{node: node_name}
        )

        :ok

      {:error, :not_found} ->
        Logger.debug("DistributedPack: node #{inspect(node_name)} not found for removal")
        {:error, :not_found}
    end
  end

  @doc """
  Dispatches a sub-agent run to a specific remote worker.

  Returns `{:ok, run_id}` on successful dispatch, or `{:error, reason}` if
  the node is not connected or the dispatch was rejected.

  The actual execution is asynchronous — results arrive via
  `{:result, run_id, payload}` casts from the worker.

  ## Examples

      iex> DistributedSupervisor.dispatch(
      ...>   :pup_worker_01@myhost,
      ...>   :terrier,
      ...>   %{worktree_path: "../wt/feat-x", task_description: "Create worktree"}
      ...> )
      {:ok, "run_abc123"}
  """
  @spec dispatch(node(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def dispatch(node_name, sub_agent, params)
      when is_atom(node_name) and is_atom(sub_agent) and is_map(params) do
    # Find the proxy pid for this node via the child ID lookup
    child_id = {:remote_node_supervisor, node_name}

    case which_children_node(child_id) do
      {:ok, proxy_pid} ->
        # Delegate to the RemoteNodeProxy GenServer (it handles the actual
        # GenServer.call/cast to the remote worker)
        CodePuppyControl.Pack.RemoteNodeProxy.dispatch(proxy_pid, sub_agent, params)

      {:error, :not_found} ->
        {:error, {:node_not_connected, node_name}}
    end
  end

  @doc """
  Lists all currently supervised remote nodes.

  ## Examples

      iex> DistributedSupervisor.list_nodes()
      [:"pup_worker_01@myhost", :"pup_worker_02@otherhost"]
  """
  @spec list_nodes() :: [node()]
  def list_nodes do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {{:remote_node_supervisor, _node_name}, pid, :supervisor, _modules} ->
        # Get the node name from the proxy's state
        case CodePuppyControl.Pack.RemoteNodeProxy.node_name(pid) do
          {:ok, name} -> [name]
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Returns the current cluster status summary.
  """
  @spec status() :: %{
          connected: [node()],
          workers_active: non_neg_integer(),
          workers_total: non_neg_integer()
        }
  def status do
    connected = list_nodes()

    %{
      connected: connected,
      workers_active: length(connected),
      workers_total: DynamicSupervisor.count_children(__MODULE__).active
    }
  end

  # ── DynamicSupervisor Callbacks ──────────────────────────────────────────

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 0, max_seconds: 1)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  # Finds the RemoteNodeProxy pid for a given child_id by walking which_children.
  # The child is a RemoteNodeSupervisor; its single child is the RemoteNodeProxy.
  defp which_children_node(child_id) do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.find_value({:error, :not_found}, fn
      {^child_id, sup_pid, :supervisor, _modules} when is_pid(sup_pid) ->
        # Walk into the RemoteNodeSupervisor to find its RemoteNodeProxy child
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value({:error, :not_found}, fn
          {:remote_node_proxy, proxy_pid, :worker, _mods} when is_pid(proxy_pid) ->
            {:ok, proxy_pid}

          _ ->
            false
        end)

      _ ->
        false
    end)
  end
end
