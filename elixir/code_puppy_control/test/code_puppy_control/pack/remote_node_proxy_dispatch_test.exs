defmodule CodePuppyControl.Pack.RemoteNodeProxyDispatchTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.RemoteNodeProxy

  @test_node :pup_test_worker@localhost

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_proxy(opts \\ []) do
    base = [
      node_name: @test_node,
      name: nil,
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end,
      grace_period_timeout: 0
    ]

    RemoteNodeProxy.start_link(Keyword.merge(base, opts))
  end

  defp mock_caps do
    %{
      node_name: @test_node,
      sub_agents: [:terrier, :watchdog],
      host_os: "linux",
      available_models: ["claude-sonnet-4-20250514"],
      max_concurrent_runs: 4,
      features: %{file_ops: true, shell_access: true, git_access: true}
    }
  end

  # ── Dispatch ─────────────────────────────────────────────────────────────

  describe "dispatch/3" do
    test "returns error when proxy is disconnected" do
      {:ok, pid} = start_proxy()
      # Force to disconnected state
      send(pid, {:nodedown, @test_node})

      assert %{status: :disconnected} = RemoteNodeProxy.status(pid)

      assert {:error, {:node_disconnected, @test_node}} =
               RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
    end

    test "returns error when proxy is connecting" do
      {:ok, pid} = start_proxy()

      assert %{status: :connecting} = RemoteNodeProxy.status(pid)

      assert {:error, {:node_not_ready, @test_node}} =
               RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      GenServer.stop(pid, :normal)
    end

    test "returns {:ok, run_id} when connected and tracks active run" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert %{status: :connected, active_runs: 0} = RemoteNodeProxy.status(pid)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert is_binary(run_id)
      assert String.starts_with?(run_id, "dist_")

      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "run_id format is dist_<ms>_<hash>" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :watchdog, %{worktree_path: "."})
      assert run_id =~ ~r/^dist_\d+_\d+$/

      GenServer.stop(pid, :normal)
    end
  end

  # ── Result / Progress Handling ────────────────────────────────────────────

  describe "worker result casts" do
    test "removes run from active_runs on :result" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      # Simulate worker sending result cast
      GenServer.cast(pid, {:result, run_id, %{status: :success, output: "done"}})

      # Let the cast be processed
      RemoteNodeProxy.status(pid)

      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "ignores result for unknown run_id" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      GenServer.cast(pid, {:result, "bogus_run_id", %{status: :success}})

      # Should not crash
      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "progress cast does not change active_runs" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      GenServer.cast(pid, {:progress, run_id, %{type: :milestone, message: "working..."}})

      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ── Dispatch Timeout ──────────────────────────────────────────────────────

  describe "dispatch timeout" do
    test "removes run from active_runs after dispatch timeout fires" do
      # Use a very short timeout so the test runs fast
      {:ok, pid} =
        start_proxy(
          handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end,
          dispatch_timeout: 50
        )

      assert {:ok, _run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      # Wait for the timeout to fire
      Process.sleep(100)

      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "emits dispatch exception telemetry on timeout" do
      events = [:code_puppy, :distributed_pack, :dispatch, :exception]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_dispatch_timeout, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(
          handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end,
          dispatch_timeout: 50
        )

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      # Wait for the timeout to fire
      Process.sleep(100)

      assert_received {:telemetry_dispatch_timeout, %{run_id: ^run_id, error: "dispatch_timeout"},
                       %{node: @test_node}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    @tag timeout: 500
    test "timer is cancelled when result arrives before timeout" do
      {:ok, pid} =
        start_proxy(
          handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end,
          dispatch_timeout: 5_000
        )

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      # Send result before timeout fires
      GenServer.cast(pid, {:result, run_id, %{status: :success, output: "done"}})
      RemoteNodeProxy.status(pid)

      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      # Verify no stale timeout message arrives later
      refute_receive {:dispatch_timeout, ^run_id}, 300

      GenServer.stop(pid, :normal)
    end

    test "timeout for unknown run_id is a no-op" do
      {:ok, pid} =
        start_proxy(
          handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end,
          dispatch_timeout: 5_000
        )

      # Send a manual dispatch_timeout for a non-existent run
      send(pid, {:dispatch_timeout, "bogus_run_id"})

      # Should not crash
      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ── reply_to mechanism ───────────────────────────────────────────────────

  describe "dispatch/4 reply_to" do
    test "sends {:dispatch_result, run_id, result} to reply_to pid when result arrives" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} =
               RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."}, reply_to: self())

      result = %{status: :success, output: "all done"}
      GenServer.cast(pid, {:result, run_id, result})
      # Flush the cast
      RemoteNodeProxy.status(pid)

      assert_received {:dispatch_result, ^run_id, ^result}

      GenServer.stop(pid, :normal)
    end

    test "does not send dispatch_result when reply_to is not set" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      # Default dispatch (no reply_to)
      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      result = %{status: :success, output: "done"}
      GenServer.cast(pid, {:result, run_id, result})
      # Flush the cast
      RemoteNodeProxy.status(pid)

      refute_received {:dispatch_result, _, _}

      GenServer.stop(pid, :normal)
    end
  end
end
