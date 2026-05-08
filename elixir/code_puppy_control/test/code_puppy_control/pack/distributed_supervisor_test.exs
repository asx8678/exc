defmodule CodePuppyControl.Pack.DistributedSupervisorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.DistributedSupervisor

  # Need async: false because we use a named Registry that must be started
  # per test and cleaned up after. Multiple tests racing on the same
  # Registry name would flake.

  setup do
    # Start a local Registry for via-tuple routing
    {:ok, _} = start_supervised({Registry, keys: :unique, name: CodePuppyControl.Pack.Registry})

    # Start the DistributedSupervisor under test
    {:ok, sup_pid} = start_supervised({DistributedSupervisor, []})

    %{sup_pid: sup_pid}
  end

  # ── Startup / Shutdown ──────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts and stops cleanly", %{sup_pid: pid} do
      assert Process.alive?(pid)
    end
  end

  # ── Children / Count ─────────────────────────────────────────────────────

  describe "children/0" do
    test "returns empty list initially" do
      assert DistributedSupervisor.children() == []
    end
  end

  describe "count/0" do
    test "returns 0 initially" do
      assert DistributedSupervisor.count() == 0
    end
  end

  # ── Start / Stop child ───────────────────────────────────────────────────

  describe "start_child/1 and stop_child/1" do
    test "can start and stop a simple child" do
      # Use a simple Agent as a stand-in child
      child_spec = %{
        id: :test_child_1,
        start: {Agent, :start_link, [fn -> 0 end, [name: :distributed_test_agent_1]]},
        restart: :transient
      }

      assert {:ok, pid} = DistributedSupervisor.start_child(child_spec)
      assert is_pid(pid)
      assert DistributedSupervisor.count() == 1

      assert :ok = DistributedSupervisor.stop_child(pid)
      # Give the supervisor a moment to clean up
      Process.sleep(50)
      assert DistributedSupervisor.count() == 0
    after
      # Clean up named agent if still alive
      if pid = Process.whereis(:distributed_test_agent_1) do
        Agent.stop(pid, :normal, 1000)
      end
    end
  end

  describe "children/0 after adding children" do
    test "lists active child pids" do
      child_spec = %{
        id: :test_child_2,
        start: {Agent, :start_link, [fn -> 0 end, [name: :distributed_test_agent_2]]},
        restart: :transient
      }

      {:ok, pid} = DistributedSupervisor.start_child(child_spec)
      children = DistributedSupervisor.children()

      assert pid in children

      DistributedSupervisor.stop_child(pid)
    after
      if pid = Process.whereis(:distributed_test_agent_2) do
        Agent.stop(pid, :normal, 1000)
      end
    end
  end
end
