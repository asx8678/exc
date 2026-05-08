defmodule CodePuppyControl.HookEngine.ModelsTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.HookEngine.Models
  alias Models.{HookConfig, EventData, ExecutionResult, HookRegistry, ProcessEventResult}

  describe "HookConfig.new/1" do
    test "creates a valid hook config with auto-generated ID" do
      hook = HookConfig.new(matcher: "Bash", type: :command, command: "echo hello")
      assert hook.matcher == "Bash"
      assert hook.type == :command
      assert hook.command == "echo hello"
      assert hook.timeout == 5000
      assert hook.once == false
      assert hook.enabled == true
      assert is_binary(hook.id) and hook.id != ""
    end

    test "uses provided ID when given" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "test", id: "my-id")
      assert hook.id == "my-id"
    end

    test "raises on empty matcher" do
      assert_raise ArgumentError, ~r/matcher cannot be empty/, fn ->
        HookConfig.new(matcher: "", type: :command, command: "test")
      end
    end

    test "raises on invalid type" do
      assert_raise ArgumentError, ~r/must be :command or :prompt/, fn ->
        HookConfig.new(matcher: "*", type: :invalid, command: "test")
      end
    end

    test "raises on empty command" do
      assert_raise ArgumentError, ~r/command cannot be empty/, fn ->
        HookConfig.new(matcher: "*", type: :command, command: "")
      end
    end

    test "raises on timeout below 100ms" do
      assert_raise ArgumentError, ~r/timeout must be >= 100ms/, fn ->
        HookConfig.new(matcher: "*", type: :command, command: "test", timeout: 50)
      end
    end

    test "generates deterministic IDs for same content" do
      h1 = HookConfig.new(matcher: "Bash", type: :command, command: "echo")
      h2 = HookConfig.new(matcher: "Bash", type: :command, command: "echo")
      assert h1.id == h2.id
    end

    test "generates different IDs for different content" do
      h1 = HookConfig.new(matcher: "Bash", type: :command, command: "echo")
      h2 = HookConfig.new(matcher: "Read", type: :command, command: "echo")
      refute h1.id == h2.id
    end
  end

  describe "EventData.new/1" do
    test "creates a valid event data" do
      ed = EventData.new(event_type: "PreToolUse", tool_name: "Bash")
      assert ed.event_type == "PreToolUse"
      assert ed.tool_name == "Bash"
      assert ed.tool_args == %{}
      assert ed.context == %{}
    end

    test "raises on empty event type" do
      assert_raise ArgumentError, ~r/Event type cannot be empty/, fn ->
        EventData.new(event_type: "", tool_name: "Bash")
      end
    end

    test "raises on empty tool name" do
      assert_raise ArgumentError, ~r/Tool name cannot be empty/, fn ->
        EventData.new(event_type: "PreToolUse", tool_name: "")
      end
    end
  end

  describe "ExecutionResult" do
    test "success? returns true for exit_code 0 and no error" do
      result = %ExecutionResult{exit_code: 0, error: nil}
      assert ExecutionResult.success?(result) == true
    end

    test "success? returns false for non-zero exit code" do
      result = %ExecutionResult{exit_code: 1, error: nil}
      assert ExecutionResult.success?(result) == false
    end

    test "success? returns false for error message" do
      result = %ExecutionResult{exit_code: 0, error: "something broke"}
      assert ExecutionResult.success?(result) == false
    end

    test "output combines stdout and stderr" do
      result = %ExecutionResult{stdout: "hello", stderr: "world"}
      assert ExecutionResult.output(result) == "hello\nworld"
    end

    test "output skips empty streams" do
      result = %ExecutionResult{stdout: "", stderr: "world"}
      assert ExecutionResult.output(result) == "world"
    end
  end

  describe "Models.normalize_event_type/1" do
    test "converts camelCase to snake_case" do
      assert Models.normalize_event_type("PreToolUse") == "pre_tool_use"
      assert Models.normalize_event_type("PostToolUse") == "post_tool_use"
      assert Models.normalize_event_type("UserPromptSubmit") == "user_prompt_submit"
    end
  end

  describe "Models.supported_event_types/0" do
    test "returns all expected event types" do
      types = Models.supported_event_types()
      assert "PreToolUse" in types
      assert "PostToolUse" in types
      assert "SessionStart" in types
      assert "SessionEnd" in types
      assert "SubagentStop" in types
    end
  end

  describe "HookRegistry" do
    test "default struct has empty entries and sets" do
      reg = %HookRegistry{}
      assert reg.entries == %{}
      assert reg.executed_once == MapSet.new()
      assert reg.registered_ids == MapSet.new()
    end
  end

  describe "ProcessEventResult" do
    test "all_successful? returns true when all results succeed" do
      r1 = %ExecutionResult{exit_code: 0, error: nil}
      r2 = %ExecutionResult{exit_code: 0, error: nil}
      per = %ProcessEventResult{results: [r1, r2]}
      assert ProcessEventResult.all_successful?(per) == true
    end

    test "all_successful? returns false when any result fails" do
      r1 = %ExecutionResult{exit_code: 0, error: nil}
      r2 = %ExecutionResult{exit_code: 1, error: "fail"}
      per = %ProcessEventResult{results: [r1, r2]}
      assert ProcessEventResult.all_successful?(per) == false
    end

    test "failed_hooks returns only unsuccessful results" do
      r1 = %ExecutionResult{exit_code: 0, error: nil}
      r2 = %ExecutionResult{exit_code: 1, error: "fail"}
      per = %ProcessEventResult{results: [r1, r2]}
      assert ProcessEventResult.failed_hooks(per) == [r2]
    end
  end
end
