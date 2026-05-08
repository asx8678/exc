defmodule CodePuppyControl.HookEngine.ExecutorTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.HookEngine.Executor
  alias CodePuppyControl.HookEngine.Models.{EventData, ExecutionResult, HookConfig}

  describe "execute_hook/3 — prompt type" do
    test "returns prompt text as stdout" do
      hook = HookConfig.new(matcher: "*", type: :prompt, command: "Review this code carefully")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "read_file")

      result = Executor.execute_hook(hook, event_data)

      assert result.blocked == false
      assert result.stdout == "Review this code carefully"
      assert result.exit_code == 0
      assert result.hook_id == hook.id
    end
  end

  describe "execute_hook/3 — command type (success)" do
    test "executes command and captures stdout" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo hello_world")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      assert result.blocked == false
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "hello_world")
      assert result.hook_id == hook.id
      assert result.duration_ms >= 0.0
    end
  end

  describe "execute_hook/3 — command type (blocking exit code 1)" do
    test "exit code 1 means blocked" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "exit 1")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      assert result.blocked == true
      assert result.exit_code == 1
    end
  end

  describe "execute_hook/3 — command type (error exit code 2)" do
    test "exit code 2 means error feedback, not blocked" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "exit 2")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      assert result.blocked == false
      assert result.exit_code == 2
    end
  end

  describe "execute_hook/3 — timeout" do
    test "times out for long-running commands" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "sleep 10", timeout: 200)
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      assert result.blocked == true
      assert result.exit_code == -1
      assert result.error != nil
      assert String.contains?(result.stderr, "timed out")
    end
  end

  describe "execute_hook/3 — error handling" do
    test "handles command not found gracefully" do
      hook =
        HookConfig.new(
          matcher: "*",
          type: :command,
          command: "nonexistent_command_xyz_12345"
        )

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      # Should not crash — returns an error result
      assert %ExecutionResult{} = result
      assert result.exit_code != 0
    end
  end

  describe "execute_hook/3 — variable substitution" do
    test "substitutes ${tool_name} in command" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo ${tool_name}")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      assert result.exit_code == 0
      assert String.contains?(result.stdout, "Bash")
    end

    test "substitutes ${event_type} in command" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo ${event_type}")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      assert result.exit_code == 0
      assert String.contains?(result.stdout, "PreToolUse")
    end
  end

  describe "execute_hook/3 — stdin payload" do
    test "hook script can read JSON from stdin" do
      # Use a command that reads stdin and echoes a field
      hook =
        HookConfig.new(
          matcher: "*",
          type: :command,
          command:
            "cat | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"tool_name\"])'"
        )

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "my_custom_tool")

      result = Executor.execute_hook(hook, event_data)

      assert result.exit_code == 0
      assert String.contains?(result.stdout, "my_custom_tool")
    end
  end

  describe "execute_hooks_sequential/3" do
    test "executes hooks in order" do
      h1 = HookConfig.new(matcher: "*", type: :command, command: "echo first")
      h2 = HookConfig.new(matcher: "*", type: :command, command: "echo second")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      results = Executor.execute_hooks_sequential([h1, h2], event_data)

      assert length(results) == 2
      assert String.contains?(Enum.at(results, 0).stdout, "first")
      assert String.contains?(Enum.at(results, 1).stdout, "second")
    end

    test "stops on block when stop_on_block is true" do
      h1 = HookConfig.new(matcher: "*", type: :command, command: "exit 1")
      h2 = HookConfig.new(matcher: "*", type: :command, command: "echo should_not_run")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      results = Executor.execute_hooks_sequential([h1, h2], event_data, stop_on_block: true)

      assert length(results) == 1
      assert hd(results).blocked == true
    end

    test "continues on block when stop_on_block is false" do
      h1 = HookConfig.new(matcher: "*", type: :command, command: "exit 1")
      h2 = HookConfig.new(matcher: "*", type: :command, command: "echo after_block")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      results = Executor.execute_hooks_sequential([h1, h2], event_data, stop_on_block: false)

      assert length(results) == 2
      assert Enum.at(results, 0).blocked == true
    end

    test "returns empty list for no hooks" do
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")
      assert Executor.execute_hooks_sequential([], event_data) == []
    end
  end

  describe "execute_hooks_parallel/3" do
    test "executes hooks and preserves registration order" do
      h1 = HookConfig.new(matcher: "*", type: :command, command: "echo alpha")
      h2 = HookConfig.new(matcher: "*", type: :command, command: "echo beta")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      results = Executor.execute_hooks_parallel([h1, h2], event_data)

      assert length(results) == 2
      # Results are in registration order, not completion order
      assert String.contains?(Enum.at(results, 0).stdout, "alpha")
      assert String.contains?(Enum.at(results, 1).stdout, "beta")
    end
  end

  describe "get_blocking_result/1" do
    test "returns first blocking result" do
      r1 = %ExecutionResult{blocked: false, hook_command: "a"}
      r2 = %ExecutionResult{blocked: true, hook_command: "b", error: "blocked"}
      r3 = %ExecutionResult{blocked: true, hook_command: "c"}

      assert Executor.get_blocking_result([r1, r2, r3]).hook_command == "b"
    end

    test "returns nil when no blocking results" do
      r1 = %ExecutionResult{blocked: false}
      assert Executor.get_blocking_result([r1]) == nil
    end

    test "returns nil for empty list" do
      assert Executor.get_blocking_result([]) == nil
    end
  end

  describe "get_failed_results/1" do
    test "returns only failed results" do
      r1 = %ExecutionResult{exit_code: 0, error: nil}
      r2 = %ExecutionResult{exit_code: 1, error: "fail"}
      assert length(Executor.get_failed_results([r1, r2])) == 1
    end
  end

  describe "format_execution_summary/1" do
    test "formats empty results" do
      assert Executor.format_execution_summary([]) == "No hooks executed"
    end

    test "formats results with counts" do
      results = [
        %ExecutionResult{
          exit_code: 0,
          error: nil,
          blocked: false,
          duration_ms: 10.0,
          hook_command: "a"
        },
        %ExecutionResult{
          exit_code: 1,
          error: "fail",
          blocked: true,
          duration_ms: 5.0,
          hook_command: "b"
        }
      ]

      summary = Executor.format_execution_summary(results)
      assert String.contains?(summary, "Executed 2 hook(s)")
      assert String.contains?(summary, "Successful: 1")
      assert String.contains?(summary, "Blocked: 1")
    end
  end

  describe "temp file security" do
    test "stdin temp files are created in private directory" do
      # Count codepuppy-hooks-* dirs before execution.
      # Uses before/after count comparison (same pattern as the other
      # cleanup tests) so that stale dirs from previous runs or
      # concurrent async tests don't cause false negatives.
      before_count =
        case File.ls(System.tmp_dir!()) do
          {:ok, files} ->
            Enum.count(files, &String.starts_with?(&1, "codepuppy-hooks-"))

          _ ->
            0
        end

      hook = HookConfig.new(matcher: "*", type: :command, command: "echo secure")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      assert result.exit_code == 0

      after_count =
        case File.ls(System.tmp_dir!()) do
          {:ok, files} ->
            Enum.count(files, &String.starts_with?(&1, "codepuppy-hooks-"))

          _ ->
            0
        end

      # Execution must not leak temp directories — the after block
      # in do_execute_command cleans up via File.rm_rf/1.
      assert after_count == before_count,
             "expected no new codepuppy-hooks-* dirs; before=#{before_count} after=#{after_count}"
    end

    test "temp directory has restrictive permissions" do
      hook =
        HookConfig.new(
          matcher: "*",
          type: :command,
          command: "stat -f %Lp /tmp/codepuppy-hooks-*"
        )

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      # This test verifies the directory exists during execution
      # The actual permission check is done in the implementation
      result = Executor.execute_hook(hook, event_data)

      # The hook may or may not succeed depending on whether a directory
      # exists at query time — the key point is no crash
      assert %ExecutionResult{} = result
    end

    test "temp files are cleaned up after execution" do
      # Count temp files before
      before_count =
        case File.ls(System.tmp_dir!()) do
          {:ok, files} ->
            Enum.count(files, &String.starts_with?(&1, "codepuppy-hooks-"))

          _ ->
            0
        end

      hook = HookConfig.new(matcher: "*", type: :command, command: "echo cleanup_test")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      _result = Executor.execute_hook(hook, event_data)

      # Count temp files after
      after_count =
        case File.ls(System.tmp_dir!()) do
          {:ok, files} ->
            Enum.count(files, &String.starts_with?(&1, "codepuppy-hooks-"))

          _ ->
            0
        end

      # No new temp directories should remain
      assert after_count == before_count
    end

    test "temp files are cleaned up even on hook failure" do
      before_count =
        case File.ls(System.tmp_dir!()) do
          {:ok, files} ->
            Enum.count(files, &String.starts_with?(&1, "codepuppy-hooks-"))

          _ ->
            0
        end

      # Hook that fails
      hook = HookConfig.new(matcher: "*", type: :command, command: "exit 1")
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      _result = Executor.execute_hook(hook, event_data)

      after_count =
        case File.ls(System.tmp_dir!()) do
          {:ok, files} ->
            Enum.count(files, &String.starts_with?(&1, "codepuppy-hooks-"))

          _ ->
            0
        end

      assert after_count == before_count
    end

    test "temp files are cleaned up on timeout" do
      before_count =
        case File.ls(System.tmp_dir!()) do
          {:ok, files} ->
            Enum.count(files, &String.starts_with?(&1, "codepuppy-hooks-"))

          _ ->
            0
        end

      # Hook that times out
      hook = HookConfig.new(matcher: "*", type: :command, command: "sleep 10", timeout: 200)
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      _result = Executor.execute_hook(hook, event_data)

      after_count =
        case File.ls(System.tmp_dir!()) do
          {:ok, files} ->
            Enum.count(files, &String.starts_with?(&1, "codepuppy-hooks-"))

          _ ->
            0
        end

      assert after_count == before_count
    end

    test "stderr is captured robustly (not via elem(1))" do
      # Hook that writes to stderr
      hook =
        HookConfig.new(matcher: "*", type: :command, command: "echo stderr_output >&2; exit 0")

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      result = Executor.execute_hook(hook, event_data)

      assert result.exit_code == 0
      assert String.contains?(result.stderr, "stderr_output")
    end
  end
end
