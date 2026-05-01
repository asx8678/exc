defmodule CodePuppyControl.Pack.RemoteNodeProxy do
  @moduledoc """
  GenServer representing a connection to a single remote pack worker node.

  This proxy holds the connection state for a remote Erlang node running a
  `PackWorker`. It provides the dispatch interface for sending sub-agent
  runs to the remote node and tracks in-flight executions.

  ## State

  - `node_name` — the remote Erlang node atom
  - `status` — `:connecting` | `:connected` | `:disconnected`
  - `capabilities` — last advertised capabilities map from the worker, or `nil`
  - `active_runs` — map of `%{run_id => run_info}` for in-flight dispatches
  - `node_ref` — reference for internal event correlation

  ## Lifecycle

  1. `start_link/1` called by `RemoteNodeSupervisor`.
  2. On init, calls `Node.monitor/2` and attempts capability handshake.
  3. On `{:nodeup, node}`, re-attempts handshake and transitions to `:connected`.
  4. On `{:nodedown, node}`, transitions to `:disconnected`.
  5. Dispatch is rejected unless status is `:connected`.

  ## Dispatch Protocol (per §6 & §11)

  All dispatches are **asynchronous** (cast-based) per §11.2. The leader
  sends a `:dispatch` cast to the remote worker and returns immediately
  with a `run_id`. Results arrive via `{:result, run_id, payload}` and
  `{:progress, run_id, msg}` casts from the worker.

  ## Telemetry

  - `[:code_puppy, :distributed_pack, :dispatch, :start]`
  - `[:code_puppy, :distributed_pack, :dispatch, :stop]`
  - `[:code_puppy, :distributed_pack, :dispatch, :exception]`
  - `[:code_puppy, :distributed_pack, :node, :connected]`
  - `[:code_puppy, :distributed_pack, :node, :disconnected]`
  - `[:code_puppy, :distributed_pack, :capabilities, :updated]`

  ## References

  - Design doc §5.3: RemoteNodeSupervisor child spec
  - Design doc §6: Message protocol
  - Design doc §11: Sync vs async dispatch
  """

  use GenServer

  require Logger

  # ── Types ────────────────────────────────────────────────────────────────

  @type status :: :connecting | :connected | :disconnected

  @type run_info :: %{
          run_id: String.t(),
          sub_agent: atom(),
          params: map(),
          started_at: integer(),
          status: :dispatched
        }

  @type state :: %{
          node_name: node(),
          status: status(),
          capabilities: map() | nil,
          active_runs: %{String.t() => run_info()},
          node_ref: reference(),
          handshake_fn: (node(), timeout() -> {:ok, map()} | {:error, term()}),
          handshake_timeout: timeout()
        }

  # ── Configuration ────────────────────────────────────────────────────────

  @default_handshake_timeout 30_000
  @worker_name :pack_worker

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Starts the proxy for a remote node.

  ## Options

  - `:node_name` — (required) the remote Erlang node atom
  - `:handshake_fn` — (optional) capability handshake function for testing;
    defaults to `&default_handshake/2`
  - `:monitor_fn` — (optional) node monitoring function for testing;
    defaults to `&Node.monitor/2`
  - `:handshake_timeout` — (optional) handshake timeout in ms (default 30_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    node_name = Keyword.fetch!(opts, :node_name)
    name = Keyword.get(opts, :name, via_name(node_name))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the via tuple for Registry-based process lookup.
  """
  @spec via_name(node()) :: {:via, Registry, {module(), node()}}
  def via_name(node_name) do
    {:via, Registry, {__MODULE__.Registry, node_name}}
  end

  @doc """
  Dispatches a sub-agent run to the remote worker.

  The dispatch is **asynchronous** per §11.2 — the leader sends a
  `:dispatch` cast to the remote worker and returns immediately with a
  `run_id`. Results arrive via `{:result, run_id, payload}` casts.

  Returns `{:ok, run_id}` on success, or `{:error, reason}` if the proxy
  is not in a connected state.

  ## Examples

      iex> RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "../wt"})
      {:ok, "dist_1717000000_28471032"}
  """
  @spec dispatch(pid(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def dispatch(proxy_pid, sub_agent, params)
      when is_pid(proxy_pid) and is_atom(sub_agent) and is_map(params) do
    GenServer.call(proxy_pid, {:dispatch, sub_agent, params})
  end

  @doc """
  Returns the current proxy status summary.
  """
  @spec status(pid()) :: map()
  def status(proxy_pid) when is_pid(proxy_pid) do
    GenServer.call(proxy_pid, :status)
  end

  @doc """
  Returns the node name tracked by this proxy.
  """
  @spec node_name(pid()) :: node()
  def node_name(proxy_pid) when is_pid(proxy_pid) do
    GenServer.call(proxy_pid, :node_name)
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
  def init(opts) do
    node_name = Keyword.fetch!(opts, :node_name)
    handshake_fn = Keyword.get(opts, :handshake_fn, &default_handshake/2)
    monitor_fn = Keyword.get(opts, :monitor_fn, &Node.monitor/2)
    handshake_timeout = Keyword.get(opts, :handshake_timeout, @default_handshake_timeout)

    # Start monitoring the remote node for up/down events.
    # Node.monitor/2 returns a boolean — we generate our own reference
    # for internal event correlation.
    monitor_fn.(node_name, true)
    node_ref = make_ref()

    state = %{
      node_name: node_name,
      status: :connecting,
      capabilities: nil,
      active_runs: %{},
      node_ref: node_ref,
      handshake_fn: handshake_fn,
      handshake_timeout: handshake_timeout
    }

    # Attempt initial capability handshake
    case handshake_fn.(node_name, handshake_timeout) do
      {:ok, caps} ->
        emit_node_telemetry(:connected, node_name, caps)
        {:ok, %{state | status: :connected, capabilities: caps}}

      {:error, _reason} ->
        Logger.warning(
          "[RemoteNodeProxy] initial handshake with #{inspect(node_name)} failed; " <>
            "waiting for :nodeup event"
        )

        {:ok, state}
    end
  end

  # ── Call Handlers ────────────────────────────────────────────────────────

  @impl true
  def handle_call(:node_name, _from, state) do
    {:reply, state.node_name, state}
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
      :connected ->
        do_dispatch(sub_agent, params, state)

      :disconnected ->
        {:reply, {:error, {:node_disconnected, state.node_name}}, state}

      :connecting ->
        {:reply, {:error, {:node_not_ready, state.node_name}}, state}
    end
  end

  # ── Node Monitor Events ──────────────────────────────────────────────────

  @impl true
  def handle_info({:nodeup, node_name}, %{node_name: node_name} = state) do
    Logger.info("[RemoteNodeProxy] node up: #{inspect(node_name)}")

    case state.handshake_fn.(node_name, state.handshake_timeout) do
      {:ok, caps} ->
        emit_node_telemetry(:connected, node_name, caps)
        {:noreply, %{state | status: :connected, capabilities: caps}}

      {:error, reason} ->
        Logger.warning(
          "[RemoteNodeProxy] re-handshake with #{inspect(node_name)} failed: #{inspect(reason)}"
        )

        # Stay in :connecting — next :nodeup will retry
        {:noreply, %{state | status: :connecting}}
    end
  end

  @impl true
  def handle_info({:nodedown, node_name}, %{node_name: node_name} = state) do
    Logger.warning("[RemoteNodeProxy] node down: #{inspect(node_name)}")

    # Mark all in-flight runs as failed
    state.active_runs
    |> Enum.each(fn {run_id, _info} ->
      :telemetry.execute(
        [:code_puppy, :distributed_pack, :dispatch, :exception],
        %{run_id: run_id, error: "node_disconnected"},
        %{node: state.node_name}
      )
    end)

    emit_node_telemetry(:disconnected, node_name, %{
      active_runs: Map.keys(state.active_runs)
    })

    {:noreply, %{state | status: :disconnected}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Worker Callback Casts ────────────────────────────────────────────────

  @impl true
  def handle_cast({:result, run_id, result}, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        Logger.warning("[RemoteNodeProxy] received result for unknown run: #{run_id}")
        {:noreply, state}

      run_info ->
        duration_ms =
          (System.monotonic_time() - run_info.started_at)
          |> System.convert_time_unit(:native, :millisecond)

        :telemetry.execute(
          [:code_puppy, :distributed_pack, :dispatch, :stop],
          %{run_id: run_id, duration_ms: duration_ms, status: result[:status]},
          %{node: state.node_name, sub_agent: run_info.sub_agent}
        )

        Logger.info(
          "[RemoteNodeProxy] run #{run_id} (#{run_info.sub_agent}) completed on " <>
            "#{inspect(state.node_name)}: #{result[:status]} in #{duration_ms}ms"
        )

        {:noreply, %{state | active_runs: Map.delete(state.active_runs, run_id)}}
    end
  end

  @impl true
  def handle_cast({:progress, run_id, progress_msg}, state) do
    if Map.has_key?(state.active_runs, run_id) do
      Logger.debug(
        "[RemoteNodeProxy] progress on #{run_id}: #{progress_msg[:type]} — #{progress_msg[:message]}"
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:capabilities, caps}, state) do
    Logger.info("[RemoteNodeProxy] capabilities updated for #{inspect(state.node_name)}")

    :telemetry.execute(
      [:code_puppy, :distributed_pack, :capabilities, :updated],
      %{node: state.node_name},
      %{capabilities: caps}
    )

    {:noreply, %{state | status: :connected, capabilities: caps}}
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp do_dispatch(sub_agent, params, state) do
    run_id = generate_run_id()

    # Dispatch message shape per §6.2
    dispatch_msg =
      {:dispatch,
       %{
         run_id: run_id,
         sub_agent: sub_agent,
         params: params,
         leader_node: node(),
         leader_pid: self()
       }}

    try do
      # Async cast to remote worker per §11.2
      GenServer.cast({@worker_name, state.node_name}, dispatch_msg)

      :telemetry.execute(
        [:code_puppy, :distributed_pack, :dispatch, :start],
        %{run_id: run_id},
        %{node: state.node_name, sub_agent: sub_agent}
      )

      run_info = %{
        run_id: run_id,
        sub_agent: sub_agent,
        params: params,
        started_at: System.monotonic_time(),
        status: :dispatched
      }

      {:reply, {:ok, run_id},
       %{state | active_runs: Map.put(state.active_runs, run_id, run_info)}}
    rescue
      e ->
        :telemetry.execute(
          [:code_puppy, :distributed_pack, :dispatch, :exception],
          %{run_id: run_id, error: Exception.message(e)},
          %{node: state.node_name, sub_agent: sub_agent}
        )

        {:reply, {:error, {:dispatch_failed, Exception.message(e)}}, state}
    end
  end

  @spec generate_run_id() :: String.t()
  defp generate_run_id do
    ms = System.system_time(:millisecond)
    hash = :erlang.phash2({self(), :erlang.unique_integer()})
    "dist_#{ms}_#{hash}"
  end

  @doc false
  @spec default_handshake(node(), timeout()) :: {:ok, map()} | {:error, term()}
  def default_handshake(node_name, timeout) do
    try do
      caps = GenServer.call({@worker_name, node_name}, :request_capabilities, timeout)
      {:ok, caps}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp emit_node_telemetry(:connected, node_name, caps) do
    :telemetry.execute(
      [:code_puppy, :distributed_pack, :node, :connected],
      %{node: node_name},
      %{capabilities: caps}
    )
  end

  defp emit_node_telemetry(:disconnected, node_name, extra) do
    :telemetry.execute(
      [:code_puppy, :distributed_pack, :node, :disconnected],
      %{node: node_name},
      extra
    )
  end
end
