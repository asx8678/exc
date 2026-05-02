defmodule CodePuppyControl.Telemetry.ClusterDashboard do
  @moduledoc """
  Telemetry dashboard for cluster status.

  Aggregates and reports on connected workers, capabilities, load,
  health, and dispatch history. Provides a snapshot view for
  observability and a streaming API for live dashboards.

  ## Architecture

  The dashboard is a GenServer that:

  1. Subscribes to `:telemetry` events from `DistributedPack`
  2. Maintains an in-memory state of cluster nodes and dispatches
  3. Provides `snapshot/0` for a point-in-time view
  4. Provides `subscribe/0` for live updates via PubSub

  ## Usage

      # Get a cluster status snapshot
      CodePuppyControl.Telemetry.ClusterDashboard.snapshot()

      # Subscribe to live updates
      CodePuppyControl.Telemetry.ClusterDashboard.subscribe()

  (code_puppy-jqr.4)
  """

  use GenServer

  require Logger

  @pubsub CodePuppyControl.PubSub
  @dashboard_topic "telemetry:cluster_dashboard"

  # ── State ────────────────────────────────────────────────────────────────

  defstruct [
    :started_at,
    nodes: %{},
    dispatch_history: [],
    total_dispatches: 0,
    total_successes: 0,
    total_failures: 0
  ]

  @type node_info :: %{
          status: :connected | :disconnected,
          connected_at: integer() | nil,
          capabilities: map() | nil,
          active_runs: non_neg_integer(),
          total_completed: non_neg_integer(),
          last_seen: integer() | nil
        }

  @type dispatch_entry :: %{
          run_id: String.t(),
          sub_agent: atom(),
          target_node: node(),
          status: :started | :completed | :failed,
          duration_ms: non_neg_integer() | nil,
          timestamp: integer()
        }

  @type state :: %__MODULE__{
          started_at: integer(),
          nodes: %{node() => node_info()},
          dispatch_history: [dispatch_entry()],
          total_dispatches: non_neg_integer(),
          total_successes: non_neg_integer(),
          total_failures: non_neg_integer()
        }

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Start the cluster dashboard GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get a point-in-time snapshot of cluster status.

  Returns a map with:

    * `:nodes` — map of node names to node info
    * `:dispatch_history` — recent dispatch entries (last 100)
    * `:totals` — aggregate dispatch statistics
    * `:uptime_ms` — dashboard uptime in milliseconds
    * `:connected_nodes` — count of currently connected nodes
    * `:cluster_health` — `:healthy`, `:degraded`, or `:down`
  """
  @spec snapshot() :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Subscribe to live cluster dashboard updates via PubSub.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @dashboard_topic)
  end

  @doc """
  Get the current cluster health status.

  - `:healthy` — all known nodes are connected
  - `:degraded` — some nodes are disconnected
  - `:down` — no nodes are connected
  """
  @spec cluster_health(state()) :: :healthy | :degraded | :down
  def cluster_health(state) do
    node_count = map_size(state.nodes)

    cond do
      node_count == 0 -> :down
      Enum.all?(state.nodes, fn {_, info} -> info.status == :connected end) -> :healthy
      true -> :degraded
    end
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Attach telemetry handlers for cluster events
    attach_telemetry_handlers()

    state = %__MODULE__{
      started_at: System.monotonic_time(:millisecond)
    }

    Logger.info("ClusterDashboard: started")
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    uptime = System.monotonic_time(:millisecond) - state.started_at

    snapshot = %{
      nodes: state.nodes,
      dispatch_history: Enum.take(state.dispatch_history, 100),
      totals: %{
        dispatches: state.total_dispatches,
        successes: state.total_successes,
        failures: state.total_failures
      },
      uptime_ms: uptime,
      connected_nodes: Enum.count(state.nodes, fn {_, i} -> i.status == :connected end),
      cluster_health: cluster_health(state)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:telemetry_event, event, measurements, metadata}, state) do
    state = process_telemetry_event(event, measurements, metadata, state)

    # Broadcast update to subscribers
    Phoenix.PubSub.broadcast(@pubsub, @dashboard_topic, {:dashboard_update, %{
      event: event,
      metadata: metadata,
      cluster_health: cluster_health(state)
    }})

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Telemetry Processing ────────────────────────────────────────────────

  defp process_telemetry_event([:code_puppy, :distributed_pack, :node, :connected], _m, meta, state) do
    node = Map.get(meta, :node)
    caps = Map.get(meta, :capabilities, %{})

    state = %{state | nodes: Map.put(state.nodes, node, %{
      status: :connected,
      connected_at: System.monotonic_time(:millisecond),
      capabilities: caps,
      active_runs: 0,
      total_completed: 0,
      last_seen: System.monotonic_time(:millisecond)
    })}

    Logger.info("ClusterDashboard: node connected — #{inspect(node)}")
    state
  end

  defp process_telemetry_event([:code_puppy, :distributed_pack, :node, :disconnected], _m, meta, state) do
    node = Map.get(meta, :node)

    state = update_in(state.nodes, [node], fn info ->
      %{info | status: :disconnected, last_seen: System.monotonic_time(:millisecond)}
    end, fn -> nil end)

    Logger.info("ClusterDashboard: node disconnected — #{inspect(node)}")
    state
  end

  defp process_telemetry_event([:code_puppy, :distributed_pack, :dispatch, :start], _m, meta, state) do
    run_id = Map.get(meta, :run_id)
    target = Map.get(meta, :target_node)

    entry = %{
      run_id: run_id,
      sub_agent: Map.get(meta, :sub_agent),
      target_node: target,
      status: :started,
      duration_ms: nil,
      timestamp: System.monotonic_time(:millisecond)
    }

    state = %{state |
      dispatch_history: [entry | state.dispatch_history],
      total_dispatches: state.total_dispatches + 1
    }

    # Increment active_runs on the target node
    state = update_in(state.nodes, [target], fn info ->
      if info, do: %{info | active_runs: info.active_runs + 1}, else: nil
    end, fn -> nil end)

    state
  end

  defp process_telemetry_event([:code_puppy, :distributed_pack, :dispatch, :stop], _m, meta, state) do
    run_id = Map.get(meta, :run_id)
    status = Map.get(meta, :status)

    # Update dispatch history entry
    state = update_dispatch_entry(state, run_id, :completed, nil)

    # Update counters
    state = case status do
      :success -> %{state | total_successes: state.total_successes + 1}
      _ -> %{state | total_failures: state.total_failures + 1}
    end

    # Decrement active_runs on the target node
    state = Enum.reduce(state.nodes, state, fn {node_name, info}, acc ->
      if info.active_runs > 0 do
        put_in(acc.nodes[node_name], %{info | active_runs: info.active_runs - 1,
          total_completed: info.total_completed + 1})
      else
        acc
      end
    end)

    state
  end

  defp process_telemetry_event([:code_puppy, :distributed_pack, :dispatch, :exception], _m, meta, state) do
    run_id = Map.get(meta, :run_id)

    state = update_dispatch_entry(state, run_id, :failed, nil)
    %{state | total_failures: state.total_failures + 1}
  end

  defp process_telemetry_event(_event, _measurements, _metadata, state), do: state

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp update_dispatch_entry(state, run_id, status, duration_ms) do
    history = Enum.map(state.dispatch_history, fn entry ->
      if entry.run_id == run_id and entry.status == :started do
        %{entry | status: status, duration_ms: duration_ms}
      else
        entry
      end
    end)

    %{state | dispatch_history: history}
  end

  defp attach_telemetry_handlers do
    events = [
      [:code_puppy, :distributed_pack, :node, :connected],
      [:code_puppy, :distributed_pack, :node, :disconnected],
      [:code_puppy, :distributed_pack, :dispatch, :start],
      [:code_puppy, :distributed_pack, :dispatch, :stop],
      [:code_puppy, :distributed_pack, :dispatch, :exception]
    ]

    handler_id = {__MODULE__, self()}

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(__MODULE__, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )
  end

  # Safe update_in with nil fallback
  defp update_in(data, keys, fun, _default) when is_map(data) do
    case get_in(data, keys) do
      nil -> data
      val -> put_in(data, keys, fun.(val))
    end
  end
end
