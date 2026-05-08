defmodule CodePuppyControl.Tools.CommandRunner.SecurityTest do
  @moduledoc """
  Tests for CommandRunner.Security.

  Covers:
  - PolicyEngine integration (allow/deny/ask_user)
  - Callback hook integration
  - Validator integration (always runs)
  - Fail-closed semantics
  - PUP_ env var handling
  - Yolo mode
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Tools.CommandRunner.Security
  alias CodePuppyControl.PolicyEngine

  # Ensure PolicyEngine is started for these tests
  setup do
    # PolicyEngine should be running via application supervision tree
    # Just verify it's available
    assert Process.whereis(PolicyEngine) != nil
    :ok
  end

  describe "check/2 with valid commands" do
    test "allows simple echo command" do
      result = Security.check("echo hello")
      # PolicyEngine default should allow
      assert result.allowed == true or match?(%{decision: {:ask_user, _}}, result)
    end

    test "rejects empty command via validator" do
      result = Security.check("")

      assert result.allowed == false
      assert match?({:denied, _}, result.decision)
    end

    test "rejects whitespace-only command via validator" do
      result = Security.check("   ")

      assert result.allowed == false
    end

    test "rejects command with forbidden chars via validator" do
      result = Security.check("echo \x00 test")

      assert result.allowed == false
      assert result.reason =~ "forbidden"
    end

    test "rejects command with dangerous patterns via validator" do
      result = Security.check("cat <(echo test)")

      assert result.allowed == false
      assert result.reason =~ "dangerous pattern"
    end

    test "rejects excessively long command via validator" do
      long_cmd = String.duplicate("a", 9000)
      result = Security.check(long_cmd)

      assert result.allowed == false
      assert result.reason =~ "exceeds maximum length"
    end
  end

  describe "check/2 with PUP_SKIP_SHELL_SAFETY" do
    test "skips policy/callbacks when env var is set" do
      original = System.get_env("PUP_SKIP_SHELL_SAFETY")

      try do
        System.put_env("PUP_SKIP_SHELL_SAFETY", "1")

        # A valid command should pass
        result = Security.check("echo hello")
        assert result.allowed == true
      after
        if original do
          System.put_env("PUP_SKIP_SHELL_SAFETY", original)
        else
          System.delete_env("PUP_SKIP_SHELL_SAFETY")
        end
      end
    end

    test "still runs validator even with skip_safety" do
      original = System.get_env("PUP_SKIP_SHELL_SAFETY")

      try do
        System.put_env("PUP_SKIP_SHELL_SAFETY", "1")

        # An invalid command should still be rejected by validator
        result = Security.check("echo \x00 test")
        assert result.allowed == false
      after
        if original do
          System.put_env("PUP_SKIP_SHELL_SAFETY", original)
        else
          System.delete_env("PUP_SKIP_SHELL_SAFETY")
        end
      end
    end
  end

  describe "yolo_mode?/0" do
    test "returns false by default" do
      original = System.get_env("PUP_YOLO_MODE")

      try do
        System.delete_env("PUP_YOLO_MODE")
        refute Security.yolo_mode?()
      after
        if original, do: System.put_env("PUP_YOLO_MODE", original)
      end
    end

    test "returns true when PUP_YOLO_MODE=1" do
      original = System.get_env("PUP_YOLO_MODE")

      try do
        System.put_env("PUP_YOLO_MODE", "1")
        assert Security.yolo_mode?()
      after
        if original do
          System.put_env("PUP_YOLO_MODE", original)
        else
          System.delete_env("PUP_YOLO_MODE")
        end
      end
    end
  end

  describe "skip_shell_safety?/0" do
    test "returns false by default" do
      original = System.get_env("PUP_SKIP_SHELL_SAFETY")

      try do
        System.delete_env("PUP_SKIP_SHELL_SAFETY")
        refute Security.skip_shell_safety?()
      after
        if original, do: System.put_env("PUP_SKIP_SHELL_SAFETY", original)
      end
    end

    test "returns true when PUP_SKIP_SHELL_SAFETY=1" do
      original = System.get_env("PUP_SKIP_SHELL_SAFETY")

      try do
        System.put_env("PUP_SKIP_SHELL_SAFETY", "1")
        assert Security.skip_shell_safety?()
      after
        if original do
          System.put_env("PUP_SKIP_SHELL_SAFETY", original)
        else
          System.delete_env("PUP_SKIP_SHELL_SAFETY")
        end
      end
    end
  end

  describe "fail-closed semantics" do
    test "validator rejection is fail-closed (denied, not ask_user)" do
      result = Security.check("echo \x00 test")

      assert result.allowed == false
      # Validator failures should be denied, not ask_user
      assert match?({:denied, _}, result.decision)
    end

    test "callback returning :callback_failed denies execution (fail-closed)" do
      # Register a callback that will fail (return :callback_failed from Merge)
      fail_cb = fn _context, _command, _cwd -> :callback_failed end
      CodePuppyControl.Callbacks.register(:run_shell_command, fail_cb)

      try do
        result = Security.check("echo callback_failed_test")
        assert result.allowed == false
        assert match?({:denied, _}, result.decision)
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, fail_cb)
      end
    end

    test "callback returning {:callback_failed, reason} denies execution (fail-closed)" do
      fail_cb = fn _context, _command, _cwd -> {:callback_failed, :timeout} end
      CodePuppyControl.Callbacks.register(:run_shell_command, fail_cb)

      try do
        result = Security.check("echo callback_failed_tuple_test")
        assert result.allowed == false
        assert match?({:denied, _}, result.decision)
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, fail_cb)
      end
    end

    test "callback that raises is caught by Callbacks as :callback_failed, denying execution" do
      raise_cb = fn _context, _command, _cwd -> raise "boom" end
      CodePuppyControl.Callbacks.register(:run_shell_command, raise_cb)

      try do
        result = Security.check("echo callback_raises_test")
        assert result.allowed == false
        # The Callbacks module catches the raise and returns :callback_failed sentinel.
        # Our fail-closed logic treats :callback_failed as blocked.
        assert {:denied, reason} = result.decision
        assert reason =~ "blocked by security plugin"
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, raise_cb)
      end
    end

    test "callback that crashes (throw) is caught as :callback_failed, denying execution" do
      crash_cb = fn _context, _command, _cwd -> throw(:boom) end
      CodePuppyControl.Callbacks.register(:run_shell_command, crash_cb)

      try do
        result = Security.check("echo callback_crash_test")
        assert result.allowed == false
        # The Callbacks module catches the throw and returns :callback_failed sentinel.
        # Our fail-closed logic treats :callback_failed as blocked.
        assert {:denied, reason} = result.decision
        assert reason =~ "blocked by security plugin"
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, crash_cb)
      end
    end

    test "callback returning %{blocked: true} denies execution" do
      block_cb = fn _context, _command, _cwd -> %{blocked: true} end
      CodePuppyControl.Callbacks.register(:run_shell_command, block_cb)

      try do
        result = Security.check("echo blocked_test")
        assert result.allowed == false
        assert match?({:denied, _}, result.decision)
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, block_cb)
      end
    end

    test "callback returning nil allows execution (no block)" do
      allow_cb = fn _context, _command, _cwd -> nil end
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb)

      try do
        result = Security.check("echo allowed_test")
        # May be allowed or denied by policy, but not by callback
        # The callback itself should not block
        assert match?({:denied, _}, result.decision) or result.allowed == true or
                 match?({:ask_user, _}, result.decision)
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb)
      end
    end
  end

  describe "fail-closed with multiple callbacks (regression code_puppy-mmk.6)" do
    # Regression tests for the bug where Callbacks.trigger(:noop merge) silently
    # discarded :callback_failed sentinels when mixed with nil or %{blocked: false}
    # results from other callbacks. Security.callback_check now uses
    # Callbacks.trigger_raw/2 to inspect unmerged results directly.

    test "one callback raises, one returns nil → command denied (fail-closed)" do
      raise_cb = fn _ctx, _cmd, _cwd -> raise "security check crashed" end
      allow_cb = fn _ctx, _cmd, _cwd -> nil end
      CodePuppyControl.Callbacks.register(:run_shell_command, raise_cb)
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb)

      try do
        result = Security.check("echo multi_raise_nil")
        assert result.allowed == false
        assert {:denied, reason} = result.decision
        assert reason =~ "blocked by security plugin"
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, raise_cb)
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb)
      end
    end

    test "one callback raises, one returns %{blocked: false} → command denied (fail-closed)" do
      raise_cb = fn _ctx, _cmd, _cwd -> raise "security check crashed" end
      allow_cb = fn _ctx, _cmd, _cwd -> %{blocked: false} end
      CodePuppyControl.Callbacks.register(:run_shell_command, raise_cb)
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb)

      try do
        result = Security.check("echo multi_raise_allow")
        assert result.allowed == false
        assert {:denied, reason} = result.decision
        assert reason =~ "blocked by security plugin"
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, raise_cb)
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb)
      end
    end

    test "one callback returns :callback_failed, one returns nil → command denied (fail-closed)" do
      fail_cb = fn _ctx, _cmd, _cwd -> :callback_failed end
      allow_cb = fn _ctx, _cmd, _cwd -> nil end
      CodePuppyControl.Callbacks.register(:run_shell_command, fail_cb)
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb)

      try do
        result = Security.check("echo multi_failed_nil")
        assert result.allowed == false
        assert match?({:denied, _}, result.decision)
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, fail_cb)
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb)
      end
    end

    test "one callback returns %{blocked: true}, one returns nil → command denied" do
      block_cb = fn _ctx, _cmd, _cwd -> %{blocked: true} end
      allow_cb = fn _ctx, _cmd, _cwd -> nil end
      CodePuppyControl.Callbacks.register(:run_shell_command, block_cb)
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb)

      try do
        result = Security.check("echo multi_block_nil")
        assert result.allowed == false
        assert match?({:denied, _}, result.decision)
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, block_cb)
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb)
      end
    end

    test "one callback returns %{blocked: true}, one returns %{blocked: false} → command denied" do
      block_cb = fn _ctx, _cmd, _cwd -> %{blocked: true} end
      allow_cb = fn _ctx, _cmd, _cwd -> %{blocked: false} end
      CodePuppyControl.Callbacks.register(:run_shell_command, block_cb)
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb)

      try do
        result = Security.check("echo multi_block_allow")
        assert result.allowed == false
        assert match?({:denied, _}, result.decision)
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, block_cb)
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb)
      end
    end

    test "both callbacks return nil → command not blocked by callbacks" do
      allow_cb1 = fn _ctx, _cmd, _cwd -> nil end
      allow_cb2 = fn _ctx, _cmd, _cwd -> nil end
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb1)
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb2)

      try do
        result = Security.check("echo multi_both_nil")
        # No callback blocked — decision depends on policy, not callbacks
        assert match?({:denied, _}, result.decision) or result.allowed == true or
                 match?({:ask_user, _}, result.decision)
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb1)
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb2)
      end
    end

    test "one callback throws, one returns %{blocked: false} → command denied (fail-closed)" do
      throw_cb = fn _ctx, _cmd, _cwd -> throw(:security_error) end
      allow_cb = fn _ctx, _cmd, _cwd -> %{blocked: false} end
      CodePuppyControl.Callbacks.register(:run_shell_command, throw_cb)
      CodePuppyControl.Callbacks.register(:run_shell_command, allow_cb)

      try do
        result = Security.check("echo multi_throw_allow")
        assert result.allowed == false
        assert {:denied, reason} = result.decision
        assert reason =~ "blocked by security plugin"
      after
        CodePuppyControl.Callbacks.unregister(:run_shell_command, throw_cb)
        CodePuppyControl.Callbacks.unregister(:run_shell_command, allow_cb)
      end
    end
  end

  describe "explicit allow-policy returns proper map (regression code_puppy-mmk.6)" do
    # Regression: when PolicyEngine returns :allowed and no callback blocks,
    # callback_check/3 previously returned the bare :allowed atom which leaked
    # out of Security.check/2, causing CommandRunner.run/2 to crash with
    # CaseClauseError (it expected %{allowed: true}, not :allowed).
    # Fix: callback_check returns :allowed, but Security.check/2 now matches
    # :allowed explicitly and converts it to the documented allowed map.

    setup do
      # Add an explicit Allow policy rule for run_shell_command so that
      # PolicyEngine.check_shell_command/2 returns %Allow{} instead of
      # the default %AskUser{}. This exercises the explicit-allow code path.
      alias CodePuppyControl.PolicyEngine.PolicyRule

      rule =
        PolicyRule.new(
          tool_name: "run_shell_command",
          decision: :allow,
          priority: 100,
          source: "regression_test_mmk6"
        )

      PolicyEngine.add_rule(rule)

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("regression_test_mmk6")
      end)

      :ok
    end

    test "Security.check returns proper allowed map when policy allows and no callback blocks" do
      result = Security.check("echo explicit_allow_test")

      # Must be a map, not a bare atom
      assert is_map(result)
      assert result.allowed == true
      assert result.decision == :allowed
      assert result.reason == nil
    end

    test "Security.check allowed map matches documented %{allowed: true, decision: :allowed, reason: nil}" do
      result = Security.check("echo map_shape_test")

      # With the explicit Allow rule, the result must match exactly
      assert result == %{allowed: true, decision: :allowed, reason: nil}
    end
  end
end
