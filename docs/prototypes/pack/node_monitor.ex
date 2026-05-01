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

  1. Read the configured worker list from `puppy.cfg [packs.distributed]`.
  2. For each configured worker:
     - If not connected and not in grace period, attempt `Node.connect/1`.
     - On success, call `DistributedSupervisor.add_node/1`.
     - On failure, log and increment retry count.
  3. For each connected node that is no longer in config, remove it.

  ## Grace Period

  When a node disconnects, it enters a grace period (`disconnect_timeout`,
  default 30s) during which:
  - In-flight runs are NOT immediately failed.
  - The `RemoteNodeProxy` status is set to `:disconnected`.
  - Reconnection is attempted on each heartbeat.
  - If the grace period expires, all runs on that node are failed.

  ## References

  - Design doc §7.2: Boot sequence (Leader)
  - Design doc §8.1: Remote Node Disconnection
  - Design doc §8.2: Worker Process Crash
  """

  use GenServer

  require Logger

  # ── Configuration ────────────────────────────────────────────────────────

  @default_heartbeat_interval 15_000
  @default_disconnect_timeout 30_000
  @default_connect_timeout 5_000

  @table :pack_distributed_nodes

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the NodeMonitor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
  Returns a list of all configured worker node names.
  """
  @spec configured_workers() :: [String.t()]
  def configured_workers do
    GenServer.call(__MODULE__, :configured_workers)
  end

  @doc """
  Triggers an immediate cluster re-evaluation.
  """
  @spec recheck() :: :ok
  def recheck do
    GenServer.cast(__MODULE__, :recheck)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # ETS table for fast node-state lookups (read-heavy, write-light)
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: false
      ])

    config = load_config(opts)

    state = %{
      table: table,
      configured_workers: config.workers || [],
      heartbeat_interval: config.heartbeat_interval || @default_heartbeat_interval,
      disconnect_timeout: config.disconnect_timeout || @default_disconnect_timeout,
      connect_timeout: config.connect_timeout || @default_connect_timeout,
      enabled: config.enabled || false,
      # Track per-node state: %{node_name => %{status: :connected|:disconnected,
      #                                       grace_until: DateTime.t()|nil,
      #                                       retry_count: integer(),
      #                                       connected_at: DateTime.t()|nil}}
      node_states: %{}
    }

    if state.enabled do
      Logger.info(
        "NodeMonitor: distributed packs enabled, #{length(state.configured_workers)} workers configured"
      )

      schedule_heartbeat(state.heartbeat_interval)
      {:ok, state, {:continue, :initial_connect}}
    else
      Logger.info(
        "NodeMonitor: distributed packs disabled (set [packs.distributed] enabled=true to enable)"
      )

      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:initial_connect, state) do
    # Attempt initial connections to all configured workers
    state = attempt_all_connections(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    # Build status from ETS and in-memory state
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
    # 1. Check for expired grace periods
    state = check_grace_periods(state)

    # 2. Attempt reconnection to disconnected nodes
    state = attempt_all_connections(state)

    # 3. Clean up nodes that are no longer configured
    state = remove_stale_nodes(state)

    # 4. Reschedule next heartbeat
    schedule_heartbeat(state.heartbeat_interval)

    {:noreply, state}
  end

  # ── Handle Node Monitor Events ──────────────────────────────────────────

  @impl true
  def handle_info({:nodeup, node_name, _ref}, state) do
    Logger.info("NodeMonitor: node up detected: #{inspect(node_name)}")

    # Update ETS and in-memory state
    :ets.insert(@table, {node_name, :connected, DateTime.utc_now()})

    node_states =
      Map.put(state.node_states, node_name, %{
        status: :connected,
        grace_until: nil,
        retry_count: 0,
        connected_at: DateTime.utc_now()
      })

    # Notify DistributedSupervisor
    try do
      CodePuppyControl.Pack.DistributedSupervisor.add_node(node_name)
    rescue
      _ -> :ok
    end

    :telemetry.execute(
      [:code_puppy, :distributed_pack, :node, :connected],
      %{node: node_name},
      %{}
    )

    {:noreply, %{state | node_states: node_states}}
  end

  @impl true
  def handle_info({:nodedown, node_name, _ref}, state) do
    Logger.warning("NodeMonitor: node down detected: #{inspect(node_name)}")

    node_states =
      Map.put(state.node_states, node_name, %{
        status: :disconnected,
        grace_until: DateTime.add(DateTime.utc_now(), state.disconnect_timeout, :millisecond),
        retry_count: (state.node_states[node_name] || %{})[:retry_count] + 1 || 1,
        connected_at: nil
      })

    :ets.insert(@table, {node_name, :disconnected, DateTime.utc_now()})

    :telemetry.execute(
      [:code_puppy, :distributed_pack, :node, :disconnected],
      %{node: node_name, grace_period_ms: state.disconnect_timeout},
      %{}
    )

    {:noreply, %{state | node_states: node_states}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp load_config(opts) do
    # Read from Application config, with opts override
    app_config = Application.get_env(:code_puppy_control, :distributed_packs, %{})

    # Merge: opts override app config
    enabled = Keyword.get(opts, :enabled, Map.get(app_config, "enabled", false))
    workers = Keyword.get(opts, :workers, Map.get(app_config, "workers", ""))

    heartbeat =
      Keyword.get(
        opts,
        :heartbeat_interval,
        Map.get(app_config, "heartbeat_interval", @default_heartbeat_interval)
      )

    disconnect =
      Keyword.get(
        opts,
        :disconnect_timeout,
        Map.get(app_config, "disconnect_timeout", @default_disconnect_timeout)
      )

    connect =
      Keyword.get(
        opts,
        :connect_timeout,
        Map.get(app_config, "connect_timeout", @default_connect_timeout)
      )

    %{
      enabled: enabled,
      workers: parse_worker_list(workers),
      heartbeat_interval: heartbeat,
      disconnect_timeout: disconnect,
      connect_timeout: connect
    }
  end

  defp parse_worker_list(""), do: []

  defp parse_worker_list(list_string) when is_binary(list_string) do
    list_string
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp parse_worker_list(list) when is_list(list), do: list

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp attempt_all_connections(state) do
    Enum.reduce(state.configured_workers, state, fn worker_name, acc ->
      node_atom = String.to_atom(worker_name)

      cond do
        # Already connected — skip
        Map.get(acc.node_states, node_atom, %{})[:status] == :connected ->
          acc

        # In grace period — skip (let grace timer expire first)
        in_grace_period?(acc.node_states, node_atom) ->
          acc

        # Try to connect
        true ->
          case Node.connect(node_atom) do
            true ->
              Logger.info("NodeMonitor: connected to worker #{worker_name}")

              node_states =
                Map.put(acc.node_states, node_atom, %{
                  status: :connected,
                  grace_until: nil,
                  retry_count: 0,
                  connected_at: DateTime.utc_now()
                })

              # Notify DistributedSupervisor
              try do
                CodePuppyControl.Pack.DistributedSupervisor.add_node(node_atom)
              rescue
                _ -> :ok
              end

              %{acc | node_states: node_states}

            false ->
              retries = (Map.get(acc.node_states, node_atom, %{})[:retry_count] || 0) + 1

              Logger.debug(
                "NodeMonitor: failed to connect to worker #{worker_name} (attempt #{retries})"
              )

              node_states =
                Map.put(acc.node_states, node_atom, %{
                  status: :disconnected,
                  grace_until: nil,
                  retry_count: retries,
                  connected_at: nil
                })

              %{acc | node_states: node_states}
          end
      end
    end)
  end

  defp check_grace_periods(state) do
    now = DateTime.utc_now()

    Enum.reduce(state.node_states, state, fn {node_name, node_state}, acc ->
      if node_state.status == :disconnected and node_state.grace_until != nil and
           DateTime.compare(now, node_state.grace_until) != :lt do
        # Grace period expired — fail in-flight runs
        Logger.warning(
          "NodeMonitor: grace period expired for #{inspect(node_name)}, failing in-flight runs"
        )

        # Remove from DistributedSupervisor
        try do
          CodePuppyControl.Pack.DistributedSupervisor.remove_node(node_name)
        rescue
          _ -> :ok
        end

        :ets.delete(@table, node_name)

        node_states =
          Map.put(acc.node_states, node_name, %{
            status: :lost,
            grace_until: nil,
            retry_count: node_state.retry_count,
            connected_at: nil
          })

        %{acc | node_states: node_states}
      else
        acc
      end
    end)
  end

  defp remove_stale_nodes(state) do
    configured_set = MapSet.new(state.configured_workers)

    state.node_states
    |> Enum.reduce(state, fn {node_name, node_state}, acc ->
      node_string = Atom.to_string(node_name)

      if not MapSet.member?(configured_set, node_string) and
           node_state.status in [:connected, :disconnected, :lost] do
        # Node is no longer configured — remove
        if node_state.status == :connected do
          try do
            CodePuppyControl.Pack.DistributedSupervisor.remove_node(node_name)
          rescue
            _ -> :ok
          end
        end

        :ets.delete(@table, node_name)

        Logger.info("NodeMonitor: removed stale node #{node_string}")
        %{acc | node_states: Map.delete(acc.node_states, node_name)}
      else
        acc
      end
    end)
  end

  defp in_grace_period?(node_states, node_atom) do
    case Map.get(node_states, node_atom) do
      %{status: :disconnected, grace_until: %DateTime{} = until} ->
        DateTime.compare(DateTime.utc_now(), until) == :lt

      _ ->
        false
    end
  end

  defp categorize_nodes(node_states) do
    {connected, others} =
      Enum.split_with(node_states, fn {_, s} -> s.status == :connected end)

    {disconnected, grace} =
      Enum.split_with(others, fn {_, s} -> s.status == :disconnected end)

    {
      Enum.map(connected, fn {n, _} -> n end),
      Enum.map(disconnected, fn {n, _} -> n end),
      Enum.map(grace, fn {n, _} -> n end)
    }
  end
end
