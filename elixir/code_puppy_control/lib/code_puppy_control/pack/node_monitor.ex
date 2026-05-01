defmodule CodePuppyControl.Pack.NodeMonitor do
  @moduledoc """
  Monitors remote Erlang nodes for pack cluster membership.

  This GenServer runs a heartbeat loop that:

  - Tracks node up/down events via `Node.monitor/2`
  - Attempts reconnection to disconnected nodes on each heartbeat interval
  - Updates the `DistributedSupervisor` when nodes connect/disconnect
  - Emits telemetry for cluster state changes

  ## Heartbeat Loop

  On every heartbeat interval (configurable, default 15s):

  1. Read the configured worker list from Application env.
  2. For each configured worker:
     - If not already connected, attempt `Node.connect/1` **asynchronously**
       via a Task with the configured `connect_timeout`.
     - On success, update ETS + state and call `DistributedSupervisor.add_node/1`.
     - On failure, log and increment retry count.
  3. For each connected node no longer in config, remove it.

  ## Grace Period

  When a node disconnects, it enters a grace period (`disconnect_timeout`,
  default 30s) during which `Node.connect/1` is retried **on every heartbeat**.
  If the grace period expires, the node becomes `:lost` — but the configured
  worker remains eligible for future retry (needs a new `:nodeup` event or
  re-check trigger).

  ## Async Connection

  `Node.connect/1` can block on slow or unreachable hosts. The monitor spawns
  a `Task` for each connection attempt, respecting `connect_timeout`. The
  GenServer is never blocked waiting on a connect.

  ## ETS Table

  The `:pack_node_monitor_state` table provides fast read-heavy lookups
  for node state. It is created on init and cleaned up on terminate.

  ## Disabled Mode

  When `enabled: false` (the default), the monitor starts but does not
  schedule heartbeats or attempt connections. It logs a single info
  message and returns `{:ok, state}` without scheduling work.

  ## Configuration (`:code_puppy_control, :distributed_packs`)

  ```
  config :code_puppy_control, :distributed_packs,
    enabled: false,
    workers: [],
    heartbeat_interval: 15_000,
    disconnect_timeout: 30_000,
    connect_timeout: 5_000
  ```

  ## References

  - Design doc §7.2: Boot sequence (Leader)
  - Design doc §8.1: Remote Node Disconnection
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Pack.DistributedSupervisor

  # ── Configuration ────────────────────────────────────────────────────────

  @default_heartbeat_interval 15_000
  @default_disconnect_timeout 30_000
  @default_connect_timeout 5_000

  @ets_table :pack_node_monitor_state

  # ── Types ────────────────────────────────────────────────────────────────

  @type node_state_status :: :connected | :disconnected | :lost

  @type node_state :: %{
          status: node_state_status(),
          grace_until: non_neg_integer() | nil,
          retry_count: non_neg_integer()
        }

  @type state :: %{
          configured_workers: [String.t()],
          heartbeat_interval: pos_integer(),
          disconnect_timeout: pos_integer(),
          connect_timeout: pos_integer(),
          enabled: boolean(),
          node_states: %{node() => node_state()},
          proxy_opts: keyword(),
          supervisor_name: atom(),
          connect_fn: (node() -> boolean() | :ignored),
          monitor_fn: (node(), boolean() -> boolean())
        }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the NodeMonitor.

  ## Options

  All options override values from Application env:

  - `:enabled` — boolean (default: false)
  - `:workers` — list of worker node name strings (default: [])
  - `:heartbeat_interval` — ms between heartbeats (default: 15_000)
  - `:disconnect_timeout` — ms grace period before removing node (default: 30_000)
  - `:connect_timeout` — ms timeout for connect attempts (default: 5_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current cluster state.
  """
  @spec status() :: %{
          configured_workers: [String.t()],
          connected_nodes: [node()],
          disconnected_nodes: [node()],
          grace_period_nodes: [node()]
        }
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Returns the list of configured worker node names.
  """
  @spec configured_workers() :: [String.t()]
  def configured_workers do
    GenServer.call(__MODULE__, :configured_workers)
  end

  @doc """
  Triggers an immediate cluster re-evaluation via cast.
  """
  @spec recheck() :: :ok
  def recheck do
    GenServer.cast(__MODULE__, :recheck)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Create or reuse ETS table for fast read-heavy node-state lookups.
    # Named tables survive across process restarts, so we must handle
    # the case where a previous monitor left the table behind.
    create_ets_table()

    config = load_config(opts)

    state = %{
      configured_workers: config.workers,
      heartbeat_interval: config.heartbeat_interval,
      disconnect_timeout: config.disconnect_timeout,
      connect_timeout: config.connect_timeout,
      enabled: config.enabled,
      node_states: %{},
      proxy_opts: config.proxy_opts,
      supervisor_name: config.supervisor_name,
      connect_fn: config.connect_fn,
      monitor_fn: config.monitor_fn
    }

    if state.enabled do
      Logger.info(
        "[NodeMonitor] distributed packs enabled, " <>
          "#{length(state.configured_workers)} workers configured"
      )

      # Monitor all known nodes for up/down events
      Enum.each(state.configured_workers, &monitor_node/1)

      {:ok, state, {:continue, :initial_connect}}
    else
      Logger.info("[NodeMonitor] distributed packs disabled (set enabled: true to enable)")

      {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    # Clean up ETS table so a fresh NodeMonitor starts clean.
    # If the table doesn't exist (e.g., disabled startup), that's fine.
    try do
      :ets.delete(@ets_table)
    rescue
      _ -> :ok
    end

    :ok
  end

  @impl true
  def handle_continue(:initial_connect, state) do
    # Don't connect immediately — defer to first heartbeat.
    # This gives tests time to inject {:nodeup}/{:nodedown} messages
    # before any async connect tasks race with them.
    schedule_heartbeat(state.heartbeat_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {connected, disconnected, grace} = categorize_nodes(state.node_states)

    reply = %{
      configured_workers: state.configured_workers,
      connected_nodes: connected,
      disconnected_nodes: disconnected,
      grace_period_nodes: grace
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:configured_workers, _from, state) do
    {:reply, state.configured_workers, state}
  end

  @impl true
  def handle_cast(:recheck, state) do
    state = attempt_all_connections(state)
    {:noreply, state}
  end

  # ── Heartbeat ────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:heartbeat, state) do
    state =
      state
      |> check_grace_periods()
      |> attempt_all_connections()
      |> remove_stale_nodes()

    schedule_heartbeat(state.heartbeat_interval)
    {:noreply, state}
  end

  # ── Node Monitor Events ─────────────────────────────────────────────────

  @impl true
  def handle_info({:nodeup, node_name}, state) do
    Logger.info("[NodeMonitor] node up detected: #{inspect(node_name)}")

    new_state = %{
      status: :connected,
      grace_until: nil,
      retry_count: 0
    }

    :ets.insert(@ets_table, {node_name, new_state})

    node_states = Map.put(state.node_states, node_name, new_state)

    # Notify DistributedSupervisor (best-effort — may already be added)
    safe_add_node(node_name, state)

    {:noreply, %{state | node_states: node_states}}
  end

  @impl true
  def handle_info({:nodedown, node_name}, state) do
    Logger.warning("[NodeMonitor] node down detected: #{inspect(node_name)}")

    grace_until = System.monotonic_time(:millisecond) + state.disconnect_timeout

    existing_retries =
      case Map.get(state.node_states, node_name) do
        %{retry_count: count} -> count
        _ -> 0
      end

    new_state = %{
      status: :disconnected,
      grace_until: grace_until,
      retry_count: existing_retries + 1
    }

    :ets.insert(@ets_table, {node_name, new_state})

    node_states = Map.put(state.node_states, node_name, new_state)

    :telemetry.execute(
      [:code_puppy, :distributed_pack, :node, :disconnected],
      %{grace_period_ms: state.disconnect_timeout},
      %{node: node_name}
    )

    {:noreply, %{state | node_states: node_states}}
  end

  @impl true
  def handle_info({:connect_result, node_atom, worker_name, result}, state) do
    state = handle_connect_result(state, node_atom, worker_name, result)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp create_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])

      _ref ->
        # Table already exists (e.g., from a previous NodeMonitor instance).
        # Wipe it clean so we start fresh.
        :ets.delete_all_objects(@ets_table)
    end
  end

  defp load_config(opts) do
    app_config = Application.get_env(:code_puppy_control, :distributed_packs, [])

    %{
      enabled: Keyword.get(opts, :enabled, Keyword.get(app_config, :enabled, false)),
      workers:
        Keyword.get(opts, :workers, Keyword.get(app_config, :workers, []))
        |> normalize_workers(),
      heartbeat_interval:
        Keyword.get(
          opts,
          :heartbeat_interval,
          Keyword.get(app_config, :heartbeat_interval, @default_heartbeat_interval)
        ),
      disconnect_timeout:
        Keyword.get(
          opts,
          :disconnect_timeout,
          Keyword.get(app_config, :disconnect_timeout, @default_disconnect_timeout)
        ),
      connect_timeout:
        Keyword.get(
          opts,
          :connect_timeout,
          Keyword.get(app_config, :connect_timeout, @default_connect_timeout)
        ),
      proxy_opts: Keyword.get(opts, :proxy_opts, []),
      supervisor_name: Keyword.get(opts, :supervisor_name, DistributedSupervisor),
      connect_fn: Keyword.get(opts, :connect_fn, &Node.connect/1),
      monitor_fn: Keyword.get(opts, :monitor_fn, &Node.monitor/2)
    }
  end

  defp normalize_workers(workers) when is_list(workers), do: workers
  defp normalize_workers(""), do: []

  defp normalize_workers(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp normalize_workers(_), do: []

  defp monitor_node(worker_name) do
    node_atom = String.to_atom(worker_name)
    Node.monitor(node_atom, true)
  rescue
    _ -> :ok
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp attempt_all_connections(state) do
    Enum.reduce(state.configured_workers, state, fn worker_name, acc ->
      node_atom = String.to_atom(worker_name)

      cond do
        # Already connected — skip
        node_connected?(acc.node_states, node_atom) ->
          acc

        # Lost (grace expired) — skip, needs fresh :nodeup or recheck
        node_lost?(acc.node_states, node_atom) ->
          acc

        # Disconnected (including in grace period) — try async connect
        true ->
          attempt_connect_async(acc, node_atom, worker_name)
      end
    end)
  end

  defp attempt_connect_async(state, node_atom, worker_name) do
    caller = self()
    timeout = state.connect_timeout

    # Spawn an unlinked temp process for async connect — Node.connect/1 can
    # block on slow/unreachable hosts, so we don't want to block the GenServer.
    # The connect_timeout from config is respected via Task.yield/2.
    Task.start(fn ->
      result =
        Task.async(fn -> state.connect_fn.(node_atom) end)
        |> Task.yield(timeout)
        |> case do
          {:ok, {:ok, connect_result}} -> connect_result
          {:ok, connect_result} -> connect_result
          nil -> :connect_timeout
        end

      send(caller, {:connect_result, node_atom, worker_name, result})
    end)

    state
  end

  defp handle_connect_result(state, node_atom, worker_name, result) do
    # Don't overwrite :connected from a {:nodeup} event
    if node_connected?(state.node_states, node_atom) do
      Logger.debug("[NodeMonitor] connect result for #{worker_name} ignored — already connected")

      state
    else
      do_handle_connect_result(state, node_atom, worker_name, result)
    end
  end

  defp do_handle_connect_result(state, node_atom, worker_name, result) do
    existing = Map.get(state.node_states, node_atom, %{})

    # Preserve existing grace_until — don't overwrite it with nil
    preserved_grace = existing[:grace_until]

    case result do
      true ->
        Logger.info("[NodeMonitor] connected to worker #{worker_name}")

        new_state = %{
          status: :connected,
          grace_until: nil,
          retry_count: 0
        }

        :ets.insert(@ets_table, {node_atom, new_state})
        node_states = Map.put(state.node_states, node_atom, new_state)

        safe_add_node(node_atom, state)

        %{state | node_states: node_states}

      :connect_timeout ->
        retries = (existing[:retry_count] || 0) + 1

        Logger.debug("[NodeMonitor] connect timeout for #{worker_name} (attempt #{retries})")

        failed_state = %{
          status: :disconnected,
          grace_until: preserved_grace,
          retry_count: retries
        }

        :ets.insert(@ets_table, {node_atom, failed_state})
        node_states = Map.put(state.node_states, node_atom, failed_state)

        %{state | node_states: node_states}

      false ->
        retries = (existing[:retry_count] || 0) + 1

        Logger.debug(
          "[NodeMonitor] failed to connect to worker #{worker_name} (attempt #{retries})"
        )

        failed_state = %{
          status: :disconnected,
          grace_until: preserved_grace,
          retry_count: retries
        }

        :ets.insert(@ets_table, {node_atom, failed_state})
        node_states = Map.put(state.node_states, node_atom, failed_state)

        %{state | node_states: node_states}

      :ignored ->
        retries = (existing[:retry_count] || 0) + 1

        Logger.debug(
          "[NodeMonitor] distribution not started, cannot connect to " <>
            "worker #{worker_name} (attempt #{retries})"
        )

        failed_state = %{
          status: :disconnected,
          grace_until: preserved_grace,
          retry_count: retries
        }

        :ets.insert(@ets_table, {node_atom, failed_state})
        node_states = Map.put(state.node_states, node_atom, failed_state)

        %{state | node_states: node_states}
    end
  end

  defp check_grace_periods(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.node_states, state, fn {node_name, node_state}, acc ->
      if node_state.status == :disconnected and
           is_integer(node_state.grace_until) and
           now >= node_state.grace_until do
        Logger.warning(
          "[NodeMonitor] grace period expired for #{inspect(node_name)}, removing node"
        )

        # Remove from DistributedSupervisor
        safe_remove_node(node_name, state)

        :ets.delete(@ets_table, node_name)

        lost_state = %{
          status: :lost,
          grace_until: nil,
          retry_count: node_state.retry_count
        }

        node_states = Map.put(acc.node_states, node_name, lost_state)

        %{acc | node_states: node_states}
      else
        acc
      end
    end)
  end

  defp remove_stale_nodes(state) do
    configured_set = MapSet.new(state.configured_workers)

    Enum.reduce(state.node_states, state, fn {node_name, node_state}, acc ->
      node_string = Atom.to_string(node_name)

      if not MapSet.member?(configured_set, node_string) and
           node_state.status in [:connected, :disconnected, :lost] do
        if node_state.status == :connected do
          safe_remove_node(node_name, state)
        end

        :ets.delete(@ets_table, node_name)
        Logger.info("[NodeMonitor] removed stale node #{node_string}")
        %{acc | node_states: Map.delete(acc.node_states, node_name)}
      else
        acc
      end
    end)
  end

  defp node_connected?(node_states, node_atom) do
    case Map.get(node_states, node_atom) do
      %{status: :connected} -> true
      _ -> false
    end
  end

  defp node_lost?(node_states, node_atom) do
    case Map.get(node_states, node_atom) do
      %{status: :lost} -> true
      _ -> false
    end
  end

  defp categorize_nodes(node_states) do
    now = System.monotonic_time(:millisecond)

    active =
      Enum.reject(node_states, fn {_, s} -> s.status == :lost end)

    {connected, others} =
      Enum.split_with(active, fn {_, s} -> s.status == :connected end)

    # Split disconnected into grace-period (future grace_until) and plain disconnected
    {disconnected, grace} =
      Enum.split_with(others, fn {_, s} ->
        s.status != :disconnected or not is_integer(s.grace_until) or now >= s.grace_until
      end)

    {
      Enum.map(connected, fn {n, _} -> n end),
      Enum.map(disconnected, fn {n, _} -> n end),
      Enum.map(grace, fn {n, _} -> n end)
    }
  end

  # Best-effort call to DistributedSupervisor.add_node/2.
  # Passes proxy_opts from state so test mocks work without distribution.
  # Uses supervisor_name from state so tests can use custom supervisors.
  # Expected errors (already_present, supervisor not started) are logged at debug.
  # Unexpected errors are logged at warning.
  defp safe_add_node(node_name, state) do
    opts = [supervisor_name: state.supervisor_name, proxy_opts: state.proxy_opts]

    case DistributedSupervisor.add_node(node_name, opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_present, _pid}} ->
        Logger.debug(
          "[NodeMonitor] node #{inspect(node_name)} already present in DistributedSupervisor"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[NodeMonitor] safe_add_node for #{inspect(node_name)} returned error: " <>
            "#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e in RuntimeError ->
      Logger.debug(
        "[NodeMonitor] safe_add_node for #{inspect(node_name)}: #{Exception.message(e)}"
      )

      :ok

    e ->
      Logger.warning(
        "[NodeMonitor] safe_add_node for #{inspect(node_name)} raised: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.debug(
        "[NodeMonitor] safe_add_node for #{inspect(node_name)} exited: #{inspect(reason)}"
      )

      :ok

    kind, reason ->
      Logger.warning(
        "[NodeMonitor] safe_add_node for #{inspect(node_name)} caught #{kind}: #{inspect(reason)}"
      )

      :ok
  end

  # Best-effort call to DistributedSupervisor.remove_node/2.
  # Uses supervisor_name from state for test isolation.
  defp safe_remove_node(node_name, state) do
    case DistributedSupervisor.remove_node(node_name, state.supervisor_name) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Logger.debug(
          "[NodeMonitor] node #{inspect(node_name)} not found in DistributedSupervisor for removal"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[NodeMonitor] safe_remove_node for #{inspect(node_name)} returned error: " <>
            "#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e in RuntimeError ->
      Logger.debug(
        "[NodeMonitor] safe_remove_node for #{inspect(node_name)}: #{Exception.message(e)}"
      )

      :ok

    e ->
      Logger.warning(
        "[NodeMonitor] safe_remove_node for #{inspect(node_name)} raised: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.debug(
        "[NodeMonitor] safe_remove_node for #{inspect(node_name)} exited: #{inspect(reason)}"
      )

      :ok

    kind, reason ->
      Logger.warning(
        "[NodeMonitor] safe_remove_node for #{inspect(node_name)} caught #{kind}: #{inspect(reason)}"
      )

      :ok
  end
end
