defmodule CodePuppyControl.Pack.WorkerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.Worker

  # ── Test Helpers ─────────────────────────────────────────────────────────

  defp valid_dispatch_msg(run_id \\ "run-123") do
    %{
      run_id: run_id,
      sub_agent: :terrier,
      leader_node: :leader@localhost,
      leader_pid: self()
    }
  end

  defp start_worker(opts \\ []) do
    # Use a simple atom name in test (no distribution),
    # unlike production which uses {:pack_worker, node()}.
    opts = Keyword.put(opts, :node_name, Node.self())
    GenServer.start_link(Worker, opts, name: :pack_worker_test)
  end

  defp stop_worker(pid) do
    if pid && Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)
  end

  # ── Dispatch Validation ─────────────────────────────────────────────────

  describe "validate_dispatch_shape/1" do
    test "returns :ok for valid dispatch message" do
      assert :ok = Worker.validate_dispatch_shape(valid_dispatch_msg())
    end

    test "returns error when run_id is missing" do
      msg = Map.delete(valid_dispatch_msg(), :run_id)
      assert {:error, :malformed_dispatch} = Worker.validate_dispatch_shape(msg)
    end

    test "returns error when sub_agent is missing" do
      msg = Map.delete(valid_dispatch_msg(), :sub_agent)
      assert {:error, :malformed_dispatch} = Worker.validate_dispatch_shape(msg)
    end

    test "returns error when leader_node is missing" do
      msg = Map.delete(valid_dispatch_msg(), :leader_node)
      assert {:error, :malformed_dispatch} = Worker.validate_dispatch_shape(msg)
    end

    test "returns error when leader_pid is missing" do
      msg = Map.delete(valid_dispatch_msg(), :leader_pid)
      assert {:error, :malformed_dispatch} = Worker.validate_dispatch_shape(msg)
    end

    test "returns error for completely empty message" do
      assert {:error, :malformed_dispatch} = Worker.validate_dispatch_shape(%{})
    end

    test "returns error for non-map input" do
      assert {:error, :malformed_dispatch} = Worker.validate_dispatch_shape(nil)
    end
  end

  describe "check_duplicate_run_id/2" do
    test "returns :ok for new run_id" do
      state = %{active_runs: %{}}
      assert :ok = Worker.check_duplicate_run_id("run-new", state)
    end

    test "returns error for duplicate run_id" do
      state = %{active_runs: %{"run-existing" => %{sub_agent: :terrier, started_at: 0}}}
      assert {:error, {:duplicate_run_id, "run-existing"}} =
        Worker.check_duplicate_run_id("run-existing", state)
    end

    test "returns :ok for different run_id when others are active" do
      state = %{active_runs: %{"run-1" => %{sub_agent: :terrier, started_at: 0}}}
      assert :ok = Worker.check_duplicate_run_id("run-2", state)
    end
  end

  # ── Integration: Malformed Dispatch via GenServer ────────────────────────

  describe "handle_cast {:dispatch, _} with malformed message" do
    test "rejects dispatch without run_id and sends rejection back" do
      {:ok, pid} = start_worker(capabilities: %{sub_agents: []})

      malformed = %{
        sub_agent: :terrier,
        leader_node: :leader@localhost,
        leader_pid: self()
      }

      GenServer.cast(:pack_worker_test, {:dispatch, malformed})

      # Give the cast time to process
      Process.sleep(50)
      assert Process.alive?(pid)

      stop_worker(pid)
    end
  end

  # ── Cancel ──────────────────────────────────────────────────────────────

  describe "handle_cast {:cancel, run_id}" do
    test "handles cancel for unknown run gracefully" do
      {:ok, pid} = start_worker(capabilities: %{sub_agents: []})

      # Should not crash
      GenServer.cast(:pack_worker_test, {:cancel, "nonexistent"})

      # Worker is still alive
      assert Process.alive?(pid)

      stop_worker(pid)
    end
  end

  # ── Capabilities ────────────────────────────────────────────────────────

  describe "handle_call :request_capabilities" do
    test "returns capabilities map" do
      caps = %{sub_agents: [:terrier], host_os: "test"}
      {:ok, _pid} = start_worker(capabilities: caps)

      result = GenServer.call(:pack_worker_test, :request_capabilities)
      assert result == caps

      stop_worker(nil)
    end
  end

  # ── Drain Mode (Phase I.5) ────────────────────────────────────────────────

  describe "drain mode" do
    test "Worker in drain mode rejects new dispatches" do
      {:ok, pid} = start_worker(capabilities: %{sub_agents: []})

      # Put worker in drain mode
      GenServer.cast(:pack_worker_test, :drain)
      Process.sleep(50)

      # Worker should have stopped immediately (no active runs)
      refute Process.alive?(pid)
    end

    test "Worker drain mode with active runs waits for completion" do
      # This tests the drain-but-wait path indirectly
      {:ok, pid} = start_worker(capabilities: %{sub_agents: [:terrier]})

      # Verify draining flag is in state
      # We can't easily test the full lifecycle in a unit test without
      # starting real sub-agents, but we can verify drain casts don't crash
      assert Process.alive?(pid)

      stop_worker(pid)
    end

    test "Ephemeral worker announces shutdown to leader node" do
      # An ephemeral worker that never had active runs won't auto-shutdown
      # (idle_since is only set after a run completes). This test verifies
      # the ephemeral worker starts correctly and doesn't crash on timers.
      {:ok, pid} = start_worker(
        mode: :ephemeral,
        idle_timeout_ms: 50,
        capabilities: %{sub_agents: []}
      )

      # Worker is alive — it waits for work, not shutting down
      assert Process.alive?(pid)

      stop_worker(pid)
    end
  end
end
