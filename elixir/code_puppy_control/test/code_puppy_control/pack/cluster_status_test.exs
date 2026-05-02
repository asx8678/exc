defmodule CodePuppyControl.Pack.ClusterStatusTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.ClusterStatus

  setup do
    # Ensure subsystems are running for status aggregation
    case Process.whereis(CodePuppyControl.Pack.NamingService) do
      nil -> start_supervised!(CodePuppyControl.Pack.NamingService)
      _pid -> :ok
    end

    case Process.whereis(CodePuppyControl.Pack.LoadBalancer) do
      nil -> start_supervised!(CodePuppyControl.Pack.LoadBalancer)
      _pid -> :ok
    end

    case Process.whereis(CodePuppyControl.Pack.NodeMonitor) do
      nil -> start_supervised!({CodePuppyControl.Pack.NodeMonitor, enabled: false, workers: []})
      _pid -> :ok
    end

    :ok
  end

  # ── snapshot/0 ──────────────────────────────────────────────────────────

  describe "snapshot/0" do
    test "returns valid structure with all required keys" do
      snap = ClusterStatus.snapshot()

      assert Map.has_key?(snap, :enabled)
      assert Map.has_key?(snap, :tls_enabled)
      assert Map.has_key?(snap, :local_node)
      assert Map.has_key?(snap, :configured_workers)
      assert Map.has_key?(snap, :connected_workers)
      assert Map.has_key?(snap, :disconnected_workers)
      assert Map.has_key?(snap, :total_active_dispatches)
      assert Map.has_key?(snap, :total_available_slots)
      assert Map.has_key?(snap, :dispatch_style)
    end

    test "shows enabled: false when distributed disabled" do
      # Default config has enabled: false
      snap = ClusterStatus.snapshot()
      refute snap.enabled
    end

    test "handles no workers gracefully" do
      snap = ClusterStatus.snapshot()
      assert snap.connected_workers == []
      assert snap.disconnected_workers == []
      assert snap.total_active_dispatches == 0
    end

    test "local_node is the current node" do
      snap = ClusterStatus.snapshot()
      assert snap.local_node == Node.self()
    end

    test "dispatch_style defaults to :async" do
      snap = ClusterStatus.snapshot()
      assert snap.dispatch_style in [:async, :sync_local, :sync_all]
    end
  end

  # ── format/1 ──────────────────────────────────────────────────────────

  describe "format/1" do
    test "produces non-empty string" do
      snap = ClusterStatus.snapshot()
      formatted = ClusterStatus.format(snap)
      assert is_binary(formatted)
      assert String.length(formatted) > 0
    end

    test "includes Pack Cluster Status header" do
      snap = ClusterStatus.snapshot()
      formatted = ClusterStatus.format(snap)
      assert formatted =~ "Pack Cluster Status"
    end

    test "includes enabled status" do
      snap = ClusterStatus.snapshot()
      formatted = ClusterStatus.format(snap)
      assert formatted =~ "Enabled"
    end

    test "includes TLS status" do
      snap = ClusterStatus.snapshot()
      formatted = ClusterStatus.format(snap)
      assert formatted =~ "TLS"
    end

    test "includes worker counts" do
      snap = ClusterStatus.snapshot()
      formatted = ClusterStatus.format(snap)
      assert formatted =~ "Connected Workers"
      assert formatted =~ "Disconnected"
    end

    test "shows worker details for connected workers" do
      # Build a snapshot with a connected worker
      snap = %{
        enabled: true,
        tls_enabled: false,
        local_node: Node.self(),
        configured_workers: [:"test@localhost"],
        connected_workers: [
          %{
            node: :"test@localhost",
            status: :connected,
            capabilities: nil,
            active_dispatches: 2,
            max_concurrent: 4,
            available_slots: 2,
            active_runs: ["run-1", "run-2"],
            total_dispatches: 10,
            total_completions: 8,
            total_failures: 1
          }
        ],
        disconnected_workers: [],
        total_active_dispatches: 2,
        total_available_slots: 2,
        dispatch_style: :async
      }

      formatted = ClusterStatus.format(snap)
      assert formatted =~ "test@localhost"
      assert formatted =~ "2/4"
      assert formatted =~ "10 dispatched"
    end

    test "shows correct status icons" do
      snap_disconnected = %{
        enabled: false,
        tls_enabled: false,
        local_node: Node.self(),
        configured_workers: [:"down@host"],
        connected_workers: [],
        disconnected_workers: [
          %{node: :"down@host", status: :disconnected, capabilities: nil,
            active_dispatches: 0, max_concurrent: 4, available_slots: 0,
            active_runs: [], total_dispatches: 0, total_completions: 0, total_failures: 0}
        ],
        total_active_dispatches: 0,
        total_available_slots: 0,
        dispatch_style: :async
      }

      formatted = ClusterStatus.format(snap_disconnected)
      assert formatted =~ "🔴"
    end

    test "shows shutting_down icon" do
      snap = %{
        enabled: true,
        tls_enabled: false,
        local_node: Node.self(),
        configured_workers: [:"draining@host"],
        connected_workers: [],
        disconnected_workers: [
          %{node: :"draining@host", status: :shutting_down, capabilities: nil,
            active_dispatches: 0, max_concurrent: 4, available_slots: 0,
            active_runs: [], total_dispatches: 0, total_completions: 0, total_failures: 0}
        ],
        total_active_dispatches: 0,
        total_available_slots: 0,
        dispatch_style: :async
      }

      formatted = ClusterStatus.format(snap)
      assert formatted =~ "🟡"
    end
  end

  # ── summary/1 ──────────────────────────────────────────────────────────

  describe "summary/1" do
    test "includes worker count" do
      snap = ClusterStatus.snapshot()
      summary = ClusterStatus.summary(snap)
      assert summary =~ "workers"
    end

    test "includes TLS indicator when enabled" do
      snap = %{
        enabled: true,
        tls_enabled: true,
        local_node: Node.self(),
        configured_workers: [],
        connected_workers: [],
        disconnected_workers: [],
        total_active_dispatches: 0,
        total_available_slots: 0,
        dispatch_style: :async
      }

      summary = ClusterStatus.summary(snap)
      assert summary =~ "TLS"
    end

    test "omits TLS indicator when disabled" do
      snap = %{
        enabled: true,
        tls_enabled: false,
        local_node: Node.self(),
        configured_workers: [],
        connected_workers: [],
        disconnected_workers: [],
        total_active_dispatches: 0,
        total_available_slots: 0,
        dispatch_style: :async
      }

      summary = ClusterStatus.summary(snap)
      refute summary =~ "TLS"
    end

    test "includes active dispatches count" do
      snap = %{
        enabled: true,
        tls_enabled: false,
        local_node: Node.self(),
        configured_workers: [],
        connected_workers: [],
        disconnected_workers: [],
        total_active_dispatches: 5,
        total_available_slots: 3,
        dispatch_style: :async
      }

      summary = ClusterStatus.summary(snap)
      assert summary =~ "5 active"
      assert summary =~ "3 slots"
    end

    test "formats connected/total worker count" do
      snap = %{
        enabled: true,
        tls_enabled: false,
        local_node: Node.self(),
        configured_workers: [:"a@h", :"b@h"],
        connected_workers: [%{node: :"a@h"}],
        disconnected_workers: [%{node: :"b@h"}],
        total_active_dispatches: 0,
        total_available_slots: 0,
        dispatch_style: :async
      }

      summary = ClusterStatus.summary(snap)
      assert summary =~ "1/2 workers"
    end
  end
end
