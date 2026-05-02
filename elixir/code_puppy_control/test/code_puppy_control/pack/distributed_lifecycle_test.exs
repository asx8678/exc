defmodule CodePuppyControl.Pack.DistributedLifecycleTest do
  @moduledoc """
  Integration tests for the distributed pack lifecycle.

  Tests disabled mode, enabled mode with mock connections, telemetry
  emission for node lifecycle events, and full lifecycle scenarios.

  Uses app-started Registries (already running in the supervision tree)
  and test-specific DistributedSupervisor/NodeMonitor instances.

  ## Tagging

  Tagged with `@moduletag :integration` and `@moduletag :distributed`.
  Run via:

      mix test --only integration --only distributed
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :distributed

  alias CodePuppyControl.Pack.DistributedSupervisor
  alias CodePuppyControl.Pack.NodeMonitor

  @test_node_name "pup_int_test_worker@localhost"
  @test_node_atom :pup_int_test_worker@localhost
  @ds_name :test_lc_distributed_supervisor
  @nm_name :test_lc_node_monitor
  @ets_table :pack_node_monitor_state

  # ── Mock helpers ─────────────────────────────────────────────────────────

  defp mock_proxy_opts do
    [
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end,
      name: nil,
      grace_period_timeout: 0
    ]
  end

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

  defp nm_status, do: GenServer.call(@nm_name, :status)

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    cleanup_ets()

    start_supervised!({DistributedSupervisor, name: @ds_name})

    on_exit(fn ->
      kill_registered(@nm_name)
      kill_registered(@ds_name)
      cleanup_ets()
    end)

    %{ds_name: @ds_name}
  end

  defp cleanup_ets do
    try do
      :ets.delete(@ets_table)
    rescue
      _ -> :ok
    end

    try do
      :ets.delete(:pack_distributed_supervisor_nodes)
    rescue
      _ -> :ok
    end
  end

  # ── Disabled mode ────────────────────────────────────────────────────────

  describe "disabled mode" do
    test "NodeMonitor stays idle with no connect attempts" do
      connect_table = :ets.new(:connect_counter, [:set, :public])
      :ets.insert(connect_table, {:count, 0})

      connect_fn = fn _node ->
        :ets.update_counter(connect_table, :count, 1)
        false
      end

      start_supervised!(
        {NodeMonitor,
         monitor_opts(
           enabled: false,
           workers: [@test_node_name],
           heartbeat_interval: 50,
           connect_fn: connect_fn
         )}
      )

      Process.sleep(200)

      [{:count, count}] = :ets.lookup(connect_table, :count)
      assert count == 0, "disabled monitor should not attempt connections"
    end

    test "DistributedSupervisor remains empty" do
      start_supervised!(
        {NodeMonitor,
         monitor_opts(
           enabled: false,
           workers: [@test_node_name],
           heartbeat_interval: 60_000
         )}
      )

      assert DistributedSupervisor.list_nodes(@ds_name) == []
    end
  end

  # ── Enabled mode ─────────────────────────────────────────────────────────

  describe "enabled mode" do
    test "node enters connected state on {:nodeup}" do
      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             heartbeat_interval: 60_000
           )}
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)

      status = nm_status()

      assert @test_node_atom in status.connected_nodes,
             "node should be connected after {:nodeup}"

      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name),
             "node should be in DistributedSupervisor"
    end

    test "node enters grace period on {:nodedown}" do
      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             disconnect_timeout: 10_000,
             heartbeat_interval: 60_000
           )}
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)

      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(50)

      status = nm_status()

      assert @test_node_atom in status.grace_period_nodes,
             "node should be in grace period after {:nodedown}"
    end

    test "grace period expiry removes node" do
      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             disconnect_timeout: 50,
             heartbeat_interval: 50
           )}
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(20)

      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(20)

      # Node in grace
      assert @test_node_atom in nm_status().grace_period_nodes

      Process.sleep(200)

      status = nm_status()
      assert @test_node_atom not in status.connected_nodes
      assert @test_node_atom not in status.disconnected_nodes
      assert @test_node_atom not in status.grace_period_nodes

      assert DistributedSupervisor.list_nodes(@ds_name) == [],
             "node should be removed from DistributedSupervisor after grace expiry"
    end

    test "reconnects during grace period" do
      flag_table = :ets.new(:reconnect_flag, [:set, :public])
      :ets.insert(flag_table, {:should_connect, false})

      connect_fn = fn _node ->
        [{:should_connect, val}] = :ets.lookup(flag_table, :should_connect)
        val
      end

      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             heartbeat_interval: 50,
             disconnect_timeout: 10_000,
             connect_fn: connect_fn
           )}
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)

      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(50)

      assert @test_node_atom in nm_status().grace_period_nodes

      # Enable reconnection
      :ets.insert(flag_table, {:should_connect, true})

      # Trigger recheck
      GenServer.cast(@nm_name, :recheck)
      Process.sleep(200)

      status = nm_status()

      assert @test_node_atom in status.connected_nodes,
             "node should reconnect before grace period expires"

      assert @test_node_atom in DistributedSupervisor.list_nodes(@ds_name),
             "reconnected node should be in DistributedSupervisor"
    end

    test "nodeup after nodedown recovers connection" do
      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             heartbeat_interval: 60_000
           )}
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)
      assert @test_node_atom in nm_status().connected_nodes

      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(50)
      assert @test_node_atom in nm_status().grace_period_nodes

      # Recover via new {:nodeup}
      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)

      status = nm_status()

      assert @test_node_atom in status.connected_nodes,
             "new {:nodeup} should recover connection"
    end
  end

  # ── Telemetry ────────────────────────────────────────────────────────────

  describe "telemetry events" do
    test "emits node_connected on {:nodeup}" do
      events = [
        [:code_puppy, :distributed_pack, :node, :connected],
        [:code_puppy, :distributed_pack, :node, :disconnected],
        [:code_puppy, :distributed_pack, :node, :reconnected]
      ]

      handler_id = make_ref()

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, _measurements, metadata, acc ->
          event_type = List.last(event_name)
          send(acc, {:"telemetry_#{event_type}", metadata})
        end,
        self()
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             heartbeat_interval: 60_000
           )}
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)

      assert_received {:telemetry_connected, metadata}
      assert metadata.node == @test_node_atom
      assert metadata.capabilities == %{}
    end

    test "emits node_disconnected on {:nodedown}" do
      events = [
        [:code_puppy, :distributed_pack, :node, :connected],
        [:code_puppy, :distributed_pack, :node, :disconnected],
        [:code_puppy, :distributed_pack, :node, :reconnected]
      ]

      handler_id = make_ref()

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, _measurements, metadata, acc ->
          event_type = List.last(event_name)
          send(acc, {:"telemetry_#{event_type}", metadata})
        end,
        self()
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             heartbeat_interval: 60_000
           )}
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(50)

      assert_received {:telemetry_disconnected, metadata}
      assert metadata.node == @test_node_atom
      assert metadata.reason == :nodedown
      assert metadata.active_runs == []
    end

    test "emits node_reconnected on successful reconnect during grace" do
      events = [
        [:code_puppy, :distributed_pack, :node, :connected],
        [:code_puppy, :distributed_pack, :node, :disconnected],
        [:code_puppy, :distributed_pack, :node, :reconnected]
      ]

      handler_id = make_ref()

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, _measurements, metadata, acc ->
          event_type = List.last(event_name)
          send(acc, {:"telemetry_#{event_type}", metadata})
        end,
        self()
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      flag_table = :ets.new(:reconnect_flag, [:set, :public])
      :ets.insert(flag_table, {:should_connect, false})

      connect_fn = fn _node ->
        [{:should_connect, val}] = :ets.lookup(flag_table, :should_connect)
        val
      end

      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             heartbeat_interval: 50,
             disconnect_timeout: 10_000,
             connect_fn: connect_fn
           )}
        )

      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(50)

      assert @test_node_atom in nm_status().grace_period_nodes

      # Enable reconnection and trigger recheck
      :ets.insert(flag_table, {:should_connect, true})
      GenServer.cast(@nm_name, :recheck)
      Process.sleep(200)

      assert_received {:telemetry_reconnected, metadata}
      assert metadata.node == @test_node_atom
      assert is_integer(metadata.grace_period_ms)
    end
  end

  # ── Full lifecycle ───────────────────────────────────────────────────────

  describe "full lifecycle" do
    test "configure workers → connect → status → disconnect → grace → reconnect" do
      events = [
        [:code_puppy, :distributed_pack, :node, :connected],
        [:code_puppy, :distributed_pack, :node, :disconnected],
        [:code_puppy, :distributed_pack, :node, :reconnected]
      ]

      handler_id = make_ref()
      received_events = :ets.new(:lifecycle_events, [:set, :public])

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, _measurements, metadata, table ->
          event_type = List.last(event_name)
          :ets.insert(table, {event_type, metadata})
        end,
        received_events
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      flag_table = :ets.new(:reconnect_flag, [:set, :public])
      :ets.insert(flag_table, {:should_connect, false})

      connect_fn = fn _node ->
        [{:should_connect, val}] = :ets.lookup(flag_table, :should_connect)
        val
      end

      # Step 1: Start NodeMonitor
      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           monitor_opts(
             enabled: true,
             workers: [@test_node_name],
             heartbeat_interval: 50,
             disconnect_timeout: 60_000,
             connect_fn: connect_fn
           )}
        )

      # Step 2: Configure workers via status check
      status = nm_status()
      assert status.configured_workers == [@test_node_name]

      # Step 3: Connect via {:nodeup}
      send(pid, {:nodeup, @test_node_atom})
      Process.sleep(50)

      status = nm_status()

      assert @test_node_atom in status.connected_nodes,
             "Step 3: node should be connected"

      assert DistributedSupervisor.list_nodes(@ds_name) |> length() == 1,
             "Step 3: one node in DistributedSupervisor"

      # Step 4: Check status
      status = nm_status()
      assert length(status.connected_nodes) == 1
      assert status.disconnected_nodes == []
      assert status.grace_period_nodes == []

      # Step 5: Disconnect via {:nodedown}
      send(pid, {:nodedown, @test_node_atom})
      Process.sleep(50)

      status = nm_status()

      assert @test_node_atom in status.grace_period_nodes,
             "Step 5: node should enter grace period"

      # Step 6: Reconnect during grace
      :ets.insert(flag_table, {:should_connect, true})
      GenServer.cast(@nm_name, :recheck)
      Process.sleep(300)

      status = nm_status()

      assert @test_node_atom in status.connected_nodes,
             "Step 6: node should reconnect during grace"

      assert DistributedSupervisor.list_nodes(@ds_name) |> length() == 1,
             "Step 6: reconnected node should be in DistributedSupervisor"

      # Verify telemetry events were captured
      assert :ets.lookup(received_events, :connected) != [],
             "should have received node:connected telemetry"

      assert :ets.lookup(received_events, :disconnected) != [],
             "should have received node:disconnected telemetry"
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

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
end
