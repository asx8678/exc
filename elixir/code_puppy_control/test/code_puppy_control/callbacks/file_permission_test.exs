defmodule CodePuppyControl.Callbacks.FilePermissionTest do
  @moduledoc """
  Tests for CodePuppyControl.Callbacks.FilePermission.

  Covers:
  - Allow path (no rules, no callbacks → default AskUser; explicit allow → Allow)
  - Deny path (PolicyEngine deny, callback deny)
  - Fail-closed on callback exceptions
  - Fail-closed on PolicyEngine unavailability
  - Mixed callback results (one denies → overall deny)
  - Callback returning false → deny
  - Callback returning true → no block
  - Callback returning nil → abstain
  - tool_name override option
  - operation_data / preview compatibility
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Callbacks.FilePermission
  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule
  alias CodePuppyControl.PolicyEngine.PolicyRule.{Allow, Deny, AskUser}

  setup do
    PolicyEngine.reset()
    Callbacks.clear(:file_permission)
    :ok
  end

  describe "check/7 — default behavior (no rules, no callbacks)" do
    test "returns AskUser when no rules match" do
      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %AskUser{} = result
    end
  end

  describe "check/7 — PolicyEngine allow" do
    test "returns Allow when policy allows and no callbacks block" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "create_file",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Allow{} = result
    end
  end

  describe "check/7 — PolicyEngine deny" do
    test "returns Deny when policy denies" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "delete_file",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      result = FilePermission.check(%{}, "lib/foo.ex", "delete")
      assert %Deny{reason: reason} = result
      assert reason =~ "Denied by policy"
    end

    test "short-circuits: does not call callbacks when policy denies" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "delete_file",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      # Register a callback that would block, but it shouldn't be reached
      cb = fn _ctx, _path, _op, _, _, _ -> true end
      Callbacks.register(:file_permission, cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "delete")
      assert %Deny{} = result

      Callbacks.unregister(:file_permission, cb)
    end
  end

  describe "check/7 — PolicyEngine ask_user" do
    test "returns AskUser when policy says ask and no callback blocks" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "read_file",
        decision: :ask_user,
        priority: 10,
        source: "test"
      })

      result = FilePermission.check(%{}, "lib/foo.ex", "read")
      assert %AskUser{} = result
    end

    test "callback can override ask_user to deny" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "read_file",
        decision: :ask_user,
        priority: 10,
        source: "test"
      })

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "read")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end
  end

  describe "check/7 — callback interactions" do
    setup do
      # Allow file operations by default so we can test callbacks
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "*",
        decision: :allow,
        priority: 1,
        source: "test_setup"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test_setup")
      end)

      :ok
    end

    test "callback returning true does not block" do
      cb = fn _ctx, _path, _op, _, _, _ -> true end
      Callbacks.register(:file_permission, cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Allow{} = result

      Callbacks.unregister(:file_permission, cb)
    end

    test "callback returning nil does not block (abstain)" do
      cb = fn _ctx, _path, _op, _, _, _ -> nil end
      Callbacks.register(:file_permission, cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Allow{} = result

      Callbacks.unregister(:file_permission, cb)
    end

    test "callback returning false blocks the operation" do
      cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, cb)
    end

    test "callback returning %Deny{} blocks the operation" do
      cb = fn _ctx, _path, _op, _, _, _ -> %Deny{reason: "custom deny reason"} end
      Callbacks.register(:file_permission, cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{} = result

      Callbacks.unregister(:file_permission, cb)
    end
  end

  describe "check/7 — fail-closed semantics" do
    setup do
      # Allow file operations by default so we can test callbacks
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "*",
        decision: :allow,
        priority: 1,
        source: "test_setup"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test_setup")
      end)

      :ok
    end

    test "callback that raises denies the operation (fail-closed)" do
      # When a callback raises, Callbacks.trigger_raw catches it and
      # replaces with :callback_failed. Our fail-closed logic treats
      # :callback_failed as a denial, so the operation is blocked.
      raise_cb = fn _ctx, _path, _op, _, _, _ -> raise "security check boom" end
      Callbacks.register(:file_permission, raise_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, raise_cb)
    end

    test "callback that throws denies the operation (fail-closed)" do
      # When a callback throws, Callbacks.trigger_raw catches it and
      # replaces with :callback_failed. Our fail-closed logic treats
      # :callback_failed as a denial, so the operation is blocked.
      throw_cb = fn _ctx, _path, _op, _, _, _ -> throw(:boom) end
      Callbacks.register(:file_permission, throw_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, throw_cb)
    end

    test "callback returning :callback_failed denies the operation (fail-closed)" do
      # Simulate a crashed callback that the Merge system replaced with :callback_failed
      fail_cb = fn _ctx, _path, _op, _, _, _ -> :callback_failed end
      Callbacks.register(:file_permission, fail_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, fail_cb)
    end

    test "callback returning {:callback_failed, reason} denies the operation (fail-closed)" do
      # Tuple-form crash sentinel (matches RunShellCommand behavior)
      fail_cb = fn _ctx, _path, _op, _, _, _ -> {:callback_failed, :timeout} end
      Callbacks.register(:file_permission, fail_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, fail_cb)
    end
  end

  describe "check/7 — mixed callback results" do
    setup do
      # Allow file operations by default so we can test callbacks
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "*",
        decision: :allow,
        priority: 1,
        source: "test_setup"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test_setup")
      end)

      :ok
    end

    test "one callback denies, one allows → overall deny" do
      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      allow_cb = fn _ctx, _path, _op, _, _, _ -> true end
      Callbacks.register(:file_permission, deny_cb)
      Callbacks.register(:file_permission, allow_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{} = result

      Callbacks.unregister(:file_permission, deny_cb)
      Callbacks.unregister(:file_permission, allow_cb)
    end

    test "one callback raises, one returns nil → overall deny (fail-closed)" do
      raise_cb = fn _ctx, _path, _op, _, _, _ -> raise "boom" end
      allow_cb = fn _ctx, _path, _op, _, _, _ -> nil end
      Callbacks.register(:file_permission, raise_cb)
      Callbacks.register(:file_permission, allow_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, raise_cb)
      Callbacks.unregister(:file_permission, allow_cb)
    end

    test "one callback raises, one returns true → overall deny (fail-closed)" do
      raise_cb = fn _ctx, _path, _op, _, _, _ -> raise "security error" end
      allow_cb = fn _ctx, _path, _op, _, _, _ -> true end
      Callbacks.register(:file_permission, raise_cb)
      Callbacks.register(:file_permission, allow_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, raise_cb)
      Callbacks.unregister(:file_permission, allow_cb)
    end

    test "both callbacks return nil → not blocked" do
      allow_cb1 = fn _ctx, _path, _op, _, _, _ -> nil end
      allow_cb2 = fn _ctx, _path, _op, _, _, _ -> nil end
      Callbacks.register(:file_permission, allow_cb1)
      Callbacks.register(:file_permission, allow_cb2)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Allow{} = result

      Callbacks.unregister(:file_permission, allow_cb1)
      Callbacks.unregister(:file_permission, allow_cb2)
    end

    test "one callback returns :callback_failed, one returns true → deny (fail-closed)" do
      fail_cb = fn _ctx, _path, _op, _, _, _ -> :callback_failed end
      allow_cb = fn _ctx, _path, _op, _, _, _ -> true end
      Callbacks.register(:file_permission, fail_cb)
      Callbacks.register(:file_permission, allow_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{} = result

      Callbacks.unregister(:file_permission, fail_cb)
      Callbacks.unregister(:file_permission, allow_cb)
    end

    test "one callback returns {:callback_failed, _}, one returns true → deny (fail-closed)" do
      fail_cb = fn _ctx, _path, _op, _, _, _ -> {:callback_failed, :timeout} end
      allow_cb = fn _ctx, _path, _op, _, _, _ -> true end
      Callbacks.register(:file_permission, fail_cb)
      Callbacks.register(:file_permission, allow_cb)

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Deny{reason: reason} = result
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, fail_cb)
      Callbacks.unregister(:file_permission, allow_cb)
    end
  end

  describe "check/7 — tool_name option" do
    test "uses derived tool name by default (operation + '_file')" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "create_file",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      result = FilePermission.check(%{}, "lib/foo.ex", "create")
      assert %Allow{} = result
    end

    test "uses explicit tool_name option when provided" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "custom_tool",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      result =
        FilePermission.check(%{}, "lib/foo.ex", "create", nil, nil, nil, tool_name: "custom_tool")

      assert %Allow{} = result
    end
  end

  describe "check/7 — operation_data vs preview" do
    setup do
      # Allow file operations by default
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "*",
        decision: :allow,
        priority: 1,
        source: "test_setup"
      })

      on_exit(fn ->
        PolicyEngine.remove_rules_by_source("test_setup")
      end)

      :ok
    end

    test "passes operation_data to callbacks" do
      test_pid = self()

      cb = fn _ctx, _path, _op, preview, _mg, operation_data ->
        send(test_pid, {:callback_args, preview, operation_data})
        nil
      end

      Callbacks.register(:file_permission, cb)

      FilePermission.check(%{}, "lib/foo.ex", "create", "old preview", nil, %{diff: "++ line"})

      # When operation_data is provided, preview should be nil (backward compat)
      assert_received {:callback_args, nil, %{diff: "++ line"}}

      Callbacks.unregister(:file_permission, cb)
    end

    test "passes preview when operation_data is nil" do
      test_pid = self()

      cb = fn _ctx, _path, _op, preview, _mg, operation_data ->
        send(test_pid, {:callback_args, preview, operation_data})
        nil
      end

      Callbacks.register(:file_permission, cb)

      FilePermission.check(%{}, "lib/foo.ex", "create", "old preview", nil, nil)

      assert_received {:callback_args, "old preview", nil}

      Callbacks.unregister(:file_permission, cb)
    end
  end
end
