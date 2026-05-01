defmodule CodePuppyControl.Pack.RemoteNodeProxyTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.RemoteNodeProxy

  @test_node :pup_test_worker@localhost

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_proxy(opts \\ []) do
    base = [
      node_name: @test_node,
      name: nil,
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end
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

  # ── State Transitions ───────────────────────────────────────────────────

  describe "state transitions" do
    test "starts in :connecting when handshake fails" do
      {:ok, pid} = start_proxy()

      assert %{status: :connecting, node_name: @test_node} = RemoteNodeProxy.status(pid)
      assert RemoteNodeProxy.capabilities(pid) == nil

      GenServer.stop(pid, :normal)
    end

    test "transitions to :connected on init when handshake succeeds" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert %{status: :connected} = RemoteNodeProxy.status(pid)
      assert RemoteNodeProxy.capabilities(pid) == mock_caps()

      GenServer.stop(pid, :normal)
    end

    test "transitions :connecting → :connected on :nodeup with successful handshake" do
      {:ok, handshake_agent} = Agent.start_link(fn -> {:error, :noproc} end)

      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(handshake_fn: handshake_fn)

      assert %{status: :connecting} = RemoteNodeProxy.status(pid)

      # Now make handshake succeed and send nodeup
      Agent.update(handshake_agent, fn _ -> {:ok, mock_caps()} end)
      send(pid, {:nodeup, @test_node})

      assert %{status: :connected, capabilities: caps} = RemoteNodeProxy.status(pid)
      assert caps == mock_caps()

      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end

    test "transitions :connected → :disconnected on :nodedown" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert %{status: :connected} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{status: :disconnected} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "stays :connecting on :nodeup when re-handshake fails" do
      {:ok, handshake_agent} = Agent.start_link(fn -> {:error, :noproc} end)

      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(handshake_fn: handshake_fn)

      assert %{status: :connecting} = RemoteNodeProxy.status(pid)

      # Send nodeup but handshake still fails
      send(pid, {:nodeup, @test_node})

      assert %{status: :connecting} = RemoteNodeProxy.status(pid)

      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end

    test "ignores :nodeup / :nodedown for different nodes" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert %{status: :connected} = RemoteNodeProxy.status(pid)

      # nodedown for a different node — should not affect our state
      send(pid, {:nodedown, :other_node@host})

      assert %{status: :connected} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end
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

  # ── Capabilities Cast ────────────────────────────────────────────────────

  describe "capabilities cast" do
    test "updates capabilities and transitions to :connected" do
      {:ok, pid} = start_proxy()
      assert %{status: :connecting, capabilities: nil} = RemoteNodeProxy.status(pid)

      new_caps = mock_caps()
      GenServer.cast(pid, {:capabilities, new_caps})

      assert %{status: :connected, capabilities: ^new_caps} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "overwrites previous capabilities" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      initial_caps = mock_caps()
      assert %{capabilities: ^initial_caps} = RemoteNodeProxy.status(pid)

      updated_caps = %{initial_caps | max_concurrent_runs: 8}
      GenServer.cast(pid, {:capabilities, updated_caps})

      assert %{capabilities: ^updated_caps} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ── Capability Handshake Timeout ─────────────────────────────────────────

  describe "capability handshake timeout" do
    test "proxy stays in :connecting when handshake times out" do
      # handshake_fn simulates a slow worker that never responds
      # (in real code this would be an exit with :timeout)
      {:ok, pid} =
        start_proxy(
          handshake_fn: fn _node, _timeout ->
            {:error, {:timeout, {GenServer, :call, [@test_node]}}}
          end
        )

      assert %{status: :connecting} = RemoteNodeProxy.status(pid)
      assert RemoteNodeProxy.capabilities(pid) == nil

      GenServer.stop(pid, :normal)
    end

    test "proxy recovers from timeout via :nodeup with successful handshake" do
      {:ok, handshake_agent} = Agent.start_link(fn -> {:error, :noproc} end)

      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(handshake_fn: handshake_fn)

      assert %{status: :connecting} = RemoteNodeProxy.status(pid)

      # Make handshake succeed for the nodeup event
      Agent.update(handshake_agent, fn _ -> {:ok, mock_caps()} end)
      send(pid, {:nodeup, @test_node})

      assert %{status: :connected, capabilities: caps} = RemoteNodeProxy.status(pid)
      assert caps == mock_caps()

      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end
  end

  # ── In-flight Runs on Disconnect ─────────────────────────────────────────

  describe "nodedown with active runs" do
    test "nodedown does not remove active runs from state" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, _run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{status: :disconnected} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ── Node.monitor Integration ─────────────────────────────────────────────

  describe "Node.monitor/2 mock" do
    test "monitor_fn is called during init" do
      {:ok, monitor_agent} = Agent.start_link(fn -> [] end)

      monitor_fn = fn node, flag ->
        Agent.update(monitor_agent, fn calls -> [{node, flag} | calls] end)
        true
      end

      {:ok, _pid} = start_proxy(monitor_fn: monitor_fn)

      calls = Agent.get(monitor_agent, & &1)
      assert [{@test_node, true}] = calls

      Agent.stop(monitor_agent)
    end
  end

  # ── Telemetry ────────────────────────────────────────────────────────────

  describe "telemetry events" do
    test "emits node connected event on successful handshake" do
      events = [:code_puppy, :distributed_pack, :node, :connected]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_node_connected, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert_received {:telemetry_node_connected, %{node: @test_node}, %{capabilities: caps}}
      assert caps == mock_caps()

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits node disconnected event on nodedown" do
      events = [:code_puppy, :distributed_pack, :node, :disconnected]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_node_disconnected, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      send(pid, {:nodedown, @test_node})
      # Synchronous flush: status/1 call is processed AFTER the nodedown info
      RemoteNodeProxy.status(pid)

      assert_received {:telemetry_node_disconnected, %{node: @test_node}, %{active_runs: []}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits dispatch start on successful dispatch" do
      events = [:code_puppy, :distributed_pack, :dispatch, :start]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_dispatch_start, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      assert_received {:telemetry_dispatch_start, %{run_id: ^run_id},
                       %{node: @test_node, sub_agent: :terrier}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits dispatch stop on worker result" do
      events = [:code_puppy, :distributed_pack, :dispatch, :stop]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_dispatch_stop, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      GenServer.cast(pid, {:result, run_id, %{status: :success, output: "done"}})
      # Flush the cast
      RemoteNodeProxy.status(pid)

      assert_received {:telemetry_dispatch_stop,
                       %{run_id: ^run_id, duration_ms: dur, status: :success},
                       %{node: @test_node, sub_agent: :terrier}}

      assert is_integer(dur)

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits dispatch exception on nodedown with active runs" do
      events = [:code_puppy, :distributed_pack, :dispatch, :exception]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_dispatch_exception, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})
      # Synchronous flush
      RemoteNodeProxy.status(pid)

      assert_received {:telemetry_dispatch_exception,
                       %{run_id: ^run_id, error: "node_disconnected"}, %{node: @test_node}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits capabilities updated on capabilities cast" do
      events = [:code_puppy, :distributed_pack, :capabilities, :updated]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_caps_updated, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} = start_proxy()

      new_caps = mock_caps()
      GenServer.cast(pid, {:capabilities, new_caps})
      # Flush the cast
      RemoteNodeProxy.status(pid)

      assert_received {:telemetry_caps_updated, %{node: @test_node}, %{capabilities: ^new_caps}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end
  end
end
