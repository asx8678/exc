defmodule CodePuppyControl.Pack.NodeMonitorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.NodeMonitor

  @event_prefix [:code_puppy, :distributed_pack]

  # async: false because we start named processes (NodeMonitor) and
  # manipulate Application env.

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp attach_handler(event_name, test_pid, ref) do
    :telemetry.attach(
      ref,
      event_name,
      fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
  end

  # Generate a unique name for each test to avoid name collisions
  defp unique_name(test_ctx) do
    {:via, Registry, {CodePuppyControl.Pack.Registry, {:node_monitor, test_ctx.line}}}
  end

  setup context do
    # Ensure the Pack Registry is available for via-tuple lookups
    {:ok, _} = start_supervised({Registry, keys: :unique, name: CodePuppyControl.Pack.Registry})

    # Clean up app env
    original = Application.get_env(:code_puppy_control, :distributed_packs)
    Application.delete_env(:code_puppy_control, :distributed_packs)

    on_exit(fn ->
      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      else
        Application.delete_env(:code_puppy_control, :distributed_packs)
      end
    end)

    name = unique_name(context)
    {:ok, name: name}
  end

  # ── Disabled Mode ────────────────────────────────────────────────────────

  describe "disabled mode (default)" do
    test "starts in disabled mode with no monitoring", %{name: name} do
      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [enabled: false, name: name]
        })

      assert Process.alive?(pid)
    end

    test "status/0 returns empty map when disabled", %{name: name} do
      start_supervised({NodeMonitor, [enabled: false, name: name]})
      assert NodeMonitor.status(name) == %{}
    end

    test "connected_nodes/0 returns empty list when disabled", %{name: name} do
      start_supervised({NodeMonitor, [enabled: false, name: name]})
      assert NodeMonitor.connected_nodes(name) == []
    end

    test "enabled?/0 returns false when disabled", %{name: name} do
      start_supervised({NodeMonitor, [enabled: false, name: name]})
      assert NodeMonitor.enabled?(name) == false
    end
  end

  # ── Enabled Mode ────────────────────────────────────────────────────────

  describe "enabled mode" do
    test "starts and reports enabled", %{name: name} do
      start_supervised({
        NodeMonitor,
        [enabled: true, workers: [], heartbeat_interval: 60_000, name: name]
      })

      assert NodeMonitor.enabled?(name) == true
    end

    test "initializes configured workers as disconnected", %{name: name} do
      worker = :pup_test_w@localhost

      start_supervised({
        NodeMonitor,
        [enabled: true, workers: [worker], heartbeat_interval: 60_000, name: name]
      })

      status = NodeMonitor.status(name)
      assert Map.has_key?(status, worker)
      assert status[worker].status == :disconnected
    end

    test "updates state on simulated nodeup", %{name: name} do
      worker = :pup_test_w2@localhost

      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [enabled: true, workers: [worker], heartbeat_interval: 60_000, name: name]
        })

      # Attach telemetry handler for node_connected event
      ref = make_ref()
      event = @event_prefix ++ [:node, :connected]
      attach_handler(event, self(), ref)

      # Simulate a nodeup message
      send(pid, {:nodeup, worker, []})

      # Allow message processing
      Process.sleep(50)

      status = NodeMonitor.status(name)
      assert status[worker].status == :connected
      assert is_integer(status[worker].connected_at)
    end

    test "emits telemetry on nodeup", %{name: name} do
      worker = :pup_test_w3@localhost

      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [enabled: true, workers: [worker], heartbeat_interval: 60_000, name: name]
        })

      ref = make_ref()
      event = @event_prefix ++ [:node, :connected]
      attach_handler(event, self(), ref)

      send(pid, {:nodeup, worker, []})
      Process.sleep(50)

      assert_receive {^ref, ^event, _measurements, metadata}
      assert metadata.node == worker
    end

    test "updates state on simulated nodedown", %{name: name} do
      worker = :pup_test_w4@localhost

      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [
            enabled: true,
            workers: [worker],
            heartbeat_interval: 60_000,
            disconnect_timeout: 5_000,
            name: name
          ]
        })

      # First connect
      send(pid, {:nodeup, worker, []})
      Process.sleep(50)

      # Then disconnect
      ref = make_ref()
      event = @event_prefix ++ [:node, :disconnected]
      attach_handler(event, self(), ref)

      send(pid, {:nodedown, worker, [nodedown_reason: :connection_closed]})
      Process.sleep(50)

      status = NodeMonitor.status(name)
      assert status[worker].status == :disconnected
      assert is_integer(status[worker].disconnected_at)

      # Telemetry was emitted
      assert_receive {^ref, ^event, _measurements, metadata}
      assert metadata.node == worker
      assert metadata.reason == :connection_closed
    end

    test "emits reconnected telemetry when previously-disconnected node reconnects",
         %{name: name} do
      worker = :pup_test_w5@localhost

      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [
            enabled: true,
            workers: [worker],
            heartbeat_interval: 60_000,
            disconnect_timeout: 60_000,
            name: name
          ]
        })

      # Connect
      send(pid, {:nodeup, worker, []})
      Process.sleep(50)

      # Disconnect
      send(pid, {:nodedown, worker, [nodedown_reason: :net_tick_timeout]})
      Process.sleep(50)

      # Now reconnect
      ref = make_ref()
      event = @event_prefix ++ [:node, :reconnected]
      attach_handler(event, self(), ref)

      send(pid, {:nodeup, worker, []})
      Process.sleep(50)

      assert_receive {^ref, ^event, _measurements, metadata}
      assert metadata.node == worker
      assert is_integer(metadata.grace_period_ms)
      assert metadata.grace_period_ms >= 0

      # State reflects reconnected
      status = NodeMonitor.status(name)
      assert status[worker].status == :connected
    end

    test "refresh/0 triggers heartbeat without error", %{name: name} do
      start_supervised({
        NodeMonitor,
        [enabled: true, workers: [], heartbeat_interval: 60_000, name: name]
      })

      assert :ok = NodeMonitor.refresh(name)
    end

    test "connected_nodes/0 returns only connected nodes", %{name: name} do
      w1 = :pup_w1@localhost
      w2 = :pup_w2@localhost

      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [enabled: true, workers: [w1, w2], heartbeat_interval: 60_000, name: name]
        })

      # Initially, no connected nodes
      assert NodeMonitor.connected_nodes(name) == []

      # Connect w1 only
      send(pid, {:nodeup, w1, []})
      Process.sleep(50)

      connected = NodeMonitor.connected_nodes(name)
      assert w1 in connected
      refute w2 in connected
    end
  end

  # ── Edge Cases ───────────────────────────────────────────────────────────

  describe "edge cases" do
    test "ignores nodeup from unconfigured node", %{name: name} do
      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [enabled: true, workers: [], heartbeat_interval: 60_000, name: name]
        })

      unknown = :unknown@alien_host

      send(pid, {:nodeup, unknown, []})
      Process.sleep(50)

      status = NodeMonitor.status(name)
      refute Map.has_key?(status, unknown)
    end

    test "ignores nodedown from unconfigured node", %{name: name} do
      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [enabled: true, workers: [], heartbeat_interval: 60_000, name: name]
        })

      unknown = :unknown@alien_host

      send(pid, {:nodedown, unknown, []})
      Process.sleep(50)

      # Should not crash
      assert NodeMonitor.status(name) == %{}
    end

    test "node_status/1 returns nil for unknown node", %{name: name} do
      start_supervised({
        NodeMonitor,
        [enabled: true, workers: [], heartbeat_interval: 60_000, name: name]
      })

      assert NodeMonitor.node_status(:totally_unknown@nowhere, name) == nil
    end
  end

  # ── Phase I.4: In-flight Run Tracking ────────────────────────────────

  describe "in-flight run tracking (Phase I.4)" do
    test "register_run/2 adds run to node's active_runs", %{name: name} do
      worker = :pup_run_test@localhost

      start_supervised({
        NodeMonitor,
        [enabled: true, workers: [worker], heartbeat_interval: 60_000, name: name]
      })

      # Initially no active runs
      assert NodeMonitor.active_runs(worker, name) == []

      # Register a run
      NodeMonitor.register_run(worker, "run-001", name)
      Process.sleep(50)

      assert NodeMonitor.active_runs(worker, name) == ["run-001"]
    end

    test "unregister_run/2 removes it", %{name: name} do
      worker = :pup_run_test2@localhost

      start_supervised({
        NodeMonitor,
        [enabled: true, workers: [worker], heartbeat_interval: 60_000, name: name]
      })

      NodeMonitor.register_run(worker, "run-002", name)
      NodeMonitor.register_run(worker, "run-003", name)
      Process.sleep(50)

      # Two runs registered
      runs = NodeMonitor.active_runs(worker, name)
      assert length(runs) == 2
      assert "run-002" in runs
      assert "run-003" in runs

      # Unregister one
      NodeMonitor.unregister_run(worker, "run-002", name)
      Process.sleep(50)

      runs = NodeMonitor.active_runs(worker, name)
      assert runs == ["run-003"]
    end

    test "active_runs/1 returns current list for unknown node", %{name: name} do
      start_supervised({
        NodeMonitor,
        [enabled: true, workers: [], heartbeat_interval: 60_000, name: name]
      })

      # Unknown node has no active runs
      assert NodeMonitor.active_runs(:unknown@nowhere, name) == []
    end

    test "grace expiry clears active_runs AND removes from LoadBalancer", %{name: name} do
      worker = :pup_grace_test@localhost

      # Start NamingService and LoadBalancer for this test
      {:ok, _} = start_supervised({CodePuppyControl.Pack.NamingService, []})
      {:ok, _} = start_supervised({CodePuppyControl.Pack.LoadBalancer, []})

      {:ok, pid} =
        start_supervised({
          NodeMonitor,
          [
            enabled: true,
            workers: [worker],
            heartbeat_interval: 60_000,
            disconnect_timeout: 100,
            name: name
          ]
        })

      # Connect the node
      send(pid, {:nodeup, worker, []})
      Process.sleep(50)

      # Register some active runs
      NodeMonitor.register_run(worker, "run-g1", name)
      NodeMonitor.register_run(worker, "run-g2", name)
      Process.sleep(50)

      # Verify runs are registered
      runs = NodeMonitor.active_runs(worker, name)
      assert length(runs) == 2

      # Sync with LoadBalancer so it tracks the node
      CodePuppyControl.Pack.NamingService.register_capabilities(
        worker,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      CodePuppyControl.Pack.LoadBalancer.sync_node(worker)
      Process.sleep(50)

      # Verify LoadBalancer knows the node
      snapshot = CodePuppyControl.Pack.LoadBalancer.load_snapshot()
      assert Map.has_key?(snapshot, worker)

      # Disconnect the node — triggers grace period
      send(pid, {:nodedown, worker, [nodedown_reason: :connection_closed]})
      Process.sleep(50)

      # Wait for grace period to expire (100ms)
      Process.sleep(200)

      # Active runs should be cleared
      runs = NodeMonitor.active_runs(worker, name)
      assert runs == []

      # LoadBalancer should have removed the node
      snapshot = CodePuppyControl.Pack.LoadBalancer.load_snapshot()
      refute Map.has_key?(snapshot, worker)
    end
  end
end
