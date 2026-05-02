defmodule CodePuppyControl.Pack.NodeMonitor do
  @moduledoc """
  Monitors remote node liveness for the distributed pack cluster.

  Tracks connected worker nodes via `:net_kernel.monitor_nodes/2`.
  Emits telemetry events on connect/disconnect/reconnect.
  Manages the heartbeat loop for reconnection attempts.

  When disabled (default), starts but does nothing — a no-op sentinel
  that satisfies the supervision tree without any runtime cost.

  (Phase I.1 — code_puppy-yge.2)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Telemetry.DistributedPack, as: PackTelemetry

  # ── Types ────────────────────────────────────────────────────────────────

  @type node_status :: :connected | :disconnected | :connecting

  @type node_info :: %{
          status: node_status(),
          connected_at: integer() | nil,
          disconnected_at: integer() | nil,
          capabilities: map() | nil,
          active_runs: [String.t()]
        }

  @type config :: %{
          heartbeat_interval: pos_integer(),
          connect_timeout: pos_integer(),
          disconnect_timeout: pos_integer(),
          workers: [node()],
          cookie: atom() | nil
        }

  @type state :: %{
          enabled: boolean(),
          nodes: %{node() => node_info()},
          config: config()
        }

  # ── Client API ────────────────────────────────────────────────────────────

  @doc """
  Starts the NodeMonitor GenServer.

  ## Options

    * `:enabled` — whether monitoring is active (default: from config)
    * `:workers` — list of worker node atoms to track
    * `:heartbeat_interval` — ms between heartbeat checks (default 15_000)
    * `:connect_timeout` — ms timeout for connection attempts (default 5_000)
    * `:disconnect_timeout` — ms grace period before permanent disconnect (default 30_000)
    * `:cookie` — Erlang distribution cookie atom

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns a map of all tracked nodes and their states.
  """
  @spec status() :: %{node() => node_info()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Returns a list of currently connected worker nodes.
  """
  @spec connected_nodes() :: [node()]
  def connected_nodes(server \\ __MODULE__) do
    GenServer.call(server, :connected_nodes)
  end

  @doc """
  Returns the status info for a specific node, or nil if unknown.
  """
  @spec node_status(node()) :: node_info() | nil
  def node_status(node_name, server \\ __MODULE__) do
    GenServer.call(server, {:node_status, node_name})
  end

  @doc """
  Triggers an immediate heartbeat cycle. Useful for testing.
  """
  @spec refresh() :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh)
  end

  @doc """
  Returns whether monitoring is active.
  """
  @spec enabled?() :: boolean()
  def enabled?(server \\ __MODULE__) do
    GenServer.call(server, :enabled?)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    pack_config = CodePuppyControl.Pack.Config.load()

    enabled = Keyword.get(opts, :enabled, pack_config.enabled)
    workers = Keyword.get(opts, :workers, pack_config.workers)
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval, pack_config.heartbeat_interval)
    connect_timeout = Keyword.get(opts, :connect_timeout, pack_config.connect_timeout)
    disconnect_timeout = Keyword.get(opts, :disconnect_timeout, pack_config.disconnect_timeout)
    cookie = Keyword.get(opts, :cookie, pack_config.cookie)

    config = %{
      heartbeat_interval: heartbeat_interval,
      connect_timeout: connect_timeout,
      disconnect_timeout: disconnect_timeout,
      workers: workers,
      cookie: cookie
    }

    # Initialize all configured workers as disconnected
    nodes =
      Map.new(workers, fn worker_node ->
        {worker_node, empty_node_info()}
      end)

    state = %{
      enabled: enabled,
      nodes: nodes,
      config: config
    }

    if enabled do
      Logger.info("NodeMonitor: enabled — monitoring #{length(workers)} worker(s)")

      # Set cookie if configured
      if cookie do
        Node.set_cookie(cookie)
      end

      # Subscribe to node up/down events
      :net_kernel.monitor_nodes(true, [:nodedown_reason])

      # Schedule first heartbeat
      schedule_heartbeat(state)

      {:ok, state}
    else
      Logger.debug("NodeMonitor: disabled — standing by as no-op sentinel")
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.nodes, state}
  end

  @impl true
  def handle_call(:connected_nodes, _from, state) do
    connected =
      state.nodes
      |> Enum.filter(fn {_node, info} -> info.status == :connected end)
      |> Enum.map(fn {node, _info} -> node end)

    {:reply, connected, state}
  end

  @impl true
  def handle_call({:node_status, node_name}, _from, state) do
    {:reply, Map.get(state.nodes, node_name), state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    if state.enabled do
      state = do_heartbeat(state)
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  # ── Info: Node Up ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:nodeup, node, _info}, %{enabled: true} = state) do
    if Map.has_key?(state.nodes, node) do
      now = System.monotonic_time(:millisecond)
      prev = Map.get(state.nodes, node)

      # Detect reconnect vs fresh connect
      was_disconnected = prev.status in [:disconnected, :connecting]

      info = %{
        prev
        | status: :connected,
          connected_at: now,
          disconnected_at: nil
      }

      state = put_in(state.nodes[node], info)

      if was_disconnected and prev.disconnected_at do
        grace_ms = now - prev.disconnected_at
        PackTelemetry.node_reconnected(node, grace_ms)
        Logger.info("NodeMonitor: node #{inspect(node)} reconnected (grace: #{grace_ms}ms)")
      else
        PackTelemetry.node_connected(node, info.capabilities || %{})
        Logger.info("NodeMonitor: node #{inspect(node)} connected")
      end

      {:noreply, state}
    else
      # Unknown node connected — ignore (only track configured workers)
      Logger.debug("NodeMonitor: ignoring connection from unconfigured node #{inspect(node)}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nodeup, _node, _info}, state) do
    # Disabled — ignore
    {:noreply, state}
  end

  # ── Info: Node Down ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:nodedown, node, info}, %{enabled: true} = state) do
    if Map.has_key?(state.nodes, node) do
      now = System.monotonic_time(:millisecond)
      prev = Map.get(state.nodes, node)
      reason = Keyword.get(info, :nodedown_reason, :unknown)

      node_info = %{
        prev
        | status: :disconnected,
          disconnected_at: now
      }

      state = put_in(state.nodes[node], node_info)

      PackTelemetry.node_disconnected(node, prev.active_runs, reason)

      Logger.warning(
        "NodeMonitor: node #{inspect(node)} disconnected (reason: #{inspect(reason)})"
      )

      # Schedule grace period expiry
      timeout = state.config.disconnect_timeout
      Process.send_after(self(), {:grace_expired, node}, timeout)

      {:noreply, state}
    else
      Logger.debug("NodeMonitor: ignoring disconnection from unconfigured node #{inspect(node)}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nodedown, _node, _info}, state) do
    # Disabled — ignore
    {:noreply, state}
  end

  # ── Info: Heartbeat ──────────────────────────────────────────────────────

  @impl true
  def handle_info(:heartbeat, %{enabled: true} = state) do
    state = do_heartbeat(state)
    schedule_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Disabled — no heartbeat
    {:noreply, state}
  end

  # ── Info: Grace Period Expiry ────────────────────────────────────────────

  @impl true
  def handle_info({:grace_expired, node}, %{enabled: true} = state) do
    case Map.get(state.nodes, node) do
      %{status: :disconnected} = info ->
        Logger.warning(
          "NodeMonitor: grace period expired for #{inspect(node)} — " <>
            "marking as permanently disconnected (#{length(info.active_runs)} active runs affected)"
        )

        # Clean up active runs on this node
        info = %{info | active_runs: []}
        state = put_in(state.nodes[node], info)

        # Unregister from NamingService
        CodePuppyControl.Pack.NamingService.unregister_node(node)

        {:noreply, state}

      _ ->
        # Node has reconnected or is in another state — ignore
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:grace_expired, _node}, state) do
    # Disabled — ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp empty_node_info do
    %{
      status: :disconnected,
      connected_at: nil,
      disconnected_at: nil,
      capabilities: nil,
      active_runs: []
    }
  end

  defp schedule_heartbeat(state) do
    Process.send_after(self(), :heartbeat, state.config.heartbeat_interval)
  end

  defp do_heartbeat(state) do
    # Attempt reconnection for disconnected workers
    Enum.reduce(state.nodes, state, fn {node, info}, acc ->
      if info.status == :disconnected do
        case Node.connect(node) do
          true ->
            # nodeup message will be handled by handle_info — don't duplicate
            # Mark as connecting until nodeup arrives
            put_in(acc.nodes[node], %{info | status: :connecting})

          false ->
            Logger.debug("NodeMonitor: heartbeat — failed to connect to #{inspect(node)}")
            acc

          :ignored ->
            # Already connected — shouldn't happen if state is consistent
            acc
        end
      else
        acc
      end
    end)
  end
end
