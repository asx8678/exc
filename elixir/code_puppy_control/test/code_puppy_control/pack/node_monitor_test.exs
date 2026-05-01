defmodule CodePuppyControl.Pack.NodeMonitorTest do
  @moduledoc """
  Tests for NodeMonitor — GenServer tracking remote node cluster membership.

  Uses async: false because tests share the global ETS table
  `:pack_node_monitor_state`, the DistributedSupervisor, and the
  NodeMonitor process name `__MODULE__`.

  NodeMonitor is tested in both disabled and enabled modes. When enabled,
  Node.connect/1 will fail (no real remote nodes), so we rely on
  direct message injection ({:nodeup, ...}, {:nodedown, ...}) to simulate
  cluster events.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.NodeMonitor
  alias CodePuppyControl.Pack.DistributedSupervisor

  @test_node_name "pup_nm_test_worker@localhost"
  @test_node_atom :pup_nm_test_worker@localhost
  @ds_name :test_nm_distributed_supervisor
  @nm_name :test_node_monitor

  # Mock proxy opts — avoid Node.monitor/2 (crashes without distribution)
  # and GenServer.call to a non-existent remote node during handshake.
  defp mock_proxy_opts do
    [
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end,
      name: nil
    ]
  end

  # Common opts for NodeMonitor — wires up the test supervisor + mock proxy opts.
  # Uses a unique name @nm_name to avoid clashing with the app-started monitor.
  defp monitor_opts(extra) do
    Keyword.merge(
      [
        name: @nm_name,
        supervisor_name: @ds_name,
        proxy_opts: mock_proxy_opts(),
        connect_fn: fn _node -> false end,
        monitor_fn: fn _node, _flag -> true end
      ],
      extra
    )
  end

  # Helper to call NodeMonitor.status/0 on our test monitor
  defp nm_status, do: GenServer.call(@nm_name, :status)

  # Helper to call NodeMonitor.configured_workers/0 on our test monitor
  defp nm_configured_workers, do: GenServer.call(@nm_name, :configured_workers)

  # Helper to call NodeMonitor.recheck/0 on our test monitor
  defp nm_recheck, do: GenServer.cast(@nm_name, :recheck)

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # Start DistributedSupervisor so NodeMonitor can call add_node/remove_node.
    start_supervised!({DistributedSupervisor, name: @ds_name})

    cleanup_ets()

    on_exit(fn ->
      cleanup_ets()
    end)

    %{ds_name: @ds_name}
  end

  defp cleanup_ets do
    try do
      :ets.delete(:pack_node_monitor_state)
    rescue
      _ -> :ok
    end
  end

  # Start a monitor and ensure it's killed when test ends. Returns the pid.
  defp start_monitor(opts) do
    cleanup_ets()

    name = Keyword.get(opts, :name, @nm_name)
    kill_registered(name)

    case NodeMonitor.start_link(opts) do
      {:ok, pid} ->
        on_exit(fn ->
          kill_registered(name)
        end)

        pid

      {:error, {:already_started, pid}} ->
        # Race condition: name was taken between kill and start
        kill_registered(name)
        {:ok, pid} = NodeMonitor.start_link(opts)
        pid
    end
  end

  defp kill_registered(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)

        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          2000 -> :ok
        end
    end
  end

  # ── Disabled ──────────────────────────────────────────────────────────────

  describe "start_link with enabled: false" do
    test "starts successfully without crash" do
      pid = start_monitor(monitor_opts(enabled: false, workers: []))
      assert Process.alive?(pid)
    end

    test "status returns empty state" do
      _pid = start_monitor(monitor_opts(enabled: false, workers: []))

      assert %{
               configured_workers: [],
               connected_nodes: [],
               disconnected_nodes: [],
               grace_period_nodes: []
             } = nm_status()
    end

    test "configured_workers returns empty list" do
      _pid = start_monitor(monitor_opts(enabled: false, workers: []))
      assert nm_configured_workers() == []
    end
  end

  # ── Enabled — basic structure ────────────────────────────────────────────

  describe "start_link with enabled: true" do
    test "starts successfully with workers" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 500
          )
        )

      assert Process.alive?(pid)
    end

    test "configured_workers returns configured list" do
      _pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name, "another@host"],
            heartbeat_interval: 500
          )
        )

      assert nm_configured_workers() == [@test_node_name, "another@host"]
    end

    test "status returns correct structure with workers" do
      _pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 500
          )
        )

      # Initial state is empty — no connect attempts yet
      status = nm_status()

      assert %{
               configured_workers: [@test_node_name],
               connected_nodes: [],
               disconnected_nodes: [],
               grace_period_nodes: []
             } = status

      # Trigger recheck to start a connect attempt
      nm_recheck()
      Process.sleep(100)

      status = nm_status()
      assert @test_node_atom in status.disconnected_nodes
    end
  end

  # ── Node events ──────────────────────────────────────────────────────────

  describe "{:nodeup, node} handling" do
    test "transitions to connected and calls DistributedSupervisor.add_node" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 500
          )
        )

      assert DistributedSupervisor.list_nodes(@ds_name) == []

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      status = nm_status()
      assert @test_node_atom in status.connected_nodes

      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name)
    end
  end

  describe "{:nodedown, node} handling" do
    test "transitions to grace period on nodedown" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            disconnect_timeout: 10_000,
            heartbeat_interval: 500
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      status = nm_status()
      assert @test_node_atom in status.connected_nodes

      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      status = nm_status()
      # Node is in grace period (future grace_until)
      assert @test_node_atom in status.grace_period_nodes
      assert @test_node_atom not in status.connected_nodes
      assert @test_node_atom not in status.disconnected_nodes
    end

    test "grace period expiry removes node after disconnect_timeout" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            disconnect_timeout: 100,
            heartbeat_interval: 50
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(10)

      status = nm_status()
      # Node enters grace period (grace_until is far in the future)
      assert @test_node_atom in status.grace_period_nodes

      # Wait for grace to expire + heartbeat
      Process.sleep(300)

      status = nm_status()

      assert @test_node_atom not in status.connected_nodes
      assert @test_node_atom not in status.disconnected_nodes
      assert @test_node_atom not in status.grace_period_nodes
    end
  end

  # ── recheck ──────────────────────────────────────────────────────────────

  describe "recheck/0" do
    test "triggers immediate re-evaluation" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 60_000
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)
      assert @test_node_atom in nm_status().connected_nodes

      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(50)
      assert @test_node_atom in nm_status().grace_period_nodes

      assert :ok = nm_recheck()
      Process.sleep(50)
      assert @test_node_atom in nm_status().grace_period_nodes
    end
  end

  # ── ETS table ────────────────────────────────────────────────────────────

  describe "ETS table" do
    test "pack_node_monitor_state exists when monitor is running" do
      _pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 500
          )
        )

      assert :ets.info(:pack_node_monitor_state, :name) == :pack_node_monitor_state
      assert :ets.info(:pack_node_monitor_state, :type) == :set
    end

    test "ETS table stores node state" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 500
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      expected = @test_node_atom
      assert [{^expected, state}] = :ets.lookup(:pack_node_monitor_state, @test_node_atom)
      assert state.status == :connected
    end
  end

  # ── Stale node removal ──────────────────────────────────────────────────

  describe "stale node removal" do
    test "removes nodes after grace period expiry on heartbeat" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 50,
            disconnect_timeout: 100
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      assert @test_node_atom in nm_status().connected_nodes
      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name)

      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      # Node enters grace period
      assert @test_node_atom in nm_status().grace_period_nodes
      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name)

      Process.sleep(300)

      final_status = nm_status()
      assert @test_node_atom not in final_status.connected_nodes
      assert @test_node_atom not in final_status.disconnected_nodes
      assert @test_node_atom not in final_status.grace_period_nodes

      assert DistributedSupervisor.list_nodes(@ds_name) == []
    end
  end

  # ── Reconnection during grace period (Bug #2) ────────────────────────────

  describe "reconnection during grace period" do
    test "retries connection on heartbeat during grace period" do
      counter_table = :ets.new(:connect_counter, [:set, :public])
      :ets.insert(counter_table, {:count, 0})

      connect_fn = fn _node ->
        :ets.update_counter(counter_table, :count, 1)
        false
      end

      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 50,
            disconnect_timeout: 10_000,
            connect_fn: connect_fn
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      status = nm_status()
      # Node is in grace period
      assert @test_node_atom in status.grace_period_nodes

      Process.sleep(200)

      # connect_fn should have been called at least once (heartbeat tries reconnection)
      [{:count, count}] = :ets.lookup(counter_table, :count)
      assert count >= 1, "connect_fn should be called on heartbeat during grace period"
    end

    test "reconnects successfully before grace expires" do
      flag_table = :ets.new(:reconnect_flag, [:set, :public])
      :ets.insert(flag_table, {:should_connect, false})

      connect_fn = fn _node ->
        [{:should_connect, val}] = :ets.lookup(flag_table, :should_connect)
        val
      end

      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 50,
            disconnect_timeout: 10_000,
            connect_fn: connect_fn
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      status = nm_status()
      assert @test_node_atom in status.grace_period_nodes

      # Enable reconnection
      :ets.insert(flag_table, {:should_connect, true})

      # Trigger recheck — will spawn async connect that now returns true
      nm_recheck()
      Process.sleep(200)

      # After reconnection, node is connected
      status = nm_status()

      assert @test_node_atom in status.connected_nodes,
             "node should reconnect before grace period expires"

      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name),
             "reconnected node should be in DistributedSupervisor"
    end
  end

  # ── Async connect (Bug #3) ───────────────────────────────────────────────

  describe "async connect" do
    test "connects via connect_fn without blocking GenServer" do
      caller = self()

      connect_fn = fn _node ->
        send(caller, :connect_called)
        false
      end

      _pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 60_000,
            connect_fn: connect_fn
          )
        )

      nm_recheck()

      assert_receive :connect_called, 200
    end

    test "uses connect_timeout from config" do
      connect_fn = fn _node ->
        :timer.sleep(500)
        true
      end

      _pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 60_000,
            connect_timeout: 50,
            connect_fn: connect_fn
          )
        )

      nm_recheck()
      Process.sleep(200)

      status = nm_status()

      assert @test_node_atom not in status.connected_nodes,
             "node should not be connected after timeout"
    end
  end

  # ── grace_period_nodes categorization ────────────────────────────────────

  describe "grace_period_nodes categorization" do
    test "nodes in grace period appear in grace_period_nodes" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            disconnect_timeout: 10_000
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      status = nm_status()

      assert @test_node_atom in status.grace_period_nodes,
             "disconnected node with future grace_until should be in grace_period_nodes"

      assert @test_node_atom not in status.disconnected_nodes,
             "node in grace should NOT be in disconnected_nodes"
    end

    test "nodes with expired grace are in lost, not grace_period_nodes" do
      pid =
        start_monitor(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            disconnect_timeout: 10,
            heartbeat_interval: 50
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      Process.sleep(200)

      status = nm_status()
      assert @test_node_atom not in status.grace_period_nodes
      assert @test_node_atom not in status.disconnected_nodes
      assert @test_node_atom not in status.connected_nodes
    end
  end
end
