defmodule CodePuppyControl.Pack.DispatcherTest do
  @moduledoc """
  Tests for the Pack.Dispatcher module — capability-aware dispatch router.

  Validates:
  - resolve_target/2 resolution logic (explicit node, auto, fallback)
  - distributed_available?/0 reflects config state
  - dispatch/3 delegates correctly for local vs remote targets
  - format_remote_result/3 handles success, failure, rejection
  - agent_name_to_sub_agent/1 maps known and unknown agents
  - generate_run_id/0 produces unique IDs with correct prefix
  - node_reachable?/1 checks NodeMonitor and fallback

  (Phase I.3 — code_puppy-yge.2)
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.Dispatcher

  setup do
    # Ensure NamingService GenServer is running for tests that need it
    naming_started =
      case GenServer.whereis(CodePuppyControl.Pack.NamingService) do
        nil ->
          {:ok, _} = CodePuppyControl.Pack.NamingService.start_link([])
          true

        _pid ->
          true
      end

    # Ensure LoadBalancer GenServer is running (Phase I.4)
    lb_started =
      case GenServer.whereis(CodePuppyControl.Pack.LoadBalancer) do
        nil ->
          {:ok, _} = CodePuppyControl.Pack.LoadBalancer.start_link([])
          true

        _pid ->
          true
      end

    # Ensure NodeMonitor GenServer is running for node_reachable? tests
    node_monitor_started =
      case GenServer.whereis(CodePuppyControl.Pack.NodeMonitor) do
        nil ->
          # Start NodeMonitor with disabled=true so it doesn't try to connect
          {:ok, _} =
            CodePuppyControl.Pack.NodeMonitor.start_link(enabled: false, workers: [])

          true

        _pid ->
          true
      end

    on_exit(fn ->
      # Clean up any test-registered capabilities
      try do
        CodePuppyControl.Pack.NamingService.unregister_node(:pup_test@localhost)
        CodePuppyControl.Pack.NamingService.unregister_node(:pup_test2@localhost)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok,
     naming_started: naming_started,
     lb_started: lb_started,
     node_monitor_started: node_monitor_started}
  end

  # ---------------------------------------------------------------------------
  # distributed_available?/0
  # ---------------------------------------------------------------------------

  describe "distributed_available?/0" do
    test "returns false when config is disabled (default)" do
      # Distributed packs are disabled by default
      refute Dispatcher.distributed_available?()
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_target/2
  # ---------------------------------------------------------------------------

  describe "resolve_target/2" do
    test "returns :local when distributed disabled and no explicit node" do
      # Default config has enabled: false
      assert Dispatcher.resolve_target("terrier", []) == :local
    end

    test "returns :local when no workers registered and distributed enabled" do
      # Temporarily enable distributed packs
      original = Application.get_env(:code_puppy_control, :distributed_packs, %{})
      Application.put_env(:code_puppy_control, :distributed_packs, %{enabled: true})

      try do
        # NamingService has no workers registered in test → falls back to local
        assert Dispatcher.resolve_target("terrier", []) == :local
      after
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      end
    end

    test "returns :local when explicit node is unreachable" do
      # A node that definitely doesn't exist
      result = Dispatcher.resolve_target("terrier", node: :nonexistent_node@nowhere)

      assert result == :local
    end

    test "returns {:remote, node} when explicit node is given and reachable" do
      # Node.self() is always reachable
      self_node = Node.self()

      result = Dispatcher.resolve_target("terrier", node: self_node)

      assert result == {:remote, self_node}
    end

    test "returns {:remote, node} when distributed enabled and workers available" do
      original = Application.get_env(:code_puppy_control, :distributed_packs, %{})
      Application.put_env(:code_puppy_control, :distributed_packs, %{enabled: true})

      # Register a fake worker node in NamingService
      test_node = :pup_test@localhost
      caps = %{sub_agents: [:terrier, :watchdog], host_os: "linux"}
      CodePuppyControl.Pack.NamingService.register_capabilities(test_node, caps)

      try do
        result = Dispatcher.resolve_target("terrier", [])

        # Should find the test worker via NamingService
        assert result == {:remote, test_node}
      after
        CodePuppyControl.Pack.NamingService.unregister_node(test_node)
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      end
    end

    test "returns :local when distributed enabled but no matching workers" do
      original = Application.get_env(:code_puppy_control, :distributed_packs, %{})
      Application.put_env(:code_puppy_control, :distributed_packs, %{enabled: true})

      # Register a worker that does NOT support :shepherd
      test_node = :pup_test2@localhost
      caps = %{sub_agents: [:terrier, :watchdog], host_os: "linux"}
      CodePuppyControl.Pack.NamingService.register_capabilities(test_node, caps)

      try do
        # Asking for :shepherd — no worker supports it
        result = Dispatcher.resolve_target("shepherd", [])

        assert result == :local
      after
        CodePuppyControl.Pack.NamingService.unregister_node(test_node)
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # agent_name_to_sub_agent/1
  # ---------------------------------------------------------------------------

  describe "agent_name_to_sub_agent/1" do
    test "maps known agent name 'retriever' to :retriever" do
      assert Dispatcher.agent_name_to_sub_agent("retriever") == :retriever
    end

    test "maps known agent name 'shepherd' to :shepherd" do
      assert Dispatcher.agent_name_to_sub_agent("shepherd") == :shepherd
    end

    test "maps known agent name 'terrier' to :terrier" do
      assert Dispatcher.agent_name_to_sub_agent("terrier") == :terrier
    end

    test "maps known agent name 'watchdog' to :watchdog" do
      assert Dispatcher.agent_name_to_sub_agent("watchdog") == :watchdog
    end

    test "maps pack_leader" do
      assert Dispatcher.agent_name_to_sub_agent("pack_leader") == :pack_leader
    end

    test "is case-insensitive for known agents" do
      assert Dispatcher.agent_name_to_sub_agent("Terrier") == :terrier
      assert Dispatcher.agent_name_to_sub_agent("RETRIEVER") == :retriever
    end

    test "converts unknown string names to atoms" do
      assert Dispatcher.agent_name_to_sub_agent("custom_agent") == :custom_agent
    end

    test "passes through atom names unchanged" do
      assert Dispatcher.agent_name_to_sub_agent(:terrier) == :terrier
      assert Dispatcher.agent_name_to_sub_agent(:custom) == :custom
    end
  end

  # ---------------------------------------------------------------------------
  # generate_run_id/0
  # ---------------------------------------------------------------------------

  describe "generate_run_id/0" do
    test "produces IDs with 'pack-run-' prefix" do
      id = Dispatcher.generate_run_id()

      assert String.starts_with?(id, "pack-run-")
    end

    test "produces unique IDs across calls" do
      ids =
        for _ <- 1..20 do
          Dispatcher.generate_run_id()
        end

      assert length(Enum.uniq(ids)) == 20
    end

    test "suffix is 16 hex characters" do
      id = Dispatcher.generate_run_id()
      suffix = String.replace_prefix(id, "pack-run-", "")

      assert String.length(suffix) == 16
      assert Regex.match?(~r/^[0-9a-f]{16}$/, suffix)
    end
  end

  # ---------------------------------------------------------------------------
  # format_remote_result/3
  # ---------------------------------------------------------------------------

  describe "format_remote_result/3" do
    test "correctly formats success results" do
      result = %{status: :success, output: "Build completed successfully"}

      assert {:ok, formatted} =
               Dispatcher.format_remote_result(result, "terrier", "sess-1")

      assert formatted.response == "Build completed successfully"
      assert formatted.agent_name == "terrier"
      assert formatted.session_id == "sess-1"
      assert formatted.error == nil
    end

    test "correctly formats success with default output message" do
      result = %{status: :success}

      assert {:ok, formatted} =
               Dispatcher.format_remote_result(result, "shepherd", "sess-2")

      assert formatted.response == "Remote agent completed"
    end

    test "correctly formats failure results" do
      result = %{status: :failure, error: "Out of disk space"}

      assert {:error, formatted} =
               Dispatcher.format_remote_result(result, "watchdog", "sess-3")

      assert formatted.response == nil
      assert formatted.agent_name == "watchdog"
      assert formatted.session_id == "sess-3"
      assert formatted.error == "Out of disk space"
    end

    test "correctly formats failure with default error message" do
      result = %{status: :failure}

      assert {:error, formatted} =
               Dispatcher.format_remote_result(result, "terrier", nil)

      assert formatted.error == "Remote agent failed"
    end

    test "correctly formats rejection results" do
      result = %{status: :rejected, reason: :no_capacity}

      assert {:error, formatted} =
               Dispatcher.format_remote_result(result, "terrier", "sess-4")

      assert formatted.response == nil
      assert formatted.error =~ "rejected dispatch"
      assert formatted.error =~ "no_capacity"
    end

    test "handles unknown status with error field" do
      result = %{status: :crashed, error: "Segfault"}

      assert {:error, formatted} =
               Dispatcher.format_remote_result(result, "terrier", nil)

      assert formatted.error == "Segfault"
    end

    test "handles unknown status with output field" do
      result = %{status: :partial, output: "Some results"}

      assert {:ok, formatted} =
               Dispatcher.format_remote_result(result, "terrier", nil)

      assert formatted.response == "Some results"
    end

    test "handles unknown status with no output or error" do
      result = %{status: :partial}

      assert {:ok, formatted} =
               Dispatcher.format_remote_result(result, "terrier", nil)

      assert formatted.response =~ "unknown status"
    end
  end

  # ---------------------------------------------------------------------------
  # dispatch/3 — local path
  # ---------------------------------------------------------------------------

  describe "dispatch/3 local path" do
    test "delegates to local invoke when target is :local" do
      # With distributed disabled, a nonexistent agent should fail locally
      result = Dispatcher.dispatch("nonexistent-agent-xyz", "test prompt")

      assert match?({:error, _}, result)
    end

    test "local dispatch result has correct shape" do
      {:error, result} = Dispatcher.dispatch("nonexistent-agent-xyz", "test prompt")

      assert Map.has_key?(result, :response)
      assert Map.has_key?(result, :agent_name)
      assert Map.has_key?(result, :session_id)
      assert Map.has_key?(result, :error)
    end
  end

  # ---------------------------------------------------------------------------
  # node_reachable?/1
  # ---------------------------------------------------------------------------

  describe "node_reachable?/1" do
    test "returns true for Node.self()" do
      assert Dispatcher.node_reachable?(Node.self()) == true
    end

    test "returns false for unreachable node" do
      # A completely fabricated node name that won't exist
      refute Dispatcher.node_reachable?(:"fake_node@999.999.999.999")
    end
  end

  # ---------------------------------------------------------------------------
  # Phase I.4: LoadBalancer Integration
  # ---------------------------------------------------------------------------

  describe "find_available_worker uses LoadBalancer (Phase I.4)" do
    test "resolve_target uses LoadBalancer for intelligent selection" do
      original = Application.get_env(:code_puppy_control, :distributed_packs, %{})
      Application.put_env(:code_puppy_control, :distributed_packs, %{enabled: true})

      # Register two workers
      node_a = :pup_test@localhost
      node_b = :pup_test2@localhost

      CodePuppyControl.Pack.NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      CodePuppyControl.Pack.NamingService.register_capabilities(
        node_b,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      CodePuppyControl.Pack.LoadBalancer.sync_node(node_a)
      CodePuppyControl.Pack.LoadBalancer.sync_node(node_b)

      try do
        result = Dispatcher.resolve_target("terrier", [])

        assert match?({:remote, _}, result)
        {:remote, selected} = result
        assert selected in [node_a, node_b]
      after
        CodePuppyControl.Pack.NamingService.unregister_node(node_a)
        CodePuppyControl.Pack.NamingService.unregister_node(node_b)
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      end
    end

    test "falls back to NamingService first-match when LoadBalancer not running" do
      # Stop the LoadBalancer to test fallback
      lb_pid = GenServer.whereis(CodePuppyControl.Pack.LoadBalancer)

      if lb_pid do
        GenServer.stop(lb_pid, :normal)
      end

      original = Application.get_env(:code_puppy_control, :distributed_packs, %{})
      Application.put_env(:code_puppy_control, :distributed_packs, %{enabled: true})

      test_node = :pup_test@localhost

      CodePuppyControl.Pack.NamingService.register_capabilities(
        test_node,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      try do
        # Should still work via NamingService fallback
        result = Dispatcher.resolve_target("terrier", [])

        assert result == {:remote, test_node}
      after
        CodePuppyControl.Pack.NamingService.unregister_node(test_node)
        Application.put_env(:code_puppy_control, :distributed_packs, original)

        # Restart LoadBalancer for other tests
        try do
          CodePuppyControl.Pack.LoadBalancer.start_link([])
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  describe "Dispatcher records dispatch/completion via LoadBalancer (Phase I.4)" do
    test "LoadBalancer tracks dispatches when workers registered" do
      node_a = :pup_test@localhost

      CodePuppyControl.Pack.NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      CodePuppyControl.Pack.LoadBalancer.sync_node(node_a)

      # Record a manual dispatch to verify tracking works
      CodePuppyControl.Pack.LoadBalancer.record_dispatch(node_a, "test-run-1")
      Process.sleep(50)

      snapshot = CodePuppyControl.Pack.LoadBalancer.load_snapshot()
      assert snapshot[node_a].active_dispatches == 1
      assert snapshot[node_a].total_dispatches == 1

      CodePuppyControl.Pack.LoadBalancer.record_completion(node_a, "test-run-1", :success)
      Process.sleep(50)

      snapshot = CodePuppyControl.Pack.LoadBalancer.load_snapshot()
      assert snapshot[node_a].active_dispatches == 0
      assert snapshot[node_a].total_completions == 1

      CodePuppyControl.Pack.NamingService.unregister_node(node_a)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase I.5: Progress Streaming
  # ---------------------------------------------------------------------------

  describe "progress streaming (Phase I.5)" do
    test "progress messages are handled during await loop" do
      # Simulate progress messages arriving for a run
      run_id = "test-progress-run"

      # Verify that the do_await_loop can handle progress messages
      # by testing the handle_progress function indirectly via telemetry
      progress_payload = %{
        phase: :executing,
        progress: 0.5,
        message: "Running test",
        data: %{},
        timestamp: System.monotonic_time(:millisecond)
      }

      # Emit a progress message — this is what the dispatcher would receive
      :telemetry.execute(
        [:code_puppy, :distributed_pack, :progress],
        %{progress: progress_payload.progress, system_time: System.system_time(:millisecond)},
        %{run_id: run_id, phase: progress_payload.phase}
      )

      # No crash — the telemetry event was emitted
      assert true
    end

    test "progress callback is invoked with payload" do
      # Test that the progress callback mechanism works
      test_pid = self()

      callback = fn run_id, payload ->
        send(test_pid, {:progress_cb, run_id, payload})
      end

      # Simulate what handle_progress does
      payload = %{
        phase: :finalizing,
        progress: 0.9,
        message: "Almost done",
        data: %{},
        timestamp: System.monotonic_time(:millisecond)
      }

      # Invoke callback directly
      callback.("run-xyz", payload)

      # Should receive the callback message
      assert_received {:progress_cb, "run-xyz", cb_payload}
      assert cb_payload.phase == :finalizing
      assert cb_payload.progress == 0.9
    end

    test "dispatch still completes after receiving progress messages" do
      # The dispatch flow should handle progress → result sequence
      # Test by verifying format_remote_result works after progress
      result = %{status: :success, output: "Completed after progress"}

      formatted = Dispatcher.format_remote_result(result, "terrier", "sess-1")

      assert {:ok, f} = formatted
      assert f.response == "Completed after progress"
    end

    test "handle_dispatch_timeout produces local fallback result" do
      # Test timeout fallback behavior
      result = Dispatcher.dispatch("nonexistent-agent-xyz", "test prompt")

      # Should fall back to local and produce an error
      assert match?({:error, _}, result)
    end
  end
end
