defmodule CodePuppyControl.Runtime.SnapshotTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Runtime.Snapshot

  describe "snapshot/0" do
    test "returns a map with all top-level keys" do
      snap = Snapshot.snapshot()

      assert is_map(snap)
      assert Map.has_key?(snap, :processes)
      assert Map.has_key?(snap, :ports)
      assert Map.has_key?(snap, :memory_mb)
      assert Map.has_key?(snap, :schedulers)
      assert Map.has_key?(snap, :supervisors)
      assert Map.has_key?(snap, :limits)
      assert Map.has_key?(snap, :concurrency)
      assert Map.has_key?(snap, :rate_limiter)
    end

    test "processes has current and limit" do
      %{processes: procs} = Snapshot.snapshot()
      assert is_integer(procs.current)
      assert procs.current > 0
      assert is_integer(procs.limit)
      assert procs.limit >= procs.current
    end

    test "memory_mb returns floats" do
      %{memory_mb: mem} = Snapshot.snapshot()
      assert is_float(mem.total)
      assert mem.total > 0.0
    end

    test "supervisors have current/max/utilization" do
      %{supervisors: sups} = Snapshot.snapshot()
      assert Map.has_key?(sups, :mcp_servers)
      assert Map.has_key?(sups, :runs)

      for {_key, entry} <- sups do
        assert is_integer(entry.current)
        assert is_integer(entry.max)
        assert is_float(entry.utilization)
      end
    end

    test "limits has all Limits.all/0 keys" do
      %{limits: limits} = Snapshot.snapshot()
      assert Map.has_key?(limits, :max_mcp_servers)
      assert Map.has_key?(limits, :max_runs)
      assert Map.has_key?(limits, :cpu_concurrency)
    end
  end

  describe "print/0" do
    test "runs without raising" do
      import ExUnit.CaptureIO

      output = capture_io(fn -> assert Snapshot.print() == :ok end)
      assert output =~ "Runtime Snapshot"
      assert output =~ "Processes:"
      assert output =~ "Supervisors:"
    end
  end
end
