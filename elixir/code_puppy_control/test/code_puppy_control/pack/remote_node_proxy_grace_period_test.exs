defmodule CodePuppyControl.Pack.RemoteNodeProxyGracePeriodTest do
  @moduledoc """
  Tests for the disconnect grace period mechanism in RemoteNodeProxy.

  When a worker node disconnects, the proxy enters a grace period during
  which in-flight runs are preserved. If the node reconnects within the
  grace period, the timer is cancelled and runs continue. If the grace
  period expires, remaining runs are marked as orphaned.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.RemoteNodeProxy

  @test_node :pup_grace_worker@localhost

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_proxy(opts \\ []) do
    base = [
      node_name: @test_node,
      name: nil,
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end,
      grace_period_timeout: 200
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

  defp attach_telemetry(event_suffix, label) do
    event = [:code_puppy, :pack, :node, event_suffix]
    handler_id = {label, make_ref()}

    :telemetry.attach(
      handler_id,
      event,
      fn _name, measurements, metadata, acc ->
        send(acc, {label, measurements, metadata})
      end,
      self()
    )

    handler_id
  end

  defp detach_all(handler_ids) do
    Enum.each(handler_ids, &:telemetry.detach/1)
  end

  # ── Grace Period Lifecycle ──────────────────────────────────────────────

  describe "grace period on nodedown" do
    test "transitions to :grace_period instead of :disconnected" do
      {:ok, pid} = start_proxy()

      assert %{status: :connected} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{status: :grace_period} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "preserves active_runs during grace period" do
      {:ok, pid} = start_proxy()

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{status: :grace_period, active_runs: 1} = RemoteNodeProxy.status(pid)

      runs = RemoteNodeProxy.in_flight_runs(pid)
      assert Map.has_key?(runs, run_id)

      GenServer.stop(pid, :normal)
    end

    test "rejects new dispatches during grace period" do
      {:ok, pid} = start_proxy()

      send(pid, {:nodedown, @test_node})

      assert %{status: :grace_period} = RemoteNodeProxy.status(pid)

      assert {:error, {:node_disconnected, @test_node}} =
               RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      GenServer.stop(pid, :normal)
    end

    test "starts grace period even without active runs" do
      {:ok, pid} = start_proxy()

      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{status: :grace_period, active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "increments reconnect_attempts on nodedown" do
      {:ok, pid} = start_proxy()

      assert %{reconnect_attempts: 0} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{reconnect_attempts: 1} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ── Grace Period Expiry ─────────────────────────────────────────────────

  describe "grace period expiry" do
    test "transitions to :disconnected and clears active_runs" do
      {:ok, pid} = start_proxy(grace_period_timeout: 50)

      assert {:ok, _run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})

      assert %{status: :grace_period, active_runs: 1} = RemoteNodeProxy.status(pid)

      # Wait for grace period to expire
      Process.sleep(100)

      assert %{status: :disconnected, active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "orphans multiple in-flight runs on expiry" do
      {:ok, pid} = start_proxy(grace_period_timeout: 50)

      assert {:ok, _r1} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert {:ok, _r2} = RemoteNodeProxy.dispatch(pid, :watchdog, %{worktree_path: "."})
      assert {:ok, _r3} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "/other"})

      assert %{active_runs: 3} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      assert %{status: :grace_period, active_runs: 3} = RemoteNodeProxy.status(pid)

      Process.sleep(100)

      assert %{status: :disconnected, active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "no-ops if grace period fires after reconnection" do
      {:ok, handshake_agent} = Agent.start_link(fn -> {:ok, mock_caps()} end)

      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(grace_period_timeout: 200, handshake_fn: handshake_fn)

      assert {:ok, _run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})

      assert %{status: :grace_period} = RemoteNodeProxy.status(pid)

      # Reconnect before grace period expires
      send(pid, {:nodeup, @test_node})

      assert %{status: :connected, active_runs: 1} = RemoteNodeProxy.status(pid)

      # Let the original timer fire — should be a no-op
      Process.sleep(250)

      assert %{status: :connected, active_runs: 1} = RemoteNodeProxy.status(pid)

      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end
  end

  # ── Grace Period Cancellation (nodeup) ──────────────────────────────────

  describe "grace period cancellation on nodeup" do
    test "cancels grace period and preserves in-flight runs" do
      {:ok, handshake_agent} = Agent.start_link(fn -> {:ok, mock_caps()} end)

      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(handshake_fn: handshake_fn)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})

      assert %{status: :grace_period, active_runs: 1} = RemoteNodeProxy.status(pid)

      send(pid, {:nodeup, @test_node})

      status = RemoteNodeProxy.status(pid)
      assert status.status == :connected
      assert status.active_runs == 1

      runs = RemoteNodeProxy.in_flight_runs(pid)
      assert Map.has_key?(runs, run_id)

      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end

    test "resets reconnect_attempts on successful reconnection" do
      {:ok, handshake_agent} = Agent.start_link(fn -> {:ok, mock_caps()} end)

      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(handshake_fn: handshake_fn)

      send(pid, {:nodedown, @test_node})

      assert %{reconnect_attempts: 1} = RemoteNodeProxy.status(pid)

      send(pid, {:nodeup, @test_node})

      assert %{reconnect_attempts: 0} = RemoteNodeProxy.status(pid)

      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end
  end

  # ── in_flight_runs/1 API ────────────────────────────────────────────────

  describe "in_flight_runs/1" do
    test "returns empty map when no runs dispatched" do
      {:ok, pid} = start_proxy()

      assert RemoteNodeProxy.in_flight_runs(pid) == %{}

      GenServer.stop(pid, :normal)
    end

    test "tracks dispatched runs with correct metadata" do
      {:ok, pid} = start_proxy()

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      runs = RemoteNodeProxy.in_flight_runs(pid)
      assert map_size(runs) == 1
      assert %{sub_agent: :terrier, status: :dispatched} = runs[run_id]

      GenServer.stop(pid, :normal)
    end

    test "removes run when result arrives" do
      {:ok, pid} = start_proxy()

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert map_size(RemoteNodeProxy.in_flight_runs(pid)) == 1

      GenServer.cast(pid, {:result, run_id, %{status: :success}})
      # Flush the cast
      RemoteNodeProxy.status(pid)

      assert RemoteNodeProxy.in_flight_runs(pid) == %{}

      GenServer.stop(pid, :normal)
    end

    test "preserves runs during grace period" do
      {:ok, pid} = start_proxy()

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})

      runs = RemoteNodeProxy.in_flight_runs(pid)
      assert Map.has_key?(runs, run_id)
      assert runs[run_id].sub_agent == :terrier

      GenServer.stop(pid, :normal)
    end
  end

  # ── Telemetry Events ────────────────────────────────────────────────────

  describe "grace period telemetry" do
    test "emits grace_period_started on nodedown" do
      h = attach_telemetry(:grace_period_started, :gp_started)

      {:ok, pid} = start_proxy()

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})
      # Flush
      RemoteNodeProxy.status(pid)

      assert_received {:gp_started, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.node == @test_node
      assert metadata.timeout_ms == 200
      assert run_id in metadata.in_flight_runs

      detach_all([h])
      GenServer.stop(pid, :normal)
    end

    test "emits grace_period_cancelled on nodeup during grace period" do
      h = attach_telemetry(:grace_period_cancelled, :gp_cancelled)

      {:ok, handshake_agent} = Agent.start_link(fn -> {:ok, mock_caps()} end)
      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(handshake_fn: handshake_fn)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})
      RemoteNodeProxy.status(pid)

      send(pid, {:nodeup, @test_node})
      RemoteNodeProxy.status(pid)

      assert_received {:gp_cancelled, _measurements, metadata}
      assert metadata.node == @test_node
      assert run_id in metadata.in_flight_runs

      detach_all([h])
      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end

    test "emits grace_period_expired when timer fires" do
      h = attach_telemetry(:grace_period_expired, :gp_expired)

      {:ok, pid} = start_proxy(grace_period_timeout: 50)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})

      Process.sleep(100)

      assert_received {:gp_expired, _measurements, metadata}
      assert metadata.node == @test_node
      assert run_id in metadata.orphaned_runs

      detach_all([h])
      GenServer.stop(pid, :normal)
    end

    test "emits run_orphaned for each in-flight run on expiry" do
      h = attach_telemetry(:run_orphaned, :orphaned)

      {:ok, pid} = start_proxy(grace_period_timeout: 50)

      assert {:ok, r1} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert {:ok, r2} = RemoteNodeProxy.dispatch(pid, :watchdog, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})

      Process.sleep(100)

      # Should receive two orphaned events
      orphaned_ids =
        receive_all_orphaned()

      assert r1 in orphaned_ids
      assert r2 in orphaned_ids

      detach_all([h])
      GenServer.stop(pid, :normal)
    end

    test "does not emit grace_period_cancelled when not in grace period" do
      h = attach_telemetry(:grace_period_cancelled, :gp_cancelled)

      {:ok, handshake_agent} = Agent.start_link(fn -> {:ok, mock_caps()} end)
      handshake_fn = fn _node, _timeout -> Agent.get(handshake_agent, & &1) end

      {:ok, pid} = start_proxy(handshake_fn: handshake_fn)

      # nodeup without prior grace period
      send(pid, {:nodeup, @test_node})
      RemoteNodeProxy.status(pid)

      refute_received {:gp_cancelled, _, _}

      detach_all([h])
      Agent.stop(handshake_agent)
      GenServer.stop(pid, :normal)
    end
  end

  # ── Configurable Timeout ────────────────────────────────────────────────

  describe "configurable grace period timeout" do
    test "uses provided timeout value" do
      h = attach_telemetry(:grace_period_started, :gp_started)

      {:ok, pid} = start_proxy(grace_period_timeout: 500)

      send(pid, {:nodedown, @test_node})
      RemoteNodeProxy.status(pid)

      assert_received {:gp_started, _measurements, metadata}
      assert metadata.timeout_ms == 500

      detach_all([h])
      GenServer.stop(pid, :normal)
    end

    test "grace_period_timeout: 0 skips grace period" do
      {:ok, pid} = start_proxy(grace_period_timeout: 0)

      assert {:ok, _run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})
      assert %{active_runs: 1} = RemoteNodeProxy.status(pid)

      send(pid, {:nodedown, @test_node})

      # Should go straight to :disconnected with no active runs
      assert %{status: :disconnected, active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp receive_all_orphaned(acc \\ []) do
    receive do
      {:orphaned, _measurements, metadata} ->
        receive_all_orphaned([metadata.run_id | acc])
    after
      100 -> acc
    end
  end
end
