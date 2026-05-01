defmodule CodePuppyControl.Pack.WorkerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.Worker

  describe "start_link/1" do
    test "initializes with default capabilities" do
      {:ok, pid} = Worker.start_link(name: :worker_test_default, host_os: :linux)
      capabilities = GenServer.call(pid, :request_capabilities)

      assert capabilities.node_name == Node.self()
      # Sub-agents come from Capabilities.detect fallback (AgentCatalogue not running)
      assert :terrier in capabilities.sub_agents
      assert :watchdog in capabilities.sub_agents
      assert :shepherd in capabilities.sub_agents
      assert :retriever in capabilities.sub_agents
      # host_os is now a string (Capabilities normalizes atoms to strings)
      assert capabilities.host_os == "linux"
      # available_models may be auto-discovered from ModelRegistry
      assert is_list(capabilities.available_models)
      assert capabilities.max_concurrent_runs in 1..4
      assert capabilities.features.file_ops == true
      assert capabilities.features.shell_access == true
      assert capabilities.features.git_access == true
      # New fields from Capabilities.detect
      assert is_binary(capabilities.beam_version)
      assert %DateTime{} = capabilities.started_at
    end

    test "initializes with custom max_concurrent_runs" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_custom_limit,
          host_os: :linux,
          max_concurrent_runs: 4
        )

      capabilities = GenServer.call(pid, :request_capabilities)
      assert capabilities.max_concurrent_runs == 4
    end

    test "detects host OS automatically" do
      {:ok, pid} = Worker.start_link(name: :worker_test_os_detect)

      capabilities = GenServer.call(pid, :request_capabilities)

      assert capabilities.host_os in ["linux", "darwin", "windows", "macos"]
    end
  end

  describe ":request_capabilities" do
    test "returns the capabilities map" do
      {:ok, pid} = Worker.start_link(name: :worker_test_caps, host_os: :macos)
      capabilities = GenServer.call(pid, :request_capabilities)

      assert is_map(capabilities)
      assert capabilities.node_name == Node.self()
      assert capabilities.host_os == "macos"
      assert Map.has_key?(capabilities, :features)
      assert Map.has_key?(capabilities.features, :file_ops)
    end
  end

  describe ":ping" do
    test "returns :pong" do
      {:ok, pid} = Worker.start_link(name: :worker_test_ping, host_os: :linux)
      assert :pong == GenServer.call(pid, :ping)
    end
  end

  defp dispatch_map(run_id, sub_agent, params, leader_node, leader_pid) do
    %{
      run_id: run_id,
      sub_agent: sub_agent,
      params: params,
      leader_node: leader_node,
      leader_pid: leader_pid
    }
  end

  describe "dispatch validation" do
    test "rejects dispatch with missing run_id" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_dispatch_no_run_id,
          host_os: :linux,
          max_concurrent_runs: 5
        )

      test_pid = self()

      # Dispatch message missing run_id
      malformed = %{
        sub_agent: :terrier,
        params: %{task_description: "test"},
        leader_node: node(),
        leader_pid: test_pid
      }

      GenServer.cast(pid, {:dispatch, malformed})

      # Sync: wait for cast to be processed
      _ = :sys.get_state(pid)

      assert_receive {:"$gen_cast", {:result, "unknown", result}}, 500
      assert result.status == :failure
      assert String.contains?(result.error, "malformed_dispatch")
    end

    test "rejects non-map dispatch messages" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_dispatch_non_map,
          host_os: :linux
        )

      # Should not crash — catch-all handles non-map
      GenServer.cast(pid, {:dispatch, "not a map"})

      _ = :sys.get_state(pid)
      assert :pong == GenServer.call(pid, :ping)
    end

    test "rejects duplicate run_id dispatch" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_dispatch_duplicate,
          host_os: :linux,
          max_concurrent_runs: 5
        )

      test_pid = self()

      # First dispatch should succeed
      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map("run-dup", :terrier, %{task_description: "test"}, node(), test_pid)}
      )

      _ = :sys.get_state(pid)

      # Second dispatch with same run_id should be rejected
      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map("run-dup", :terrier, %{task_description: "test2"}, node(), test_pid)}
      )

      _ = :sys.get_state(pid)

      assert_receive {:"$gen_cast", {:result, "run-dup", result}}, 500
      assert result.status == :failure
      assert String.contains?(result.error, "duplicate_run_id")
    end

    test "rejects unknown sub_agent types" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_dispatch_unknown,
          host_os: :linux,
          max_concurrent_runs: 5
        )

      test_pid = self()

      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map("run-1", :nonexistent_agent, %{task_description: "test"}, node(), test_pid)}
      )

      # Sync: wait for cast to be processed
      _ = :sys.get_state(pid)

      # The rejection should be sent to the leader_pid (test_pid) via GenServer.cast
      # GenServer.cast wraps the message in {:"$gen_cast", msg}
      assert_receive {:"$gen_cast", {:result, "run-1", result}}, 500
      assert result.status == :failure
      assert String.contains?(result.error, "unsupported_sub_agent")
    end

    test "rejects unavailable models" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_dispatch_model,
          host_os: :linux,
          available_models: []
        )

      test_pid = self()

      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map(
           "run-2",
           :terrier,
           %{
             task_description: "test",
             model_preference: "claude-sonnet-4-20250514"
           },
           node(),
           test_pid
         )}
      )

      # Sync: wait for cast to be processed
      _ = :sys.get_state(pid)

      assert_receive {:"$gen_cast", {:result, "run-2", result}}, 500
      assert result.status == :failure
      assert String.contains?(result.error, "unavailable_model")
    end

    test "accepts valid dispatch with nil model_preference" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_dispatch_accept,
          host_os: :linux,
          max_concurrent_runs: 5
        )

      test_pid = self()

      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map(
           "run-3",
           :terrier,
           %{task_description: "test", model_preference: nil},
           node(),
           test_pid
         )}
      )

      # Sync: wait for cast to be processed
      _ = :sys.get_state(pid)

      # No rejection should be sent
      refute_receive {:"$gen_cast", {:result, "run-3", _result}}, 200
    end

    test "rejects dispatch when max concurrent runs exceeded" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_dispatch_overflow,
          host_os: :linux,
          max_concurrent_runs: 1
        )

      test_pid = self()

      # Fill the single slot
      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map(
           "run-4",
           :terrier,
           %{task_description: "test", model_preference: nil},
           node(),
           test_pid
         )}
      )

      # Sync: wait for first dispatch to be processed
      _ = :sys.get_state(pid)

      # Try to dispatch another
      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map(
           "run-5",
           :terrier,
           %{task_description: "test", model_preference: nil},
           node(),
           test_pid
         )}
      )

      # Sync: wait for second dispatch to be processed
      _ = :sys.get_state(pid)

      assert_receive {:"$gen_cast", {:result, "run-5", result}}, 500
      assert result.status == :failure
      assert String.contains?(result.error, "max_concurrent_runs_exceeded")
    end
  end

  describe "cancel" do
    test "cancels an active run" do
      {:ok, pid} =
        Worker.start_link(name: :worker_test_cancel, host_os: :linux, max_concurrent_runs: 5)

      test_pid = self()

      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map(
           "run-6",
           :terrier,
           %{task_description: "test", model_preference: nil},
           node(),
           test_pid
         )}
      )

      # Sync: wait for dispatch to be processed
      _ = :sys.get_state(pid)

      GenServer.cast(pid, {:cancel, "run-6"})

      # Sync: wait for cancel to be processed
      _ = :sys.get_state(pid)

      assert :pong == GenServer.call(pid, :ping)
    end

    test "handles cancel for unknown run gracefully" do
      {:ok, pid} = Worker.start_link(name: :worker_test_cancel_unknown, host_os: :linux)
      # Should not crash
      GenServer.cast(pid, {:cancel, "nonexistent_run"})
      _ = :sys.get_state(pid)
      assert :pong == GenServer.call(pid, :ping)
    end
  end

  describe "nodedown handling" do
    # NOTE: Leader monitoring is not yet wired via Node.monitor/2. The nodedown
    # handler exists but won't receive real :nodedown messages until monitoring
    # is set up (future work). These tests serve as placeholders.

    test "handles nodedown message gracefully" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_nodedown,
          host_os: :linux,
          max_concurrent_runs: 5
        )

      test_pid = self()

      # Dispatch first to set leader_node
      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map(
           "run-nd1",
           :terrier,
           %{task_description: "test", model_preference: nil},
           node(),
           test_pid
         )}
      )

      _ = :sys.get_state(pid)

      # Simulate nodedown from leader (handler exists but won't receive real
      # nodedown messages until leader monitoring is wired)
      send(pid, {:nodedown, node(), make_ref()})
      _ = :sys.get_state(pid)

      assert :pong == GenServer.call(pid, :ping)
    end

    test "does not crash on nodedown from other node" do
      {:ok, pid} =
        Worker.start_link(
          name: :worker_test_nodedown_other,
          host_os: :linux,
          max_concurrent_runs: 5
        )

      test_pid = self()

      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map(
           "run-nd2",
           :terrier,
           %{task_description: "test", model_preference: nil},
           node(),
           test_pid
         )}
      )

      _ = :sys.get_state(pid)

      # Simulate nodedown from a different node (should be ignored)
      send(pid, {:nodedown, :other_node@host, make_ref()})
      _ = :sys.get_state(pid)

      assert :pong == GenServer.call(pid, :ping)
    end
  end

  describe "NamingService registration" do
    test "worker registers with NamingService on init when available" do
      # Start NamingService so registration succeeds
      start_supervised!(CodePuppyControl.Pack.NamingService)

      {:ok, pid} =
        Worker.start_link(name: :worker_test_naming_reg, host_os: :linux)

      capabilities = GenServer.call(pid, :request_capabilities)

      # Worker should have registered itself with NamingService
      registered = CodePuppyControl.Pack.NamingService.node_capabilities(Node.self())
      assert registered != nil

      # All sub_agents must be in NamingService's supported set
      supported = MapSet.new([:terrier, :watchdog, :shepherd, :retriever])

      for agent <- capabilities.sub_agents do
        assert MapSet.member?(supported, agent),
               "sub_agent #{inspect(agent)} not in NamingService supported types"
      end

      GenServer.stop(pid)
    end
  end

  describe "run completion" do
    test "sends result back to leader_pid" do
      {:ok, pid} =
        Worker.start_link(name: :worker_test_complete, host_os: :linux, max_concurrent_runs: 5)

      test_pid = self()

      GenServer.cast(
        pid,
        {:dispatch,
         dispatch_map(
           "run-7",
           :terrier,
           %{task_description: "test", model_preference: nil},
           node(),
           test_pid
         )}
      )

      _ = :sys.get_state(pid)

      # Simulate run completion
      send(pid, {:run_completed, "run-7", %{status: :success, output: "done"}})
      _ = :sys.get_state(pid)

      assert_receive {:"$gen_cast", {:result, "run-7", result}}, 500
      assert result.status == :success
      assert result.output == "done"
    end
  end
end
