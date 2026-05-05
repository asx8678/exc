defmodule CodePuppyControl.Callbacks.SecurityTest do
  @moduledoc """
  Tests for CodePuppyControl.Callbacks.Security.

  Covers:
  - on_file_permission/6: fail-closed (crashed callback → false)
  - on_file_permission_async/6: fail-closed (crashed callback → false)
  - on_run_shell_command/3: fail-closed (crashed callback → %{blocked: true})
  - on_pre_tool_call/3: fail-closed (crashed callback → %{blocked: true, reason: ...})
  - on_post_tool_call/5: NOT fail-closed (crashed callback → :callback_failed preserved)
  - any_denied?/1: utility for checking denial in results
  - Backward compatibility: operation_data overrides preview
  - Mixed results: one crashes, one allows → deny
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Callbacks.Security

  setup do
    Callbacks.clear()
    on_exit(fn -> Callbacks.clear() end)
    :ok
  end

  # ── on_file_permission/6 ────────────────────────────────────────

  describe "on_file_permission/6 — fail-closed" do
    test "returns empty list when no callbacks registered" do
      assert [] = Security.on_file_permission(%{}, "test.ex", "create")
    end

    test "passes args to callbacks" do
      test_pid = self()

      Callbacks.register(:file_permission, fn ctx, path, op, preview, mg, op_data ->
        send(test_pid, {:fp_args, ctx, path, op, preview, mg, op_data})
        true
      end)

      Security.on_file_permission(%{run_id: "r1"}, "lib/foo.ex", "create", "prev", "mg1", %{
        diff: "++"
      })

      assert_received {:fp_args, %{run_id: "r1"}, "lib/foo.ex", "create", nil, "mg1",
                       %{diff: "++"}}
    end

    test "crashed callback returns false (fail-closed)" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ ->
        raise "security boom"
      end)

      results = Security.on_file_permission(%{}, "test.ex", "create")
      assert results == [false]
    end

    test "callback returning :callback_failed is replaced with false" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ ->
        :callback_failed
      end)

      results = Security.on_file_permission(%{}, "test.ex", "create")
      assert results == [false]
    end

    test "callback returning {:callback_failed, reason} is replaced with false" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ ->
        {:callback_failed, :timeout}
      end)

      results = Security.on_file_permission(%{}, "test.ex", "create")
      assert results == [false]
    end

    test "callback returning true is preserved" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ -> true end)
      results = Security.on_file_permission(%{}, "test.ex", "create")
      assert results == [true]
    end

    test "callback returning nil is preserved" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ -> nil end)
      results = Security.on_file_permission(%{}, "test.ex", "create")
      assert results == [nil]
    end

    test "mixed: one crashes, one returns nil → false in results (fail-closed)" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ ->
        raise "boom"
      end)

      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ -> nil end)

      results = Security.on_file_permission(%{}, "test.ex", "create")
      assert false in results
      assert nil in results
    end

    test "operation_data overrides preview (backward compat)" do
      test_pid = self()

      Callbacks.register(:file_permission, fn _ctx, _path, _op, preview, _mg, op_data ->
        send(test_pid, {:compat, preview, op_data})
        true
      end)

      Security.on_file_permission(%{}, "test.ex", "create", "old preview", nil, %{diff: "++"})

      # When operation_data is provided, preview should be nil
      assert_received {:compat, nil, %{diff: "++"}}
    end

    test "preview is passed when operation_data is nil" do
      test_pid = self()

      Callbacks.register(:file_permission, fn _ctx, _path, _op, preview, _mg, op_data ->
        send(test_pid, {:compat, preview, op_data})
        true
      end)

      Security.on_file_permission(%{}, "test.ex", "create", "old preview", nil, nil)

      assert_received {:compat, "old preview", nil}
    end
  end

  # ── on_file_permission_async/6 ─────────────────────────────────

  describe "on_file_permission_async/6 — fail-closed" do
    test "returns {:ok, []} when no callbacks registered" do
      assert {:ok, []} == Security.on_file_permission_async(%{}, "test.ex", "create")
    end

    test "callback returning true is preserved" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ -> true end)
      assert {:ok, [true]} == Security.on_file_permission_async(%{}, "test.ex", "create")
    end

    test "crashed callback returns false in results (fail-closed)" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ ->
        raise "async boom"
      end)

      assert {:ok, [false]} == Security.on_file_permission_async(%{}, "test.ex", "create")
    end
  end

  # ── on_run_shell_command/3 ──────────────────────────────────────

  describe "on_run_shell_command/3 — fail-closed" do
    test "returns empty list when no callbacks registered" do
      assert [] = Security.on_run_shell_command(%{}, "echo hi")
    end

    test "callback returning nil is preserved" do
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> nil end)
      results = Security.on_run_shell_command(%{}, "echo hi")
      assert results == [nil]
    end

    test "callback returning %{blocked: false} is preserved" do
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> %{blocked: false} end)
      results = Security.on_run_shell_command(%{}, "echo hi")
      assert results == [%{blocked: false}]
    end

    test "callback returning %{blocked: true} is preserved" do
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> %{blocked: true} end)
      results = Security.on_run_shell_command(%{}, "rm -rf /")
      assert results == [%{blocked: true}]
    end

    test "crashed callback returns %{blocked: true} (fail-closed)" do
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd ->
        raise "security crash"
      end)

      results = Security.on_run_shell_command(%{}, "echo hi")
      assert results == [%{blocked: true}]
    end

    test "callback returning :callback_failed is replaced with %{blocked: true}" do
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> :callback_failed end)
      results = Security.on_run_shell_command(%{}, "echo hi")
      assert results == [%{blocked: true}]
    end

    test "callback returning {:callback_failed, _} is replaced with %{blocked: true}" do
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd ->
        {:callback_failed, :timeout}
      end)

      results = Security.on_run_shell_command(%{}, "echo hi")
      assert results == [%{blocked: true}]
    end

    test "mixed: one crashes, one returns %{blocked: false} → both in results" do
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> raise "crash" end)
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> %{blocked: false} end)

      results = Security.on_run_shell_command(%{}, "echo hi")
      assert %{blocked: true} in results
      assert %{blocked: false} in results
    end
  end

  # ── on_pre_tool_call/3 ──────────────────────────────────────────

  describe "on_pre_tool_call/3 — fail-closed" do
    test "returns empty list when no callbacks registered" do
      assert [] = Security.on_pre_tool_call("read_file", %{})
    end

    test "callback returning nil is preserved" do
      Callbacks.register(:pre_tool_call, fn _name, _args, _ctx -> nil end)
      results = Security.on_pre_tool_call("read_file", %{})
      assert results == [nil]
    end

    test "crashed callback returns %{blocked: true, reason: ...} (fail-closed)" do
      Callbacks.register(:pre_tool_call, fn _name, _args, _ctx ->
        raise "security error"
      end)

      results = Security.on_pre_tool_call("read_file", %{})
      assert [%{blocked: true, reason: reason}] = results
      assert reason =~ "Security check failed"
    end

    test "callback returning :callback_failed is replaced with blocked" do
      Callbacks.register(:pre_tool_call, fn _name, _args, _ctx -> :callback_failed end)
      results = Security.on_pre_tool_call("delete_file", %{})
      assert [%{blocked: true}] = results
    end

    test "callback returning {:callback_failed, reason} is replaced with blocked" do
      Callbacks.register(:pre_tool_call, fn _name, _args, _ctx ->
        {:callback_failed, :timeout}
      end)

      results = Security.on_pre_tool_call("delete_file", %{})
      assert [%{blocked: true, reason: reason}] = results
      assert reason =~ "timeout"
    end
  end

  # ── on_post_tool_call/5 ──────────────────────────────────────────

  describe "on_post_tool_call/5 — NOT fail-closed" do
    test "returns empty list when no callbacks registered" do
      assert [] = Security.on_post_tool_call("read_file", %{}, "result", 10.0)
    end

    test "callback returning result is preserved" do
      Callbacks.register(:post_tool_call, fn _name, _args, result, _dur, _ctx ->
        {:logged, result}
      end)

      results = Security.on_post_tool_call("read_file", %{}, "contents", 10.0)
      assert [{:logged, "contents"}] = results
    end

    test "crashed callback preserves :callback_failed (NOT fail-closed)" do
      Callbacks.register(:post_tool_call, fn _name, _args, _result, _dur, _ctx ->
        raise "logging error"
      end)

      results = Security.on_post_tool_call("read_file", %{}, "contents", 10.0)
      assert :callback_failed in results
    end
  end

  # ── any_denied?/1 ───────────────────────────────────────────────

  describe "any_denied?/1" do
    test "returns false for empty list" do
      refute Security.any_denied?([])
    end

    test "returns false when all results allow" do
      refute Security.any_denied?([true, nil, %{blocked: false}])
    end

    test "returns true when any result is false" do
      assert Security.any_denied?([true, false, nil])
    end

    test "returns true when any result is :callback_failed" do
      assert Security.any_denied?([true, :callback_failed])
    end

    test "returns true when any result is {:callback_failed, _}" do
      assert Security.any_denied?([nil, {:callback_failed, :timeout}])
    end

    test "returns true when any result is %{blocked: true}" do
      assert Security.any_denied?([%{blocked: false}, %{blocked: true}])
    end

    test "returns true when any result is %Deny{}" do
      alias CodePuppyControl.PolicyEngine.PolicyRule.Deny
      assert Security.any_denied?([%Deny{reason: "nope"}])
    end
  end
end
