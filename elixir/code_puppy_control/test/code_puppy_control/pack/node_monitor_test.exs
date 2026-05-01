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

  # Mock proxy opts — avoid Node.monitor/2 (crashes without distribution)
  # and GenServer.call to a non-existent remote node during handshake.
  # Cannot be a module attribute because anonymous functions are not escapable.
  defp mock_proxy_opts do
    [
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end,
      name: nil
    ]
  end

  # Common opts for NodeMonitor — wires up the test supervisor + mock proxy opts.
  defp monitor_opts(extra \\ []) do
    Keyword.merge(
      [supervisor_name: @ds_name, proxy_opts: mock_proxy_opts()],
      extra
    )
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # Start DistributedSupervisor so NodeMonitor can call add_node/remove_node.
    start_supervised!({DistributedSupervisor, name: @ds_name})

    # Registries are already started by the application supervision tree —
    # do NOT start a duplicate (the child Registry names are global).

    # Ensure no stale ETS table or NodeMonitor from a previous test
    cleanup_monitor()
    cleanup_ets()

    on_exit(fn ->
      cleanup_monitor()
      cleanup_ets()
    end)

    %{ds_name: @ds_name}
  end

  defp cleanup_monitor do
    # Stop the app-supervised NodeMonitor without restart.
    # Must use Supervisor.terminate_child/2 on the app supervisor
    # to prevent automatic restart.
    case GenServer.whereis(NodeMonitor) do
      nil ->
        :ok

      _pid ->
        case Supervisor.terminate_child(CodePuppyControl.Supervisor, NodeMonitor) do
          :ok -> :ok
          {:error, _} -> :ok
        end
    end
  end

  defp cleanup_ets do
    try do
      :ets.delete(:pack_node_monitor_state)
    rescue
      _ -> :ok
    end
  end

  # ── Disabled ──────────────────────────────────────────────────────────────

  describe "start_link with enabled: false" do
    test "starts successfully without crash" do
      assert {:ok, pid} = NodeMonitor.start_link(enabled: false)
      assert Process.alive?(pid)
    end

    test "status returns empty state" do
      {:ok, _pid} = NodeMonitor.start_link(enabled: false)

      assert %{
               configured_workers: [],
               connected_nodes: [],
               disconnected_nodes: [],
               grace_period_nodes: []
             } = NodeMonitor.status()
    end

    test "configured_workers returns empty list" do
      {:ok, _pid} = NodeMonitor.start_link(enabled: false)
      assert NodeMonitor.configured_workers() == []
    end
  end

  # ── Enabled — basic structure ────────────────────────────────────────────

  describe "start_link with enabled: true" do
    test "starts successfully with workers" do
      assert {:ok, pid} =
               NodeMonitor.start_link(
                 monitor_opts(
                   enabled: true,
                   workers: [@test_node_name],
                   heartbeat_interval: 500
                 )
               )

      assert Process.alive?(pid)
      Process.sleep(50)
    end

    test "configured_workers returns configured list" do
      {:ok, _pid} =
        NodeMonitor.start_link(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name, "another@host"],
            heartbeat_interval: 500
          )
        )

      assert NodeMonitor.configured_workers() == [@test_node_name, "another@host"]
    end

    test "status returns correct structure with workers" do
      {:ok, _pid} =
        NodeMonitor.start_link(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 500
          )
        )

      status = NodeMonitor.status()

      assert %{
               configured_workers: [@test_node_name],
               connected_nodes: [],
               disconnected_nodes: [_],
               grace_period_nodes: []
             } = status
    end
  end

  # ── Node events ──────────────────────────────────────────────────────────

  describe "{:nodeup, node} handling" do
    test "transitions to connected and calls DistributedSupervisor.add_node" do
      {:ok, pid} =
        NodeMonitor.start_link(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 500
          )
        )

      # Initially no nodes in DistributedSupervisor
      assert DistributedSupervisor.list_nodes(@ds_name) == []

      # Simulate nodeup — this triggers DistributedSupervisor.add_node
      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      status = NodeMonitor.status()
      assert @test_node_atom in status.connected_nodes

      # Node should be added to DistributedSupervisor (with mock proxy opts)
      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name)
    end
  end

  describe "{:nodedown, node} handling" do
    test "transitions to disconnected with grace period" do
      {:ok, pid} =
        NodeMonitor.start_link(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            disconnect_timeout: 10_000,
            heartbeat_interval: 500
          )
        )

      # First simulate nodeup so the node is connected
      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      status = NodeMonitor.status()
      assert @test_node_atom in status.connected_nodes

      # Now simulate nodedown
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      status = NodeMonitor.status()
      assert @test_node_atom in status.disconnected_nodes
      assert @test_node_atom not in status.connected_nodes
    end

    test "grace period expiry removes node after disconnect_timeout" do
      {:ok, pid} =
        NodeMonitor.start_link(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            disconnect_timeout: 10,
            heartbeat_interval: 50
          )
        )

      # Simulate nodeup
      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      # Simulate nodedown (very short disconnect_timeout)
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      # After nodedown, node should be in disconnected state
      status = NodeMonitor.status()
      assert @test_node_atom in status.disconnected_nodes

      # Wait for grace period to expire + heartbeat to fire
      Process.sleep(300)

      status = NodeMonitor.status()

      # After grace expiry, node transitions to :lost status
      # (no longer in disconnected or connected)
      assert @test_node_atom not in status.connected_nodes
      assert @test_node_atom not in status.disconnected_nodes
      assert @test_node_atom not in status.grace_period_nodes
    end
  end

  # ── recheck ──────────────────────────────────────────────────────────────

  describe "recheck/0" do
    test "triggers immediate re-evaluation" do
      {:ok, pid} =
        NodeMonitor.start_link(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 60_000
          )
        )

      # Simulate nodeup so we have a node
      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      assert @test_node_atom in NodeMonitor.status().connected_nodes

      # Now simulate nodedown
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      assert @test_node_atom in NodeMonitor.status().disconnected_nodes

      # Call recheck — should try to reconnect (will fail, but shouldn't crash)
      assert :ok = NodeMonitor.recheck()
      Process.sleep(20)

      # Still disconnected since no real node to connect to
      assert @test_node_atom in NodeMonitor.status().disconnected_nodes
    end
  end

  # ── ETS table ────────────────────────────────────────────────────────────

  describe "ETS table" do
    test "pack_node_monitor_state exists when monitor is running" do
      {:ok, _pid} =
        NodeMonitor.start_link(
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
      {:ok, pid} =
        NodeMonitor.start_link(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 500
          )
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      # Assign module attribute to a variable for pin in pattern match
      expected_node = @test_node_atom
      assert [{^expected_node, state}] = :ets.lookup(:pack_node_monitor_state, @test_node_atom)
      assert state.status == :connected
    end
  end

  # ── Stale node removal ──────────────────────────────────────────────────

  describe "stale node removal" do
    test "removes nodes after grace period expiry on heartbeat" do
      {:ok, pid} =
        NodeMonitor.start_link(
          monitor_opts(
            enabled: true,
            workers: [@test_node_name],
            heartbeat_interval: 50,
            disconnect_timeout: 100
          )
        )

      # Simulate nodeup for the configured worker
      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      assert @test_node_atom in NodeMonitor.status().connected_nodes
      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name)

      # Simulate nodedown
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      assert @test_node_atom in NodeMonitor.status().disconnected_nodes
      # Node still in supervisor during grace period
      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name)

      # Wait for grace period to expire
      Process.sleep(300)

      # Node should be gone from all categories after grace expiry
      final_status = NodeMonitor.status()
      assert @test_node_atom not in final_status.connected_nodes
      assert @test_node_atom not in final_status.disconnected_nodes

      # And removed from DistributedSupervisor
      assert DistributedSupervisor.list_nodes(@ds_name) == []
    end
  end
end
