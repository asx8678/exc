defmodule CodePuppyControl.Callbacks.TriggersTest do
  @moduledoc """
  Tests for CodePuppyControl.Callbacks.Triggers.

  Covers:
  - Each on_* function delegates to the correct trigger type (sync/async)
  - Merge semantics match hook declarations
  - Args are passed correctly to callbacks
  - Default argument values work
  - No callbacks registered returns nil / {:ok, nil}
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Callbacks.Triggers

  setup do
    Callbacks.clear()
    :ok
  end

  # ── Lifecycle Hooks ──────────────────────────────────────────────

  describe "on_startup/0" do
    test "returns nil when no callbacks registered" do
      assert nil == Triggers.on_startup()
    end

    test "triggers sync callback" do
      Callbacks.register(:startup, fn -> :booted end)
      assert :booted = Triggers.on_startup()
    end
  end

  describe "on_shutdown/0" do
    test "returns nil when no callbacks registered" do
      Callbacks.reset_shutdown_stage()
      assert nil == Triggers.on_shutdown()
    end

    test "triggers with reentrancy guard" do
      Callbacks.reset_shutdown_stage()
      Callbacks.register(:shutdown, fn -> :clean end)
      assert :clean = Triggers.on_shutdown()
      # Second call returns nil (already complete)
      assert nil == Triggers.on_shutdown()
    end

    test "reentrancy guard prevents recursive shutdown" do
      Callbacks.reset_shutdown_stage()
      # Register a callback that tries to trigger shutdown recursively
      Callbacks.register(:shutdown, fn ->
        # This recursive call should be blocked
        Triggers.on_shutdown()
        :done
      end)

      result = Triggers.on_shutdown()
      assert :done = result
    end
  end

  describe "on_agent_reload/1" do
    test "passes agent module to callbacks" do
      Callbacks.register(:agent_reload, fn mod -> {:reloaded, mod} end)
      assert {:reloaded, MyAgent} = Triggers.on_agent_reload(MyAgent)
    end
  end

  # ── Agent Lifecycle Hooks ────────────────────────────────────────

  describe "on_invoke_agent/1" do
    test "returns {:ok, nil} when no callbacks registered" do
      assert {:ok, nil} == Triggers.on_invoke_agent(%{})
    end

    test "triggers async callback" do
      Callbacks.register(:invoke_agent, fn _ -> :invoked end)
      assert {:ok, :invoked} == Triggers.on_invoke_agent(%{})
    end
  end

  describe "on_agent_exception/2" do
    test "triggers async callback with exception" do
      Callbacks.register(:agent_exception, fn _exc, _args -> :logged end)
      assert {:ok, :logged} == Triggers.on_agent_exception(%RuntimeError{}, nil)
    end
  end

  describe "on_agent_run_start/3" do
    test "triggers async callback with args" do
      test_pid = self()

      Callbacks.register(:agent_run_start, fn name, model, sid ->
        send(test_pid, {:run_start, name, model, sid})
        :ok
      end)

      assert {:ok, :ok} == Triggers.on_agent_run_start("puppy", "gpt-4", "sess-1")
      assert_received {:run_start, "puppy", "gpt-4", "sess-1"}
    end

    test "default session_id is nil" do
      test_pid = self()

      Callbacks.register(:agent_run_start, fn _name, _model, sid ->
        send(test_pid, {:sid, sid})
        :ok
      end)

      Triggers.on_agent_run_start("puppy", "gpt-4")
      assert_received {:sid, nil}
    end
  end

  describe "on_agent_run_end/7" do
    test "triggers async callback with all args" do
      test_pid = self()

      Callbacks.register(:agent_run_end, fn _name, _model, _sid, success, _err, text, meta ->
        send(test_pid, {:run_end, success, text, meta})
        :ok
      end)

      assert {:ok, :ok} ==
               Triggers.on_agent_run_end("puppy", "gpt-4", "s1", true, nil, "woof!", %{tokens: 42})

      assert_received {:run_end, true, "woof!", %{tokens: 42}}
    end

    test "metadata defaults to nil" do
      test_pid = self()

      Callbacks.register(:agent_run_end, fn _name, _model, _sid, _success, _err, _text, meta ->
        send(test_pid, {:meta, meta})
        :ok
      end)

      assert {:ok, :ok} == Triggers.on_agent_run_end("puppy", "gpt-4", "s1", true, nil, "woof!")
      assert_received {:meta, nil}
    end
  end

  # ── Prompt / Config Hooks ────────────────────────────────────────

  describe "on_load_prompt/0" do
    test "concatenates string results" do
      Callbacks.register(:load_prompt, fn -> "## Section 1" end)
      Callbacks.register(:load_prompt, fn -> "## Section 2" end)

      assert "## Section 1\n## Section 2" = Triggers.on_load_prompt()
    end

    test "returns nil when no callbacks" do
      assert nil == Triggers.on_load_prompt()
    end
  end

  describe "on_load_model_config/2" do
    test "deep-merges map results" do
      Callbacks.register(:load_model_config, fn _a, _b -> %{api_key: "test"} end)
      Callbacks.register(:load_model_config, fn _a, _b -> %{timeout: 30} end)

      result = Triggers.on_load_model_config(:arg1, :arg2)
      assert %{api_key: "test", timeout: 30} = result
    end
  end

  describe "on_load_models_config/0" do
    test "deep-merges map results" do
      Callbacks.register(:load_models_config, fn -> %{model_a: %{type: "gpt"}} end)
      Callbacks.register(:load_models_config, fn -> %{model_b: %{type: "claude"}} end)

      result = Triggers.on_load_models_config()
      assert %{model_a: %{type: "gpt"}, model_b: %{type: "claude"}} = result
    end
  end

  describe "on_get_model_system_prompt/3" do
    test "triggers callback with model info" do
      Callbacks.register(:get_model_system_prompt, fn _name, prompt, _user ->
        %{instructions: prompt <> " +extra", handled: true}
      end)

      result = Triggers.on_get_model_system_prompt("gpt-4", "base prompt", "user msg")
      # noop merge returns single value
      assert %{instructions: "base prompt +extra", handled: true} = result
    end

    test "chains callbacks — second receives updated instructions from first" do
      Callbacks.register(:get_model_system_prompt, fn _name, prompt, user ->
        %{instructions: prompt <> " +plugin1", user_prompt: user <> " +u1", handled: true}
      end)

      Callbacks.register(:get_model_system_prompt, fn _name, prompt, user ->
        %{instructions: prompt <> " +plugin2", user_prompt: user <> " +u2", handled: true}
      end)

      result = Triggers.on_get_model_system_prompt("gpt-4", "base", "hello")
      # noop merge with multiple callbacks returns list
      assert is_list(result)

      assert Enum.any?(result, fn r ->
               r[:instructions] == "base +plugin1" and r[:user_prompt] == "hello +u1"
             end)

      assert Enum.any?(result, fn r ->
               r[:instructions] == "base +plugin1 +plugin2" and r[:user_prompt] == "hello +u1 +u2"
             end)
    end
  end

  # ── File Mutation Observer Hooks ─────────────────────────────────

  describe "file observer hooks" do
    test "on_edit_file passes args" do
      Callbacks.register(:edit_file, fn path -> {:edited, path} end)
      assert {:edited, "lib/foo.ex"} = Triggers.on_edit_file("lib/foo.ex")
    end

    test "on_create_file passes args" do
      Callbacks.register(:create_file, fn path -> {:created, path} end)
      assert {:created, "lib/bar.ex"} = Triggers.on_create_file("lib/bar.ex")
    end

    test "on_replace_in_file passes args" do
      Callbacks.register(:replace_in_file, fn path -> {:replaced, path} end)
      assert {:replaced, "lib/baz.ex"} = Triggers.on_replace_in_file("lib/baz.ex")
    end

    test "on_delete_snippet passes args" do
      Callbacks.register(:delete_snippet, fn path -> {:snippet_deleted, path} end)
      assert {:snippet_deleted, "lib/qux.ex"} = Triggers.on_delete_snippet("lib/qux.ex")
    end

    test "on_delete_file passes args" do
      Callbacks.register(:delete_file, fn path -> {:deleted, path} end)
      assert {:deleted, "lib/old.ex"} = Triggers.on_delete_file("lib/old.ex")
    end
  end

  # ── Custom Command Hooks ────────────────────────────────────────

  describe "on_custom_command/2" do
    test "passes command and name to callbacks" do
      Callbacks.register(:custom_command, fn cmd, name -> {:handled, cmd, name} end)
      assert {:handled, "/woof", "woof"} = Triggers.on_custom_command("/woof", "woof")
    end
  end

  describe "on_custom_command_help/0" do
    test "extends list results from callbacks" do
      Callbacks.register(:custom_command_help, fn -> [{:woof, "emit woof"}] end)
      Callbacks.register(:custom_command_help, fn -> [{:bark, "emit bark"}] end)

      result = Triggers.on_custom_command_help()
      assert [{:woof, "emit woof"}, {:bark, "emit bark"}] = result
    end
  end

  # ── Tool Call Hooks ──────────────────────────────────────────────

  describe "on_pre_tool_call/3" do
    test "triggers async callback" do
      Callbacks.register(:pre_tool_call, fn _name, _args, _ctx -> :approved end)
      assert {:ok, :approved} == Triggers.on_pre_tool_call("read_file", %{}, nil)
    end
  end

  describe "on_post_tool_call/5" do
    test "triggers async callback with result and duration" do
      test_pid = self()

      Callbacks.register(:post_tool_call, fn name, _args, result, dur, _ctx ->
        send(test_pid, {:post, name, result, dur})
        :ok
      end)

      assert {:ok, :ok} == Triggers.on_post_tool_call("read_file", %{}, "contents", 42.5)
      assert_received {:post, "read_file", "contents", 42.5}
    end
  end

  # ── Stream / Event Hooks ────────────────────────────────────────

  describe "on_stream_event/3" do
    test "triggers async callback" do
      Callbacks.register(:stream_event, fn _type, _data, _sid -> :streamed end)
      assert {:ok, :streamed} == Triggers.on_stream_event("token", %{}, "sess-1")
    end
  end

  describe "on_version_check/1" do
    test "triggers async callback" do
      Callbacks.register(:version_check, fn _ -> :checked end)
      assert {:ok, :checked} == Triggers.on_version_check(%{})
    end
  end

  # ── Registration Hooks ──────────────────────────────────────────

  describe "registration hooks" do
    test "on_register_tools extends lists" do
      Callbacks.register(:register_tools, fn -> [%{name: "my_tool"}] end)
      Callbacks.register(:register_tools, fn -> [%{name: "other_tool"}] end)

      result = Triggers.on_register_tools()
      assert [%{name: "my_tool"}, %{name: "other_tool"}] = result
    end

    test "on_register_agents extends lists" do
      Callbacks.register(:register_agents, fn -> [%{name: "puppy"}] end)
      assert [%{name: "puppy"}] = Triggers.on_register_agents()
    end

    test "on_register_model_type extends lists" do
      Callbacks.register(:register_model_type, fn -> [%{type: "custom"}] end)
      assert [%{type: "custom"}] = Triggers.on_register_model_type()
    end

    test "on_register_model_types/0 delegates to on_register_model_type/0" do
      Callbacks.register(:register_model_type, fn -> [%{type: "custom"}] end)
      assert Triggers.on_register_model_types() == Triggers.on_register_model_type()
    end

    test "on_register_mcp_catalog_servers extends lists" do
      Callbacks.register(:register_mcp_catalog_servers, fn -> [%{name: "my_server"}] end)
      assert [%{name: "my_server"}] = Triggers.on_register_mcp_catalog_servers()
    end

    test "on_register_browser_types extends lists" do
      Callbacks.register(:register_browser_types, fn -> [%{name: "stealth"}] end)
      assert [%{name: "stealth"}] = Triggers.on_register_browser_types()
    end

    test "on_register_model_providers extends lists" do
      Callbacks.register(:register_model_providers, fn -> [%{name: "walmart"}] end)
      assert [%{name: "walmart"}] = Triggers.on_register_model_providers()
    end

    test "on_get_motd returns results from callbacks" do
      Callbacks.register(:get_motd, fn -> {"Welcome!", "1.0"} end)
      assert {"Welcome!", "1.0"} = Triggers.on_get_motd()
    end

    test "on_get_motd with multiple callbacks returns list" do
      Callbacks.register(:get_motd, fn -> {"Welcome!", "1.0"} end)
      Callbacks.register(:get_motd, fn -> {"New msg!", "2.0"} end)
      result = Triggers.on_get_motd()
      assert is_list(result)
      assert {"Welcome!", "1.0"} in result
      assert {"New msg!", "2.0"} in result
    end
  end

  # ── Message History Processor Hooks ─────────────────────────────

  describe "on_message_history_processor_start/4" do
    test "triggers async callback with all args" do
      test_pid = self()

      Callbacks.register(:message_history_processor_start, fn name, sid, hist, incoming ->
        send(test_pid, {:mhps, name, sid, length(hist), length(incoming)})
        :ok
      end)

      assert {:ok, :ok} == Triggers.on_message_history_processor_start("puppy", "s1", [1, 2], [3])
      assert_received {:mhps, "puppy", "s1", 2, 1}
    end
  end

  describe "on_message_history_processor_end/5" do
    test "triggers async callback with all args" do
      test_pid = self()

      Callbacks.register(:message_history_processor_end, fn name, sid, hist, added, filtered ->
        send(test_pid, {:mhpe, name, sid, length(hist), added, filtered})
        :ok
      end)

      assert {:ok, :ok} ==
               Triggers.on_message_history_processor_end("puppy", "s1", [1, 2, 3], 2, 1)

      assert_received {:mhpe, "puppy", "s1", 3, 2, 1}
    end
  end

  # ── Thin Security Trigger Wrappers ──────────────────────────────

  describe "on_file_permission/6 (thin trigger)" do
    test "triggers async callback" do
      Callbacks.register(:file_permission, fn _ctx, _path, _op, _, _, _ -> true end)
      assert {:ok, true} == Triggers.on_file_permission(%{}, "test.ex", "create")
    end
  end

  describe "on_run_shell_command/3 (thin trigger)" do
    test "triggers async callback" do
      Callbacks.register(:run_shell_command, fn _ctx, _cmd, _cwd -> %{blocked: false} end)
      assert {:ok, %{blocked: false}} == Triggers.on_run_shell_command(%{}, "echo hi")
    end
  end

  # ── Error Handling ──────────────────────────────────────────────

  describe "callback failure in typed trigger" do
    test "on_startup handles crashed callback" do
      Callbacks.register(:startup, fn -> raise "boom" end)
      # :noop merge with single crashed callback returns :callback_failed
      assert :callback_failed = Triggers.on_startup()
    end

    test "on_load_prompt filters crashed callback" do
      Callbacks.register(:load_prompt, fn -> "good" end)
      Callbacks.register(:load_prompt, fn -> raise "bad" end)
      # :concat_str merge filters :callback_failed
      assert "good" = Triggers.on_load_prompt()
    end

    test "on_register_tools filters crashed callback" do
      Callbacks.register(:register_tools, fn -> [%{name: "a"}] end)
      Callbacks.register(:register_tools, fn -> raise "oops" end)
      # :extend_list merge filters :callback_failed
      assert [%{name: "a"}] = Triggers.on_register_tools()
    end
  end
end
