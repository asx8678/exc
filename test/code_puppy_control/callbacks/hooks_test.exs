defmodule CodePuppyControl.Callbacks.HooksTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Callbacks.Hooks

  # ── All known hooks from the Python callbacks.py ────────────────
  @expected_hooks [
    :agent_exception,
    :agent_reload,
    :agent_run_end,
    :agent_run_start,
    :custom_command,
    :custom_command_help,
    :delete_file,
    :delete_snippet,
    :edit_file,
    :file_permission,
    :get_model_system_prompt,
    :get_motd,
    :invoke_agent,
    :load_model_config,
    :load_models_config,
    :load_prompt,
    :message_history_processor_end,
    :message_history_processor_start,
    :post_tool_call,
    :pre_tool_call,
    :register_agents,
    :register_browser_types,
    :register_mcp_catalog_servers,
    :register_model_providers,
    :register_model_type,
    :register_tools,
    :run_shell_command,
    :shutdown,
    :startup,
    :stream_event,
    :version_check,
    :create_file,
    :replace_in_file
  ]

  describe "all/0" do
    test "returns a non-empty map" do
      hooks = Hooks.all()
      assert is_map(hooks)
      assert map_size(hooks) > 0
    end

    test "contains all expected hooks" do
      hooks = Hooks.all()

      for hook <- @expected_hooks do
        assert Map.has_key?(hooks, hook),
               "Missing hook: #{hook}"
      end
    end

    test "every hook has required keys" do
      for {_name, config} <- Hooks.all() do
        assert Map.has_key?(config, :arity), "Hook missing :arity"
        assert Map.has_key?(config, :merge), "Hook missing :merge"
        assert Map.has_key?(config, :async), "Hook missing :async"
        assert Map.has_key?(config, :description), "Hook missing :description"
      end
    end

    test "every hook has a valid merge type" do
      valid_merge_types = [:noop, :concat_str, :extend_list, :update_map, :or_bool]

      for {name, config} <- Hooks.all() do
        assert config.merge in valid_merge_types,
               "Hook #{name} has invalid merge type: #{inspect(config.merge)}"
      end
    end

    test "every hook has a non-negative arity" do
      for {name, config} <- Hooks.all() do
        assert is_integer(config.arity) and config.arity >= 0,
               "Hook #{name} has invalid arity: #{inspect(config.arity)}"
      end
    end

    test "every hook has a boolean async flag" do
      for {name, config} <- Hooks.all() do
        assert is_boolean(config.async),
               "Hook #{name} has non-boolean async: #{inspect(config.async)}"
      end
    end

    test "every hook has a non-empty description" do
      for {name, config} <- Hooks.all() do
        assert is_binary(config.description) and config.description != "",
               "Hook #{name} has empty/invalid description"
      end
    end
  end

  describe "get/1" do
    test "returns {:ok, config} for known hooks" do
      assert {:ok, %{merge: :concat_str}} = Hooks.get(:load_prompt)
    end

    test "returns :error for unknown hooks" do
      assert :error = Hooks.get(:nonexistent_hook)
    end
  end

  describe "names/0" do
    test "returns a sorted list of hook names" do
      names = Hooks.names()
      assert is_list(names)
      assert names == Enum.sort(names)
    end

    test "includes all expected hooks" do
      names = Hooks.names()

      for hook <- @expected_hooks do
        assert hook in names, "Missing hook name: #{hook}"
      end
    end
  end

  describe "merge_type/1" do
    test "returns correct merge type for load_prompt" do
      assert :concat_str = Hooks.merge_type(:load_prompt)
    end

    test "returns correct merge type for register_tools" do
      assert :extend_list = Hooks.merge_type(:register_tools)
    end

    test "returns correct merge type for load_model_config" do
      assert :update_map = Hooks.merge_type(:load_model_config)
    end

    test "returns :noop for unknown hook" do
      assert :noop = Hooks.merge_type(:nonexistent_hook)
    end

    test "returns :noop for startup (no merge needed)" do
      assert :noop = Hooks.merge_type(:startup)
    end

    test "returns :or_bool for file_permission (AGENTS table: bool→OR)" do
      assert :or_bool = Hooks.merge_type(:file_permission)
    end

    test "returns :noop for get_motd (returns tuple, not list)" do
      assert :noop = Hooks.merge_type(:get_motd)
    end

    test "returns :extend_list for register_model_type" do
      assert :extend_list = Hooks.merge_type(:register_model_type)
    end
  end

  describe "async?/1" do
    test "stream_event is async" do
      assert true = Hooks.async?(:stream_event)
    end

    test "startup is not async" do
      assert false == Hooks.async?(:startup)
    end

    test "agent_run_start is async" do
      assert true = Hooks.async?(:agent_run_start)
    end

    test "load_prompt is not async" do
      assert false == Hooks.async?(:load_prompt)
    end

    test "unknown hook returns false" do
      assert false == Hooks.async?(:nonexistent_hook)
    end
  end

  describe "arity/1" do
    test "startup has arity 0" do
      assert 0 = Hooks.arity(:startup)
    end

    test "stream_event has arity 3" do
      assert 3 = Hooks.arity(:stream_event)
    end

    test "agent_run_end has arity 7" do
      assert 7 = Hooks.arity(:agent_run_end)
    end

    test "message_history_processor_start has arity 4" do
      assert 4 = Hooks.arity(:message_history_processor_start)
    end

    test "message_history_processor_end has arity 5" do
      assert 5 = Hooks.arity(:message_history_processor_end)
    end

    test "file_permission has arity 6" do
      assert 6 = Hooks.arity(:file_permission)
    end

    test "unknown hook returns 0" do
      assert 0 = Hooks.arity(:nonexistent_hook)
    end
  end

  describe "valid?/1" do
    test "returns true for known hooks" do
      assert true = Hooks.valid?(:startup)
      assert true = Hooks.valid?(:load_prompt)
    end

    test "returns false for unknown hooks" do
      assert false == Hooks.valid?(:nonexistent_hook)
    end
  end
end
