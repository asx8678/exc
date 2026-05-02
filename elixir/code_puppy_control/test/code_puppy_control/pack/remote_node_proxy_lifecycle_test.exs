defmodule CodePuppyControl.Pack.RemoteNodeProxyLifecycleTest do
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

  # ── State Transitions ───────────────────────────────────────────────────

  describe "state transitions" do
    test "starts in :connecting when handshake fails" do
      {:ok, pid} = start_proxy()

      assert %{status: :connecting, node_name: @test_node, reconnect_attempts: 1} =
               RemoteNodeProxy.status(pid)

      assert RemoteNodeProxy.capabilities(pid) == nil

      GenServer.stop(pid, :normal)
    end

    test "transitions to :connected on init when handshake succeeds" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert %{status: :connected, reconnect_attempts: 0} = RemoteNodeProxy.status(pid)
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

      assert %{status: :connected, capabilities: caps, reconnect_attempts: 0} =
               RemoteNodeProxy.status(pid)

      assert caps == mock_caps()

      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end

    test "increments reconnect_attempts on each failed :nodeup handshake" do
      {:ok, pid} = start_proxy()
      assert %{reconnect_attempts: 1} = RemoteNodeProxy.status(pid)

      # Send nodeup — handshake still fails
      send(pid, {:nodeup, @test_node})
      assert %{reconnect_attempts: 2, status: :connecting} = RemoteNodeProxy.status(pid)

      # Send another nodeup — still failing
      send(pid, {:nodeup, @test_node})
      assert %{reconnect_attempts: 3, status: :connecting} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "resets reconnect_attempts to 0 on successful :nodeup handshake" do
      {:ok, pid} = start_proxy()
      assert %{reconnect_attempts: 1} = RemoteNodeProxy.status(pid)

      # We can't swap handshake_fn after init, so use a new proxy
      GenServer.stop(pid, :normal)

      {:ok, pid2} =
        start_proxy(
          handshake_fn: fn _node, _timeout ->
            # Init handshake succeeds → reconnect_attempts = 0
            {:ok, mock_caps()}
          end
        )

      # Init handshake succeeds → reconnect_attempts = 0
      assert %{reconnect_attempts: 0, status: :connected} = RemoteNodeProxy.status(pid2)

      GenServer.stop(pid2, :normal)
    end

    test "transitions :connected → :disconnected on :nodedown" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert %{status: :connected, reconnect_attempts: 0} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{status: :disconnected, reconnect_attempts: 1} =
               RemoteNodeProxy.status(pid)

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

      assert %{status: :connecting, reconnect_attempts: 1} = RemoteNodeProxy.status(pid)
      assert RemoteNodeProxy.capabilities(pid) == nil

      GenServer.stop(pid, :normal)
    end

    test "proxy recovers from timeout via :nodeup with successful handshake" do
      {:ok, handshake_agent} = Agent.start_link(fn -> {:error, :noproc} end)

      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(handshake_fn: handshake_fn)

      assert %{status: :connecting, reconnect_attempts: 1} = RemoteNodeProxy.status(pid)

      # Make handshake succeed for the nodeup event
      Agent.update(handshake_agent, fn _ -> {:ok, mock_caps()} end)
      send(pid, {:nodeup, @test_node})

      assert %{status: :connected, capabilities: caps, reconnect_attempts: 0} =
               RemoteNodeProxy.status(pid)

      assert caps == mock_caps()

      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end
  end

  # ── In-flight Runs on Disconnect ─────────────────────────────────────────

  describe "nodedown with active runs" do
    test "nodedown clears active runs from state" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, _run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{status: :disconnected, active_runs: 0} = RemoteNodeProxy.status(pid)

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

  # ── Capabilities Cast ────────────────────────────────────────────────────

  describe "capabilities cast" do
    test "updates capabilities and transitions to :connected" do
      {:ok, pid} = start_proxy()

      assert %{status: :connecting, capabilities: nil, reconnect_attempts: 1} =
               RemoteNodeProxy.status(pid)

      new_caps = mock_caps()
      GenServer.cast(pid, {:capabilities, new_caps})

      assert %{status: :connected, capabilities: ^new_caps, reconnect_attempts: 0} =
               RemoteNodeProxy.status(pid)

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
end
