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
  - `reconnect_attempts` — count of failed connection attempts since last
    successful handshake; reset to 0 on connect

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

  alias CodePuppyControl.Pack.NamingService

  # ── Types ────────────────────────────────────────────────────────────────────────

  @type status :: :connecting | :connected | :disconnected

  @type run_info :: %{
          run_id: String.t(),
          sub_agent: atom(),
          params: map(),
          started_at: integer(),
          status: :dispatched,
          timer_ref: reference() | nil,
          reply_to: pid() | nil
        }

  @type state :: %{
          node_name: node(),
          status: status(),
          capabilities: map() | nil,
          active_runs: %{String.t() => run_info()},
          node_ref: reference(),
          reconnect_attempts: non_neg_integer(),
          handshake_fn: (node(), timeout() -> {:ok, map()} | {:error, term()}),
          handshake_timeout: timeout(),
          dispatch_timeout: timeout()
        }

  # ── Configuration ────────────────────────────────────────────────────────

  @default_handshake_timeout 30_000
  @default_dispatch_timeout 30_000
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
  - `:dispatch_timeout` — (optional) per-run dispatch timeout in ms
    (default 30_000); lost results are cleaned up after this timeout
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
  @spec dispatch(GenServer.server(), atom(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch(proxy, sub_agent, params, opts \\ [])
      when is_atom(sub_agent) and is_map(params) and is_list(opts) do
    GenServer.call(proxy, {:dispatch, sub_agent, params, opts})
  end

  @doc """
  Returns the current proxy status summary.
  """
  @spec status(GenServer.server()) :: map()
  def status(proxy) do
    GenServer.call(proxy, :status)
  end

  @doc """
  Returns the node name tracked by this proxy.
  """
  @spec node_name(GenServer.server()) :: node()
  def node_name(proxy) do
    GenServer.call(proxy, :node_name)
  end

  @doc """
  Returns the last known capabilities from the remote worker.
  """
  @spec capabilities(GenServer.server()) :: map() | nil
  def capabilities(proxy) do
    GenServer.call(proxy, :capabilities)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    node_name = Keyword.fetch!(opts, :node_name)
    handshake_fn = Keyword.get(opts, :handshake_fn, &default_handshake/2)
    monitor_fn = Keyword.get(opts, :monitor_fn, &Node.monitor/2)
    handshake_timeout = Keyword.get(opts, :handshake_timeout, @default_handshake_timeout)
    dispatch_timeout = Keyword.get(opts, :dispatch_timeout, @default_dispatch_timeout)

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
      reconnect_attempts: 0,
      handshake_fn: handshake_fn,
      handshake_timeout: handshake_timeout,
      dispatch_timeout: dispatch_timeout
    }

    # Defer the initial handshake to handle_continue so supervisor
    # startup doesn't block for up to @default_handshake_timeout ms.
    {:ok, state, {:continue, :handshake}}
  end

  # ── Continue Handlers ───────────────────────────────────────────────────

  @impl true
  def handle_continue(:handshake, state) do
    case state.handshake_fn.(state.node_name, state.handshake_timeout) do
      {:ok, caps} ->
        emit_node_telemetry(:connected, state.node_name, caps)
        safe_register_naming(state.node_name, caps)
        {:noreply, %{state | status: :connected, capabilities: caps}}

      {:error, _reason} ->
        Logger.warning(
          "[RemoteNodeProxy] initial handshake with #{inspect(state.node_name)} failed; " <>
            "waiting for :nodeup event"
        )

        {:noreply, %{state | reconnect_attempts: 1}}
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
      capabilities: state.capabilities,
      reconnect_attempts: state.reconnect_attempts
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  @impl true
  def handle_call({:dispatch, sub_agent, params, opts}, _from, state) do
    case state.status do
      :connected ->
        do_dispatch(sub_agent, params, opts, state)

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
        safe_register_naming(node_name, caps)
        {:noreply, %{state | status: :connected, capabilities: caps, reconnect_attempts: 0}}

      {:error, reason} ->
        new_attempts = state.reconnect_attempts + 1

        Logger.warning(
          "[RemoteNodeProxy] re-handshake with #{inspect(node_name)} failed " <>
            "(attempt #{new_attempts}): #{inspect(reason)}"
        )

        # Stay in :connecting — next :nodeup will retry
        {:noreply, %{state | status: :connecting, reconnect_attempts: new_attempts}}
    end
  end

  @impl true
  def handle_info({:nodedown, node_name}, %{node_name: node_name} = state) do
    Logger.warning("[RemoteNodeProxy] node down: #{inspect(node_name)}")

    # Remove from NamingService so Dispatcher stops routing to this node
    safe_unregister_naming(node_name)

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

    # Cancel any outstanding dispatch timers for in-flight runs
    state.active_runs
    |> Enum.each(fn {_run_id, run_info} ->
      if run_info.timer_ref, do: Process.cancel_timer(run_info.timer_ref)
    end)

    {:noreply,
     %{
       state
       | status: :disconnected,
         active_runs: %{},
         reconnect_attempts: state.reconnect_attempts + 1
     }}
  end

  @impl true
  def handle_info({:dispatch_timeout, run_id}, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        # Already cleaned up (result arrived or nodedown)
        {:noreply, state}

      _run_info ->
        Logger.warning(
          "[RemoteNodeProxy] dispatch timeout for run #{run_id} on #{inspect(state.node_name)}"
        )

        :telemetry.execute(
          [:code_puppy, :distributed_pack, :dispatch, :exception],
          %{run_id: run_id, error: "dispatch_timeout"},
          %{node: state.node_name}
        )

        {:noreply, %{state | active_runs: Map.delete(state.active_runs, run_id)}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Worker Callback Casts ────────────────────────────────────────────────

  @impl true
  def handle_cast({:result, run_id, result}, state)
      when is_binary(run_id) and is_map(result) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        Logger.warning("[RemoteNodeProxy] received result for unknown run: #{run_id}")
        {:noreply, state}

      run_info ->
        # Cancel the dispatch timeout timer — result arrived in time
        if run_info.timer_ref, do: Process.cancel_timer(run_info.timer_ref)

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

        # Send result to caller if reply_to was requested
        if run_info.reply_to, do: send(run_info.reply_to, {:dispatch_result, run_id, result})

        {:noreply, %{state | active_runs: Map.delete(state.active_runs, run_id)}}
    end
  end

  # Guard clause: crash-safe from malformed remote data
  @impl true
  def handle_cast({:result, _run_id, _result}, state) do
    Logger.warning("[RemoteNodeProxy] received malformed result cast — ignoring")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:progress, run_id, progress_msg}, state)
      when is_binary(run_id) and is_map(progress_msg) do
    if Map.has_key?(state.active_runs, run_id) do
      Logger.debug(
        "[RemoteNodeProxy] progress on #{run_id}: #{progress_msg[:type]} — #{progress_msg[:message]}"
      )
    end

    {:noreply, state}
  end

  # Guard clause: crash-safe from malformed remote data
  @impl true
  def handle_cast({:progress, _run_id, _progress_msg}, state) do
    Logger.warning("[RemoteNodeProxy] received malformed progress cast — ignoring")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:capabilities, caps}, state) when is_map(caps) do
    Logger.info("[RemoteNodeProxy] capabilities updated for #{inspect(state.node_name)}")

    :telemetry.execute(
      [:code_puppy, :distributed_pack, :capabilities, :updated],
      %{node: state.node_name},
      %{capabilities: caps}
    )

    # Update NamingService with latest capabilities so Dispatcher routes correctly
    safe_register_naming(state.node_name, caps)

    {:noreply, %{state | status: :connected, capabilities: caps, reconnect_attempts: 0}}
  end

  # Guard clause: crash-safe from malformed capability casts
  @impl true
  def handle_cast({:capabilities, _caps}, state) do
    Logger.warning("[RemoteNodeProxy] received malformed capabilities cast — ignoring")
    {:noreply, state}
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp do_dispatch(sub_agent, params, opts, state) do
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

      timer_ref =
        Process.send_after(self(), {:dispatch_timeout, run_id}, state.dispatch_timeout)

      reply_to = Keyword.get(opts, :reply_to)

      run_info = %{
        run_id: run_id,
        sub_agent: sub_agent,
        params: params,
        started_at: System.monotonic_time(),
        status: :dispatched,
        timer_ref: timer_ref,
        reply_to: reply_to
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

  # ── NamingService Integration ─────────────────────────────────────────────────

  defp safe_register_naming(node_name, caps) do
    NamingService.register_node(node_name, caps)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_unregister_naming(node_name) do
    NamingService.unregister_node(node_name)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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
