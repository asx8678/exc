defmodule CodePuppyControl.Callbacks.ParityTest do
  @moduledoc """
  Python parity tests: validates that the Elixir hook declarations
  match the Python `code_puppy/callbacks.py` PhaseType definitions.

  This test acts as a golden reference to catch drift between the
  two implementations. If Python adds a new hook, this test fails
  until the Elixir port is updated.

  Refs: code_puppy-154.6 (Phase F port)
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Callbacks.Hooks

  # ── Python PhaseType definitions (from code_puppy/callbacks.py) ──
  # This is the authoritative list. Every hook here MUST exist in
  # the Elixir Hooks module with matching merge semantics.
  @python_hooks [
    # {hook_name, merge_type}
    # Merge semantics from AGENTS.md: str→concat, list→extend,
    # dict→update, bool→OR, None→ignored. noop for observer hooks.
    {:startup, :noop},
    {:shutdown, :noop},
    {:invoke_agent, :noop},
    {:agent_exception, :noop},
    {:version_check, :noop},
    {:edit_file, :noop},
    {:create_file, :noop},
    {:replace_in_file, :noop},
    {:delete_snippet, :noop},
    {:delete_file, :noop},
    {:run_shell_command, :noop},
    {:load_model_config, :update_map},
    {:load_models_config, :update_map},
    {:load_prompt, :concat_str},
    {:agent_reload, :noop},
    {:custom_command, :noop},
    {:custom_command_help, :extend_list},
    {:file_permission, :or_bool},
    {:pre_tool_call, :noop},
    {:post_tool_call, :noop},
    {:stream_event, :noop},
    {:register_tools, :extend_list},
    {:register_agents, :extend_list},
    {:register_model_type, :extend_list},
    {:get_model_system_prompt, :noop},
    {:agent_run_start, :noop},
    {:agent_run_end, :noop},
    {:register_mcp_catalog_servers, :extend_list},
    {:register_browser_types, :extend_list},
    {:get_motd, :noop},
    {:register_model_providers, :extend_list},
    {:message_history_processor_start, :noop},
    {:message_history_processor_end, :noop}
  ]

  describe "Python parity — every Python hook exists in Elixir" do
    test "all Python hooks are declared in Elixir Hooks" do
      for {hook_name, _expected_merge} <- @python_hooks do
        assert Hooks.valid?(hook_name),
               "Python hook #{hook_name} is missing from Elixir Hooks"
      end
    end

    test "all Python hooks have matching merge types" do
      for {hook_name, expected_merge} <- @python_hooks do
        actual = Hooks.merge_type(hook_name)

        assert actual == expected_merge,
               "Hook #{hook_name}: expected merge #{inspect(expected_merge)}, got #{inspect(actual)}"
      end
    end

    test "no extra Elixir hooks beyond Python definitions" do
      python_names = Enum.map(@python_hooks, fn {name, _} -> name end) |> MapSet.new()
      elixir_names = Hooks.names() |> MapSet.new()

      extra = MapSet.difference(elixir_names, python_names)

      assert MapSet.size(extra) == 0,
             "Elixir has extra hooks not in Python: #{inspect(MapSet.to_list(extra))}"
    end

    test "hook count matches Python" do
      assert length(@python_hooks) == length(Hooks.names())
    end
  end

  describe "merge semantics — AGENTS.md table compliance" do
    test "str→concat: load_prompt uses :concat_str" do
      assert :concat_str = Hooks.merge_type(:load_prompt)
    end

    test "list→extend: register_tools uses :extend_list" do
      assert :extend_list = Hooks.merge_type(:register_tools)
    end

    test "dict→update: load_model_config uses :update_map (later wins)" do
      assert :update_map = Hooks.merge_type(:load_model_config)
    end

    test "bool→OR: file_permission uses :or_bool" do
      assert :or_bool = Hooks.merge_type(:file_permission)
    end

    test "None/nil ignored: filter_valid removes nil and :callback_failed" do
      alias CodePuppyControl.Callbacks.Merge

      assert [1, 2] = Merge.filter_valid([1, nil, :callback_failed, 2])
      assert [] = Merge.filter_valid([nil, :callback_failed, nil])
    end
  end

  describe "security hooks — fail-closed / noop / raw semantics" do
    test "file_permission: declared :or_bool but Security module uses trigger_raw" do
      # The declared merge type is :or_bool for trigger/2 usage,
      # but the Security module uses trigger_raw to preserve
      # :callback_failed sentinels for fail-closed processing.
      assert :or_bool = Hooks.merge_type(:file_permission)

      # Verify Security module is available
      assert Code.ensure_loaded?(CodePuppyControl.Callbacks.Security)
    end

    test "run_shell_command: declared :noop, Security module uses trigger_raw" do
      assert :noop = Hooks.merge_type(:run_shell_command)
      assert Code.ensure_loaded?(CodePuppyControl.Callbacks.Security)
    end

    test "pre_tool_call: declared :noop, Security module uses trigger_raw" do
      assert :noop = Hooks.merge_type(:pre_tool_call)
      assert Code.ensure_loaded?(CodePuppyControl.Callbacks.Security)
    end

    test "post_tool_call: NOT fail-closed (observer, not security gate)" do
      # Post-tool callbacks observe results, they don't gate execution.
      # No fail-closed replacement needed.
      assert :noop = Hooks.merge_type(:post_tool_call)
    end

    test "trigger_raw preserves :callback_failed for security hooks" do
      alias CodePuppyControl.Callbacks

      Callbacks.clear(:run_shell_command)
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> raise "boom" end)
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> %{blocked: false} end)

      results = Callbacks.trigger_raw(:run_shell_command, [%{}, "ls", "/tmp"])
      assert :callback_failed in results
      assert %{blocked: false} in results
    end

    test "trigger_raw_async preserves :callback_failed for async security hooks" do
      alias CodePuppyControl.Callbacks

      Callbacks.clear(:file_permission)
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ -> raise "boom" end)
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ -> true end)

      {:ok, results} =
        Callbacks.trigger_raw_async(:file_permission, [%{}, "test.ex", "create", nil, nil, nil])

      assert :callback_failed in results
      assert true in results
    end
  end

  describe "trigger functions — Python-compatible API" do
    test "Callbacks.Triggers module has on_* for every hook" do
      alias CodePuppyControl.Callbacks.Triggers

      trigger_fns = Triggers.__info__(:functions)
      trigger_names = Enum.map(trigger_fns, fn {name, _arity} -> name end) |> Enum.uniq()

      for {hook_name, _merge} <- @python_hooks do
        func_name = "on_#{hook_name}" |> String.to_atom()

        # Security hooks also have fail-closed variants in Security module
        has_security =
          hook_name in [:file_permission, :run_shell_command, :pre_tool_call, :post_tool_call]

        assert func_name in trigger_names or has_security,
               "No on_#{hook_name} function in Triggers module for hook #{hook_name}"
      end
    end

    test "Callbacks.Security has fail-closed wrappers for security hooks" do
      alias CodePuppyControl.Callbacks.Security

      # Check that Security module is compiled and has the expected functions
      # Using Code.ensure_loaded? to guarantee module availability
      assert Code.ensure_loaded?(Security)

      # Check for function exports (with default args, multiple arities exist)
      security_fns = Security.__info__(:functions)

      fn_names = Enum.map(security_fns, fn {name, _arity} -> name end) |> Enum.uniq()
      assert :on_file_permission in fn_names
      assert :on_file_permission_async in fn_names
      assert :on_run_shell_command in fn_names
      assert :on_pre_tool_call in fn_names
      assert :on_post_tool_call in fn_names
      assert :any_denied? in fn_names
    end
  end

  describe "compatibility with existing plugins" do
    test "existing plugins can register for register_model_type (was register_model_types)" do
      alias CodePuppyControl.Callbacks

      # The hook name was changed from register_model_types → register_model_type
      # to match Python. Existing plugins that used the old name would need updating.
      # Verify the new name works.
      fun = fn -> [%{type: "test", handler: fn -> :ok end}] end
      assert :ok = Callbacks.register(:register_model_type, fun)

      # Verify it triggers correctly
      result = Callbacks.trigger(:register_model_type)
      assert [%{type: "test"}] = result

      Callbacks.unregister(:register_model_type, fun)
    end

    test "Triggers.on_register_model_types/0 delegates to on_register_model_type/0" do
      alias CodePuppyControl.Callbacks
      alias CodePuppyControl.Callbacks.Triggers

      fun = fn -> [%{type: "alias_test"}] end
      assert :ok = Callbacks.register(:register_model_type, fun)

      # Both names return identical results
      assert Triggers.on_register_model_types() == Triggers.on_register_model_type()

      Callbacks.unregister(:register_model_type, fun)
    end
  end
end
