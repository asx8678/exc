defmodule CodePuppyControl.Pack.DistributedSupervisor do
  @moduledoc """
  DynamicSupervisor for remote pack worker nodes.

  Manages one `RemoteNodeSupervisor` child per connected remote Erlang node.
  When a node connects, a child supervisor is started; when it disconnects,
  the child is shut down (transient restart strategy — no auto-reconnect).

  ## Architecture

  ```
  DistributedSupervisor (DynamicSupervisor)
  ├── RemoteNodeSupervisor(:worker_a)    # Child for node :pup_worker_a@host
  │   └── RemoteNodeProxy                # GenServer holding connection + dispatch
  ├── RemoteNodeSupervisor(:worker_b)    # Child for node :pup_worker_b@host
  │   └── RemoteNodeProxy
  └── ...
  ```

  An ETS table (`:pack_distributed_supervisor_nodes` by default) stores the
  node_name → supervisor_pid mapping for O(1) lookups.

  ## Stale-pid Recovery

  When DynamicSupervisor restarts a child (abnormal exit, transient restart),
  the new child gets a new pid but the ETS entry still has the old pid.
  `add_node/2` detects stale pids and re-creates the entry.

  `resolve_supervisor_pid/2` provides restart-safe ETS lookup: if the ETS pid
  is dead, it falls back to `Registry.lookup/2` on
  `RemoteNodeSupervisor.Registry` to find the restarted child. If found, ETS
  is updated with the new pid. This means `list_nodes/1`, `dispatch/4`, and
  `find_proxy_pid/2` all auto-repair stale entries without caller intervention.

  ## Lifecycle

  1. `add_node/1` is called by `NodeMonitor` when a remote node connects.
  2. A `RemoteNodeSupervisor` is started under this DynamicSupervisor
     using `RemoteNodeSupervisor.child_spec/1`.
  3. `RemoteNodeSupervisor` starts a `RemoteNodeProxy` GenServer.
  4. On node disconnection, `NodeMonitor` calls `remove_node/1`.
  5. The `RemoteNodeSupervisor` and its children are shut down.
  6. On reconnection, a fresh `RemoteNodeSupervisor` is started.

  ## References

  - Design doc §5.1: Leader-side supervision tree
  - Design doc §8.1: Remote Node Disconnection
  """

  use DynamicSupervisor

  require Logger

  alias CodePuppyControl.Pack.RemoteNodeProxy
  alias CodePuppyControl.Pack.RemoteNodeSupervisor

  # ── Registration ──────────────────────────────────────────────────────────

  @default_name __MODULE__
  @default_ets :pack_distributed_supervisor_nodes

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the DistributedSupervisor.

  ## Options

  - `:name` — registration name (defaults to `__MODULE__`).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Adds a remote node to the cluster.

  Called by `NodeMonitor` when a node connects. Starts a
  `RemoteNodeSupervisor` child for the given node atom using
  `RemoteNodeSupervisor.child_spec/1`.

  Returns `{:ok, pid}` on success, or `{:error, {:already_present, pid}}`
  if the node is already tracked, or `{:error, reason}` on failure.
  """
  @spec add_node(node()) :: {:ok, pid()} | {:error, term()}
  @spec add_node(node(), atom() | keyword()) :: {:ok, pid()} | {:error, term()}
  def add_node(node_name, supervisor_or_opts \\ @default_name)
      when is_atom(node_name) do
    {supervisor_name, proxy_opts} = parse_supervisor_arg(supervisor_or_opts)
    ets_table = ets_name(supervisor_name)

    case :ets.lookup(ets_table, node_name) do
      [{^node_name, existing_pid}] when is_pid(existing_pid) ->
        if Process.alive?(existing_pid) do
          Logger.debug(
            "[DistributedSupervisor] node #{inspect(node_name)} already present " <>
              "(pid: #{inspect(existing_pid)})"
          )

          {:error, {:already_present, existing_pid}}
        else
          # Stale entry from a previous restart — clean up and retry
          :ets.delete(ets_table, node_name)
          do_add_node(node_name, supervisor_name, ets_table, proxy_opts)
        end

      _ ->
        do_add_node(node_name, supervisor_name, ets_table, proxy_opts)
    end
  end

  @doc """
  Removes a remote node from the cluster.

  Called by `NodeMonitor` when a node disconnects. Terminates the
  `RemoteNodeSupervisor` child and its `RemoteNodeProxy`. In-flight
  runs on the disconnected node are marked as failed by the proxy.
  """
  @spec remove_node(node()) :: :ok | {:error, :not_found}
  @spec remove_node(node(), atom()) :: :ok | {:error, :not_found}
  def remove_node(node_name, supervisor_name \\ @default_name)
      when is_atom(node_name) and is_atom(supervisor_name) do
    ets_table = ets_name(supervisor_name)

    case :ets.lookup(ets_table, node_name) do
      [{^node_name, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          case DynamicSupervisor.terminate_child(supervisor_name, pid) do
            :ok ->
              :ets.delete(ets_table, node_name)

              Logger.info("[DistributedSupervisor] removed node #{inspect(node_name)}")

              :telemetry.execute(
                [:code_puppy, :distributed_pack, :node, :removed],
                %{count: DynamicSupervisor.count_children(supervisor_name).active},
                %{node: node_name}
              )

              :ok

            {:error, reason} ->
              :ets.delete(ets_table, node_name)

              Logger.debug(
                "[DistributedSupervisor] terminate_child for #{inspect(node_name)} " <>
                  "returned #{inspect(reason)} (cleaned up ETS)"
              )

              :ok
          end
        else
          # Stale pid — just clean up ETS
          :ets.delete(ets_table, node_name)

          Logger.debug(
            "[DistributedSupervisor] stale pid for #{inspect(node_name)}, " <>
              "cleaned up ETS"
          )

          :ok
        end

      _ ->
        Logger.debug("[DistributedSupervisor] node #{inspect(node_name)} not found for removal")

        {:error, :not_found}
    end
  end

  @doc """
  Dispatches a sub-agent run to a specific remote worker.

  Delegates to `RemoteNodeProxy.dispatch/3` on the proxy for the given node.
  Returns `{:ok, run_id}` on successful dispatch, or `{:error, reason}` if
  the node is not connected or the dispatch was rejected.
  """
  @spec dispatch(node(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  @spec dispatch(node(), atom(), map(), atom()) :: {:ok, String.t()} | {:error, term()}
  def dispatch(node_name, sub_agent, params, supervisor_name \\ @default_name)
      when is_atom(node_name) and is_atom(sub_agent) and is_map(params) do
    ets_table = ets_name(supervisor_name)

    case find_proxy_pid(node_name, ets_table) do
      {:ok, proxy_pid} ->
        RemoteNodeProxy.dispatch(proxy_pid, sub_agent, params)

      {:error, :not_found} ->
        {:error, {:node_not_connected, node_name}}
    end
  end

  @doc """
  Returns a list of all currently supervised remote node atoms.

  Auto-repairs stale ETS entries via Registry lookup when
  DynamicSupervisor has restarted a child with a new pid.
  """
  @spec list_nodes() :: [node()]
  @spec list_nodes(atom()) :: [node()]
  def list_nodes(supervisor_name \\ @default_name) do
    ets_table = ets_name(supervisor_name)

    ets_table
    |> :ets.tab2list()
    |> Enum.reduce([], fn {node, pid}, acc ->
      if is_pid(pid) and Process.alive?(pid) do
        [node | acc]
      else
        # Try to resolve stale pid via Registry
        case resolve_supervisor_pid(node, ets_table) do
          {:ok, _pid} -> [node | acc]
          {:error, :not_found} -> acc
        end
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Returns the current cluster status summary.
  """
  @spec status() :: %{
          connected: [node()],
          workers_active: non_neg_integer(),
          workers_total: non_neg_integer()
        }
  @spec status(atom()) :: %{
          connected: [node()],
          workers_active: non_neg_integer(),
          workers_total: non_neg_integer()
        }
  def status(supervisor_name \\ @default_name) do
    connected = list_nodes(supervisor_name)
    counts = DynamicSupervisor.count_children(supervisor_name)

    %{
      connected: connected,
      workers_active: length(connected),
      workers_total: counts.active
    }
  end

  # ── DynamicSupervisor Callbacks ──────────────────────────────────────────

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, @default_name)
    ets_table = ets_name(name)

    case :ets.whereis(ets_table) do
      :undefined ->
        :ets.new(ets_table, [:set, :public, :named_table, read_concurrency: true])

      _ref ->
        :ets.delete_all_objects(ets_table)
    end

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp ets_name(@default_name), do: @default_ets
  defp ets_name(name) when is_atom(name), do: :"#{name}_nodes"

  defp parse_supervisor_arg(supervisor_name) when is_atom(supervisor_name) do
    {supervisor_name, []}
  end

  defp parse_supervisor_arg(opts) when is_list(opts) do
    supervisor_name = Keyword.get(opts, :supervisor_name, @default_name)
    proxy_opts = Keyword.get(opts, :proxy_opts, [])
    {supervisor_name, proxy_opts}
  end

  defp do_add_node(node_name, supervisor_name, ets_table, proxy_opts) do
    child_spec = build_child_spec(node_name, proxy_opts)

    case DynamicSupervisor.start_child(supervisor_name, child_spec) do
      {:ok, pid} ->
        :ets.insert(ets_table, {node_name, pid})

        Logger.info(
          "[DistributedSupervisor] added node #{inspect(node_name)} (pid: #{inspect(pid)})"
        )

        :telemetry.execute(
          [:code_puppy, :distributed_pack, :node, :supervised],
          %{count: DynamicSupervisor.count_children(supervisor_name).active},
          %{node: node_name}
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        :ets.insert(ets_table, {node_name, pid})

        Logger.debug(
          "[DistributedSupervisor] node #{inspect(node_name)} already present " <>
            "(pid: #{inspect(pid)})"
        )

        {:error, {:already_present, pid}}

      {:error, reason} ->
        Logger.warning(
          "[DistributedSupervisor] failed to add node #{inspect(node_name)}: " <>
            "#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp build_child_spec(node_name, []) do
    RemoteNodeSupervisor.child_spec(node_name)
  end

  defp build_child_spec(node_name, proxy_opts) do
    # When proxy_opts are provided (test mocks), the supervisor still
    # registers via Registry so resolve_supervisor_pid can find it
    # after DynamicSupervisor restarts the child.
    RemoteNodeSupervisor.child_spec(
      node_name: node_name,
      proxy_opts: proxy_opts
    )
  end

  defp resolve_supervisor_pid(node_name, ets_table) do
    case :ets.lookup(ets_table, node_name) do
      [{^node_name, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          # ETS has stale pid — try Registry for restarted child
          case Registry.lookup(CodePuppyControl.Pack.RemoteNodeSupervisor.Registry, node_name) do
            [{new_pid, _}] when is_pid(new_pid) ->
              # Found restarted child — update ETS
              :ets.insert(ets_table, {node_name, new_pid})
              {:ok, new_pid}

            _ ->
              # No replacement found — clean up stale entry
              :ets.delete(ets_table, node_name)
              {:error, :not_found}
          end
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp find_proxy_pid(node_name, ets_table) do
    case resolve_supervisor_pid(node_name, ets_table) do
      {:ok, sup_pid} ->
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value({:error, :not_found}, fn
          {:remote_node_proxy, proxy_pid, :worker, _mods} when is_pid(proxy_pid) ->
            {:ok, proxy_pid}

          _ ->
            false
        end)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
