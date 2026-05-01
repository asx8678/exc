defmodule CodePuppyControl.Pack.RemoteNodeProxy do
  @moduledoc """
  GenServer representing a connection to a single remote pack worker node.

  This proxy holds the connection state for a remote Erlang node that is a
  pack worker. It provides the dispatch interface for sending sub-agent runs
  to the remote node and tracks in-flight executions.

  ## State

      %{
        node_name: node(),                  # The remote Erlang node atom
        status: :connected | :disconnected,  # Current connection state
        capabilities: map() | nil,           # Last known capabilities from worker
        active_runs: %{run_id => run_info},  # In-flight sub-agent runs
        leader_ref: reference() | nil,       # Node.monitor/2 reference
        leader_pid: pid()                    # Our own pid (for worker callbacks)
      }

  ## Protocol (Leader → Worker)

  See design doc §6.2 for full message shapes. All inter-node messaging
  uses direct GenServer calls/casts over Erlang distribution — no PubSub.

  ## Lifecycle

  1. `start_link/1` is called by `RemoteNodeSupervisor.init/1`.
  2. On init, sets up `Node.monitor/2` for the remote node.
  3. Attempts initial capability handshake with the remote worker.
  4. On node-down, sets status to `:disconnected` and emits telemetry.
  5. On reconnection, `NodeMonitor` triggers a capability re-fetch.

  ## State Transitions

      :connecting  →  :connected  →  :disconnected  →  :reconnecting → ...
                (capabilities    (node-down)     (NodeMonitor heartbeat)
                 handshake OK)

  ## References

  - Design doc §5.3: RemoteNodeSupervisor child spec
  - Design doc §6: Message protocol
  - Design doc §11: Sync vs async dispatch
  """

  use GenServer

  require Logger

  # ── Configuration ────────────────────────────────────────────────────────

  @default_dispatch_timeout 30_000

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the proxy for a remote node.
  """
  @spec start_link(node()) :: GenServer.on_start()
  def start_link(node_name) when is_atom(node_name) do
    GenServer.start_link(__MODULE__, node_name, name: via_name(node_name))
  end

  @doc """
  Returns the :via tuple for registration.
  """
  @spec via_name(node()) :: {:via, Registry, {:remote_node_proxies, node()}}
  def via_name(node_name) do
    {:via, Registry, {:remote_node_proxies, node_name}}
  end

  @doc """
  Dispatches a sub-agent run to the remote worker.

  The dispatch is **asynchronous** — the leader sends a `:dispatch` cast to
  the remote worker and returns immediately with a `run_id`. Results arrive
  via `{:result, run_id, payload}` casts.

  Returns `{:ok, run_id}` or `{:error, {:node_disconnected, node}}` if the
  proxy is in disconnected state.

  ## Examples

      iex> RemoteNodeProxy.dispatch(proxy_pid, :terrier, %{worktree_path: "../wt"})
      {:ok, "run_abc123"}
  """
  @spec dispatch(pid(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def dispatch(proxy_pid, sub_agent, params)
      when is_pid(proxy_pid) and is_atom(sub_agent) and is_map(params) do
    GenServer.call(proxy_pid, {:dispatch, sub_agent, params})
  end

  @doc """
  Returns the node name tracked by this proxy.

  ## Examples

      iex> RemoteNodeProxy.node_name(proxy_pid)
      {:ok, :"pup_worker@host"}
  """
  @spec node_name(pid()) :: {:ok, node()}
  def node_name(proxy_pid) when is_pid(proxy_pid) do
    GenServer.call(proxy_pid, :node_name)
  end

  @doc """
  Returns current proxy status.

  ## Examples

      iex> RemoteNodeProxy.status(proxy_pid)
      %{
        node_name: :"pup_worker@host",
        status: :connected,
        active_runs: 2,
        capabilities: %{sub_agents: [:terrier, :watchdog], ...}
      }
  """
  @spec status(pid()) :: map()
  def status(proxy_pid) when is_pid(proxy_pid) do
    GenServer.call(proxy_pid, :status)
  end

  @doc """
  Returns the last known capabilities from the remote worker.
  """
  @spec capabilities(pid()) :: map() | nil
  def capabilities(proxy_pid) when is_pid(proxy_pid) do
    GenServer.call(proxy_pid, :capabilities)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(node_name) when is_atom(node_name) do
    # Start monitoring the remote node for up/down events
    node_ref = Node.monitor(node_name, true)

    state = %{
      node_name: node_name,
      status: :connecting,
      capabilities: nil,
      node_ref: node_ref,
      active_runs: %{},
      reconnect_attempts: 0
    }

    # Attempt initial capability handshake
    capabilities = try_capability_handshake(node_name)

    state =
      case capabilities do
        {:ok, caps} ->
          Logger.info("RemoteNodeProxy: connected to #{inspect(node_name)} with #{inspect(caps)}")
          %{state | status: :connected, capabilities: caps}

        {:error, reason} ->
          Logger.warning(
            "RemoteNodeProxy: initial handshake with #{inspect(node_name)} failed: #{inspect(reason)}"
          )

          %{state | status: :disconnected}
      end

    register_with_naming_service(node_name, state.capabilities)

    {:ok, state}
  end

  @impl true
  def handle_call(:node_name, _from, state) do
    {:reply, {:ok, state.node_name}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      node_name: state.node_name,
      status: state.status,
      active_runs: map_size(state.active_runs),
      capabilities: state.capabilities
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  @impl true
  def handle_call({:dispatch, sub_agent, params}, _from, state) do
    case state.status do
      :disconnected ->
        {:reply, {:error, {:node_disconnected, state.node_name}}, state}

      :connecting ->
        {:reply, {:error, {:node_not_ready, state.node_name}}, state}

      :connected ->
        # Generate a unique run ID
        run_id = generate_run_id()

        # Build the dispatch message per §6.2
        dispatch_msg = {
          :dispatch,
          %{
            run_id: run_id,
            sub_agent: sub_agent,
            params: params,
            leader_node: node(),
            leader_pid: self()
          }
        }

        # Send to remote worker via GenServer.cast (async per §11.2)
        # The remote PackWorker is registered via :global or :via
        worker_name = {:pack_worker, state.node_name}

        try do
          # GenServer.cast to remote registered name
          GenServer.cast({worker_name, state.node_name}, dispatch_msg)

          # Track the in-flight run
          run_info = %{
            run_id: run_id,
            sub_agent: sub_agent,
            params: params,
            started_at: System.monotonic_time(),
            status: :dispatched
          }

          :telemetry.execute(
            [:code_puppy, :distributed_pack, :dispatch, :start],
            %{run_id: run_id},
            %{node: state.node_name, sub_agent: sub_agent}
          )

          {:reply, {:ok, run_id},
           %{state | active_runs: Map.put(state.active_runs, run_id, run_info)}}
        rescue
          e in ArgumentError ->
            # Remote node might be unreachable
            {:reply, {:error, {:dispatch_failed, Exception.message(e)}}, state}
        end
    end
  end

  # ── Handle Node Monitor Events ───────────────────────────────────────────

  @impl true
  def handle_info({:nodeup, node_name, _node_ref}, state)
      when node_name == state.node_name do
    Logger.info("RemoteNodeProxy: node up detected for #{inspect(node_name)}")

    # Re-fetch capabilities
    case try_capability_handshake(node_name) do
      {:ok, caps} ->
        register_with_naming_service(node_name, caps)
        {:noreply, %{state | status: :connected, capabilities: caps, reconnect_attempts: 0}}

      {:error, reason} ->
        Logger.warning(
          "RemoteNodeProxy: re-handshake with #{inspect(node_name)} failed: #{inspect(reason)}"
        )

        {:noreply, %{state | status: :connecting}}
    end
  end

  @impl true
  def handle_info({:nodedown, node_name, _node_ref}, state)
      when node_name == state.node_name do
    Logger.warning("RemoteNodeProxy: node down detected for #{inspect(node_name)}")

    # Mark all in-flight runs as disconnected
    failed_runs =
      state.active_runs
      |> Enum.map(fn {run_id, info} ->
        :telemetry.execute(
          [:code_puppy, :distributed_pack, :dispatch, :exception],
          %{run_id: run_id, error: "node_disconnected"},
          %{node: state.node_name}
        )

        {run_id, %{info | status: :disconnected}}
      end)
      |> Map.new()

    unregister_from_naming_service(state.node_name)

    {:noreply, %{state | status: :disconnected, active_runs: failed_runs}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Handle Worker Results ─────────────────────────────────────────────────

  @impl true
  def handle_cast({:result, run_id, result}, state) do
    run_info = Map.get(state.active_runs, run_id)

    if run_info do
      duration_ms = System.monotonic_time() - run_info.started_at
      duration_ms = System.convert_time_unit(duration_ms, :native, :millisecond)

      :telemetry.execute(
        [:code_puppy, :distributed_pack, :dispatch, :stop],
        %{run_id: run_id, duration_ms: duration_ms, status: result.status},
        %{node: state.node_name, sub_agent: run_info.sub_agent}
      )

      Logger.info(
        "RemoteNodeProxy: run #{run_id} (#{run_info.sub_agent}) completed on " <>
          "#{inspect(state.node_name)}: #{result.status} in #{duration_ms}ms"
      )

      {:noreply, %{state | active_runs: Map.delete(state.active_runs, run_id)}}
    else
      Logger.warning("RemoteNodeProxy: received result for unknown run #{run_id}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:progress, run_id, progress_msg}, state) do
    # Progress updates are logged but do not change state
    if Map.has_key?(state.active_runs, run_id) do
      Logger.debug(
        "RemoteNodeProxy: progress on #{run_id}: #{progress_msg.type} — #{progress_msg.message}"
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:capabilities, caps}, state) do
    Logger.info(
      "RemoteNodeProxy: capabilities updated for #{inspect(state.node_name)}: #{inspect(caps)}"
    )

    register_with_naming_service(state.node_name, caps)

    {:noreply, %{state | status: :connected, capabilities: caps}}
  end

  # ── Private Helpers ───────────────────────────────────────────────────────

  defp generate_run_id do
    "dist_#{System.system_time(:millisecond)}_#{:erlang.phash2({self(), :erlang.unique_integer()})}"
  end

  defp try_capability_handshake(node_name) do
    worker_name = {:pack_worker, node_name}

    try do
      GenServer.call(
        {worker_name, node_name},
        :request_capabilities,
        @default_dispatch_timeout
      )
    rescue
      e ->
        {:error, Exception.message(e)}
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, {:noproc, _} -> {:error, :noproc}
    end
  end

  defp register_with_naming_service(_node_name, nil), do: :ok

  defp register_with_naming_service(node_name, caps) do
    # Delegate to NamingService to update the capability index
    CodePuppyControl.Pack.NamingService.register_node(node_name, caps)
  rescue
    # Gracefully degrade if NamingService isn't started
    _ -> :ok
  end

  defp unregister_from_naming_service(node_name) do
    CodePuppyControl.Pack.NamingService.unregister_node(node_name)
  rescue
    _ -> :ok
  end
end
