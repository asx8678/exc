defmodule CodePuppyControl.ApplicationWiringTest do
  @moduledoc """
  Direct runtime coverage for application supervision wiring.

  Verifies that key processes (Workflow.State [aliased as WorkflowState], SlashCommands.Registry,
  Callbacks.Registry) are startable and reachable in application context.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Workflow.State, as: WorkflowState
  alias CodePuppyControl.CLI.SlashCommands.Registry

  describe "WorkflowState supervision wiring" do
    test "WorkflowState can be started under a supervisor" do
      # Simulate the Application child_spec entry
      case start_supervised({WorkflowState, name: WorkflowState}) do
        {:ok, pid} ->
          assert is_pid(pid)
          assert Process.whereis(WorkflowState) == pid

        {:error, {:already_started, pid}} ->
          # Already started by a prior test — still proves it's startable
          assert is_pid(pid)
          assert Process.whereis(WorkflowState) == pid
      end
    end

    test "WorkflowState is functional after supervised start" do
      start_supervised({WorkflowState, name: WorkflowState})
      WorkflowState.reset()

      WorkflowState.set_flag(:did_generate_code)
      assert WorkflowState.has_flag?(:did_generate_code)

      WorkflowState.reset()
      refute WorkflowState.has_flag?(:did_generate_code)
    end
  end

  describe "SlashCommands.Registry + builtin wiring" do
    setup do
      case Process.whereis(Registry) do
        nil -> start_supervised!({Registry, []})
        _pid -> :ok
      end

      Registry.clear()
      :ok
    end

    test "register_builtin_commands/0 makes /flags dispatchable" do
      :ok = Registry.register_builtin_commands()

      assert {:ok, cmd} = Registry.get("flags")
      assert cmd.name == "flags"
    end

    test "/flags handler is invocable after registration" do
      # Start WorkflowState for the handler
      case Process.whereis(WorkflowState) do
        nil -> start_supervised!({WorkflowState, name: WorkflowState})
        _pid -> :ok
      end

      WorkflowState.reset()
      :ok = Registry.register_builtin_commands()

      {:ok, cmd} = Registry.get("flags")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = cmd.handler.("/flags", %{})
        end)

      assert output =~ "Workflow State"
    end
  end

  describe "Callbacks.Registry supervision wiring (regression code_puppy-mmk.6)" do
    # Regression: Callbacks.Registry was not added to the application supervision
    # tree, so callbacks could not be triggered without manually starting the
    # registry. This test verifies that under normal app supervision (without
    # manual start), callback checks work.

    test "Callbacks.Registry is supervised and callback registration works" do
      # The registry should already be started by the application supervisor
      pid = Process.whereis(CodePuppyControl.Callbacks.Registry)
      assert pid != nil, "Callbacks.Registry should be supervised by the application"
      assert is_pid(pid)

      # Verify we can register and trigger without any manual start
      test_cb = fn -> :test_result end
      CodePuppyControl.Callbacks.register(:startup, test_cb)

      try do
        result = CodePuppyControl.Callbacks.trigger(:startup)
        # :startup uses :noop merge, so result may be a list of all
        # callback returns or a single value depending on how many are
        # registered. We just verify our callback's return is in the results.
        results = List.wrap(result)
        assert :test_result in results
      after
        CodePuppyControl.Callbacks.unregister(:startup, test_cb)
      end
    end

    test "security callback check works without manual registry start" do
      # This specifically exercises the code path where Security.check/2
      # triggers the run_shell_command callback via the supervised registry.
      # If the registry is not supervised, this would crash.
      result =
        CodePuppyControl.Tools.CommandRunner.Security.check("echo supervision_test")

      # Must return a proper map (not crash)
      assert is_map(result)
      assert Map.has_key?(result, :allowed)
    end
  end

  describe "WorkflowState callback registration wiring (code-puppy-ctj.3)" do
    test "workflow-state callbacks are auto-registered on startup" do
      # The Application.start/2 callback calls
      # WorkflowState.register_callback_handlers() after the
      # Callbacks.Registry is started. This test verifies the
      # handlers are present in the live registry.
      CodePuppyControl.Callbacks.clear(:pre_tool_call)
      CodePuppyControl.Callbacks.clear(:run_shell_command)
      CodePuppyControl.Callbacks.clear(:agent_run_start)
      CodePuppyControl.Callbacks.clear(:agent_run_end)
      CodePuppyControl.Callbacks.clear(:delete_file)

      # Simulate the application startup wiring
      CodePuppyControl.Workflow.State.register_callback_handlers()

      # Verify handlers are registered for key hooks
      assert CodePuppyControl.Callbacks.count_callbacks(:pre_tool_call) >= 1
      assert CodePuppyControl.Callbacks.count_callbacks(:run_shell_command) >= 1
      assert CodePuppyControl.Callbacks.count_callbacks(:agent_run_start) >= 1
      assert CodePuppyControl.Callbacks.count_callbacks(:agent_run_end) >= 1
      assert CodePuppyControl.Callbacks.count_callbacks(:delete_file) >= 1

      # Verify the run_shell_command callback has the correct arity
      # (hook declares arity 3: context, command, cwd)
      callbacks = CodePuppyControl.Callbacks.get_callbacks(:run_shell_command)

      Enum.each(callbacks, fn cb ->
        {:arity, arity} = Function.info(cb, :arity)
        assert arity == 3, "run_shell_command callback must be arity 3, got #{arity}"
      end)

      # Verify end-to-end: triggering run_shell_command sets workflow flag
      CodePuppyControl.Workflow.State.clear_run_key()
      CodePuppyControl.Workflow.State.reset()

      # Add policy to allow the command
      CodePuppyControl.PolicyEngine.add_rule(%CodePuppyControl.PolicyEngine.PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        source: "wiring-test"
      })

      result =
        CodePuppyControl.Callbacks.RunShellCommand.check("pytest run", cwd: "/tmp")

      assert result.allowed == true
      assert CodePuppyControl.Workflow.State.has_flag?(:did_execute_shell)
      assert CodePuppyControl.Workflow.State.has_flag?(:did_run_tests)

      CodePuppyControl.PolicyEngine.remove_rules_by_source("wiring-test")
      CodePuppyControl.Workflow.State.unregister_callback_handlers()
    end
  end
end
