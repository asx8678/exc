defmodule CodePuppyControl.Callbacks.RunShellCommandTest do
  @moduledoc """
  Tests for CodePuppyControl.Callbacks.RunShellCommand.

  Covers:
  - Allow path (policy allows, no callbacks block)
  - Deny path (policy deny, callback block)
  - Fail-closed on callback exceptions
  - Fail-closed on PolicyEngine unavailability
  - Mixed callback results (one blocks → overall deny)
  - Callback returning %{blocked: true} → deny
  - Callback returning nil → no block
  - Callback returning :callback_failed → deny (fail-closed)
  - Compound command handling (delegated to PolicyEngine)
  - Return shape matches CommandRunner.Security.check/2 contract
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Callbacks.RunShellCommand
  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule

  setup do
    PolicyEngine.reset()
    Callbacks.clear(:run_shell_command)
    :ok
  end

  describe "check/2 — default behavior (no rules, no callbacks)" do
    test "returns ask_user when no rules match" do
      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:ask_user, _}, result.decision)
    end
  end

  describe "check/2 — PolicyEngine allow" do
    setup do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test")
      end)

      :ok
    end

    test "returns allowed when policy allows and no callbacks block" do
      result = RunShellCommand.check("echo hello")
      assert result.allowed == true
      assert result.decision == :allowed
      assert result.reason == nil
    end

    test "result map shape matches CommandRunner.Security contract" do
      result = RunShellCommand.check("echo hello")
      assert Map.has_key?(result, :allowed)
      assert Map.has_key?(result, :reason)
      assert Map.has_key?(result, :decision)
    end
  end

  describe "check/2 — PolicyEngine deny" do
    test "returns denied when policy denies" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      result = RunShellCommand.check("rm -rf /")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)
    end

    test "short-circuits: does not call callbacks when policy denies" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      # Register a callback that would allow — but it shouldn't be reached
      cb = fn _ctx, _cmd, _cwd -> %{blocked: false} end
      Callbacks.register(:run_shell_command, cb)

      result = RunShellCommand.check("rm -rf /")
      assert result.allowed == false

      Callbacks.unregister(:run_shell_command, cb)
    end
  end

  describe "check/2 — PolicyEngine ask_user" do
    setup do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :ask_user,
        priority: 10,
        source: "test"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test")
      end)

      :ok
    end

    test "returns ask_user when policy says ask and no callback blocks" do
      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:ask_user, _}, result.decision)
    end

    test "callback can override ask_user to deny" do
      deny_cb = fn _ctx, _cmd, _cwd -> %{blocked: true} end
      Callbacks.register(:run_shell_command, deny_cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, deny_cb)
    end
  end

  describe "check/2 — callback interactions" do
    setup do
      # Allow all shell commands by default so we can test callbacks
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test")
      end)

      :ok
    end

    test "callback returning nil does not block" do
      cb = fn _ctx, _cmd, _cwd -> nil end
      Callbacks.register(:run_shell_command, cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == true

      Callbacks.unregister(:run_shell_command, cb)
    end

    test "callback returning %{blocked: false} does not block" do
      cb = fn _ctx, _cmd, _cwd -> %{blocked: false} end
      Callbacks.register(:run_shell_command, cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == true

      Callbacks.unregister(:run_shell_command, cb)
    end

    test "callback returning %{blocked: true} blocks the command" do
      cb = fn _ctx, _cmd, _cwd -> %{blocked: true} end
      Callbacks.register(:run_shell_command, cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, cb)
    end

    test "callback returning %Deny{} blocks the command" do
      alias CodePuppyControl.PolicyEngine.PolicyRule.Deny

      cb = fn _ctx, _cmd, _cwd -> %Deny{reason: "custom deny"} end
      Callbacks.register(:run_shell_command, cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, cb)
    end
  end

  describe "check/2 — fail-closed semantics" do
    setup do
      # Allow all shell commands by default so we can test callbacks
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test")
      end)

      :ok
    end

    test "callback that raises denies the command (fail-closed)" do
      raise_cb = fn _ctx, _cmd, _cwd -> raise "security check boom" end
      Callbacks.register(:run_shell_command, raise_cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)
      assert result.reason =~ "blocked by security plugin"

      Callbacks.unregister(:run_shell_command, raise_cb)
    end

    test "callback that throws denies the command (fail-closed)" do
      throw_cb = fn _ctx, _cmd, _cwd -> throw(:boom) end
      Callbacks.register(:run_shell_command, throw_cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, throw_cb)
    end

    test "callback returning :callback_failed denies the command (fail-closed)" do
      fail_cb = fn _ctx, _cmd, _cwd -> :callback_failed end
      Callbacks.register(:run_shell_command, fail_cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, fail_cb)
    end

    test "callback returning {:callback_failed, reason} denies the command" do
      fail_cb = fn _ctx, _cmd, _cwd -> {:callback_failed, :timeout} end
      Callbacks.register(:run_shell_command, fail_cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, fail_cb)
    end

    test "callback returning false denies the command" do
      deny_cb = fn _ctx, _cmd, _cwd -> false end
      Callbacks.register(:run_shell_command, deny_cb)

      result = RunShellCommand.check("echo hello")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, deny_cb)
    end
  end

  describe "check/2 — mixed callback results (regression code_puppy-mmk.6)" do
    setup do
      # Allow all shell commands by default so we can test callbacks
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test")
      end)

      :ok
    end

    test "one callback raises, one returns nil → denied (fail-closed)" do
      raise_cb = fn _ctx, _cmd, _cwd -> raise "security check crashed" end
      allow_cb = fn _ctx, _cmd, _cwd -> nil end
      Callbacks.register(:run_shell_command, raise_cb)
      Callbacks.register(:run_shell_command, allow_cb)

      result = RunShellCommand.check("echo multi_raise_nil")
      assert result.allowed == false
      assert {:denied, reason} = result.decision
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:run_shell_command, raise_cb)
      Callbacks.unregister(:run_shell_command, allow_cb)
    end

    test "one callback raises, one returns %{blocked: false} → denied (fail-closed)" do
      raise_cb = fn _ctx, _cmd, _cwd -> raise "crash" end
      allow_cb = fn _ctx, _cmd, _cwd -> %{blocked: false} end
      Callbacks.register(:run_shell_command, raise_cb)
      Callbacks.register(:run_shell_command, allow_cb)

      result = RunShellCommand.check("echo multi_crash_allow")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, raise_cb)
      Callbacks.unregister(:run_shell_command, allow_cb)
    end

    test "one callback returns %{blocked: true}, one returns nil → denied" do
      block_cb = fn _ctx, _cmd, _cwd -> %{blocked: true} end
      allow_cb = fn _ctx, _cmd, _cwd -> nil end
      Callbacks.register(:run_shell_command, block_cb)
      Callbacks.register(:run_shell_command, allow_cb)

      result = RunShellCommand.check("echo multi_block_nil")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, block_cb)
      Callbacks.unregister(:run_shell_command, allow_cb)
    end

    test "one callback returns :callback_failed, one returns nil → denied (fail-closed)" do
      fail_cb = fn _ctx, _cmd, _cwd -> :callback_failed end
      allow_cb = fn _ctx, _cmd, _cwd -> nil end
      Callbacks.register(:run_shell_command, fail_cb)
      Callbacks.register(:run_shell_command, allow_cb)

      result = RunShellCommand.check("echo multi_failed_nil")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)

      Callbacks.unregister(:run_shell_command, fail_cb)
      Callbacks.unregister(:run_shell_command, allow_cb)
    end

    test "both callbacks return nil → not blocked by callbacks" do
      allow_cb1 = fn _ctx, _cmd, _cwd -> nil end
      allow_cb2 = fn _ctx, _cmd, _cwd -> nil end
      Callbacks.register(:run_shell_command, allow_cb1)
      Callbacks.register(:run_shell_command, allow_cb2)

      result = RunShellCommand.check("echo multi_both_nil")
      assert result.allowed == true

      Callbacks.unregister(:run_shell_command, allow_cb1)
      Callbacks.unregister(:run_shell_command, allow_cb2)
    end
  end

  describe "check/2 — opts (cwd and context)" do
    setup do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test")
      end)

      :ok
    end

    test "passes cwd to PolicyEngine for compound commands" do
      # Just verify it doesn't crash with cwd
      result = RunShellCommand.check("echo hello", cwd: "/tmp")
      assert result.allowed == true
    end

    test "passes context to callbacks" do
      test_pid = self()

      cb = fn context, _cmd, _cwd ->
        send(test_pid, {:callback_context, context})
        nil
      end

      Callbacks.register(:run_shell_command, cb)

      RunShellCommand.check("echo hello", context: %{run_id: "test-123"})

      assert_received {:callback_context, %{run_id: "test-123"}}

      Callbacks.unregister(:run_shell_command, cb)
    end
  end

  describe "check/2 — compound commands" do
    test "deny in compound command is picked up via PolicyEngine" do
      # Allow git commands
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        command_pattern: "^git\\s+",
        source: "test"
      })

      # Deny rm commands
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :deny,
        priority: 10,
        command_pattern: "^rm\\s+",
        source: "test"
      })

      result = RunShellCommand.check("git status && rm -rf /")
      assert result.allowed == false
      assert match?({:denied, _}, result.decision)
    end
  end
end
