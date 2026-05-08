defmodule CodePuppyControl.HookEngine.IntegrationTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.HookEngine
  alias CodePuppyControl.HookEngine.Models.{EventData, HookConfig}
  alias CodePuppyControl.HookEngine.CallbackAdapter
  alias CodePuppyControl.Callbacks

  @engine_name __MODULE__.TestEngine

  setup do
    # (code_puppy-i1n) Ensure Callbacks.Registry is alive — it's a supervised
    # singleton that may be dead if a prior test killed the supervisor tree.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Callbacks.Registry
    )

    # Start a fresh HookEngine for each test
    {:ok, pid} = HookEngine.start_link(name: @engine_name, strict_validation: false)
    Callbacks.clear(:pre_tool_call)
    Callbacks.clear(:post_tool_call)

    # Clean up adapter ETS if left from a prior test
    try do
      :ets.delete(:hook_engine_callback_adapter)
    catch
      _, _ -> :ok
    end

    on_exit(fn ->
      # Safely stop the engine — it may already be dead
      case Process.whereis(@engine_name) do
        nil ->
          :ok

        _pid ->
          try do
            GenServer.stop(@engine_name, :normal, 1000)
          catch
            :exit, _ -> :ok
          end
      end

      Callbacks.clear(:pre_tool_call)
      Callbacks.clear(:post_tool_call)

      try do
        :ets.delete(:hook_engine_callback_adapter)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, engine: @engine_name, pid: pid}
  end

  describe "HookEngine GenServer lifecycle" do
    test "starts with empty registry", %{engine: engine} do
      assert HookEngine.count_hooks(engine) == 0
    end

    test "loads config and counts hooks", %{engine: engine} do
      config = %{
        "PreToolUse" => [
          %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "echo hi"}]}
        ]
      }

      assert :ok = HookEngine.load_config(engine, config)
      assert HookEngine.count_hooks(engine) == 1
    end

    test "returns error for invalid config with strict mode" do
      strict_name = :strict_test_engine_
      result = HookEngine.start_link(strict_validation: true, name: strict_name)

      case result do
        {:ok, pid} ->
          result = HookEngine.load_config(strict_name, %{"BadType" => []})
          assert {:error, _msg} = result
          GenServer.stop(pid, :normal, 1000)

        {:error, _} ->
          :ok
      end
    end

    test "reloads config replacing previous hooks", %{engine: engine} do
      config1 = %{
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "echo 1"}]}
        ]
      }

      config2 = %{
        "PostToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "echo 2"}]}
        ]
      }

      :ok = HookEngine.load_config(engine, config1)
      assert HookEngine.count_hooks(engine, "PreToolUse") == 1

      :ok = HookEngine.load_config(engine, config2)
      # Old config should be replaced
      assert HookEngine.count_hooks(engine, "PreToolUse") == 0
      assert HookEngine.count_hooks(engine, "PostToolUse") == 1
    end
  end

  describe "process_event/4" do
    test "returns empty result when no hooks configured", %{engine: engine} do
      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")
      result = HookEngine.process_event(engine, "PreToolUse", event_data)

      assert result.blocked == false
      assert result.executed_hooks == 0
    end

    test "executes matching hook and returns results", %{engine: engine} do
      config = %{
        "PreToolUse" => [
          %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "echo test_ok"}]}
        ]
      }

      :ok = HookEngine.load_config(engine, config)

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "agent_run_shell_command")
      result = HookEngine.process_event(engine, "PreToolUse", event_data)

      assert result.blocked == false
      assert result.executed_hooks == 1
      assert String.contains?(hd(result.results).stdout, "test_ok")
    end

    test "blocking hook sets blocked=true", %{engine: engine} do
      config = %{
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "exit 1"}]}
        ]
      }

      :ok = HookEngine.load_config(engine, config)

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")
      result = HookEngine.process_event(engine, "PreToolUse", event_data)

      assert result.blocked == true
      assert result.blocking_reason != nil
    end

    test "non-matching hooks are skipped", %{engine: engine} do
      config = %{
        "PreToolUse" => [
          %{"matcher" => "Read", "hooks" => [%{"type" => "command", "command" => "echo nope"}]}
        ]
      }

      :ok = HookEngine.load_config(engine, config)

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")
      result = HookEngine.process_event(engine, "PreToolUse", event_data)

      assert result.executed_hooks == 0
    end

    test "parallel execution mode", %{engine: engine} do
      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "*",
            "hooks" => [
              %{"type" => "command", "command" => "echo alpha"},
              %{"type" => "command", "command" => "echo beta"}
            ]
          }
        ]
      }

      :ok = HookEngine.load_config(engine, config)

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")
      result = HookEngine.process_event(engine, "PreToolUse", event_data, sequential: false)

      assert result.executed_hooks == 2
    end
  end

  describe "add_hook/3 with deduplication" do
    test "adding same hook twice is a no-op", %{engine: engine} do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo dup", id: "dedup-test")

      assert :ok = HookEngine.add_hook(engine, "PreToolUse", hook)
      assert :duplicate = HookEngine.add_hook(engine, "PreToolUse", hook)
      assert HookEngine.count_hooks(engine, "PreToolUse") == 1
    end
  end

  describe "remove_hook/3" do
    test "removes a hook", %{engine: engine} do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo rm")
      :ok = HookEngine.add_hook(engine, "PreToolUse", hook)

      assert true = HookEngine.remove_hook(engine, "PreToolUse", hook.id)
      assert HookEngine.count_hooks(engine, "PreToolUse") == 0
    end
  end

  describe "once hooks" do
    test "once hooks are executed only once", %{engine: engine} do
      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "*",
            "hooks" => [%{"type" => "command", "command" => "echo once", "once" => true}]
          }
        ]
      }

      :ok = HookEngine.load_config(engine, config)

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")

      # First call — should execute
      result1 = HookEngine.process_event(engine, "PreToolUse", event_data)
      assert result1.executed_hooks == 1

      # Second call — once hook should be skipped
      result2 = HookEngine.process_event(engine, "PreToolUse", event_data)
      assert result2.executed_hooks == 0
    end

    test "reset_once_hooks allows re-execution", %{engine: engine} do
      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "*",
            "hooks" => [%{"type" => "command", "command" => "echo once", "once" => true}]
          }
        ]
      }

      :ok = HookEngine.load_config(engine, config)

      event_data = EventData.new(event_type: "PreToolUse", tool_name: "Bash")
      _result = HookEngine.process_event(engine, "PreToolUse", event_data)

      :ok = HookEngine.reset_once_hooks(engine)

      result = HookEngine.process_event(engine, "PreToolUse", event_data)
      assert result.executed_hooks == 1
    end
  end

  describe "update_env_vars/2" do
    test "updates environment variables", %{engine: engine} do
      :ok = HookEngine.update_env_vars(engine, %{"MY_VAR" => "hello"})
      # Just verify it doesn't crash — env vars are used during execution
      assert :ok = HookEngine.update_env_vars(engine, %{"ANOTHER" => "world"})
    end
  end

  describe "get_stats/1" do
    test "returns stats for loaded registry", %{engine: engine} do
      config = %{
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "echo st"}]}
        ]
      }

      :ok = HookEngine.load_config(engine, config)
      stats = HookEngine.get_stats(engine)
      assert stats.total_hooks == 1
    end
  end

  describe "CallbackAdapter integration" do
    test "registers as pre_tool_call callback" do
      assert :ok = CallbackAdapter.register(@engine_name)
    end

    test "handle_pre_tool_call returns nil when not blocked" do
      result = CallbackAdapter.handle_pre_tool_call(@engine_name, "Bash", %{})
      assert result == nil
    end

    test "handle_pre_tool_call returns blocked when hook blocks" do
      config = %{
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "exit 1"}]}
        ]
      }

      :ok = HookEngine.load_config(@engine_name, config)

      result = CallbackAdapter.handle_pre_tool_call(@engine_name, "Bash", %{})
      assert result != nil
      assert result.blocked == true
      assert is_binary(result.reason)
    end

    test "handle_post_tool_call always returns nil" do
      result = CallbackAdapter.handle_post_tool_call(@engine_name, "Bash", %{}, "ok", 42)
      assert result == nil
    end

    test "adapter recovers from errors gracefully (fail-open)" do
      result = CallbackAdapter.handle_pre_tool_call(:nonexistent_engine, "Bash", %{})
      assert result == nil
    end

    test "post_tool_call includes result and duration in context" do
      # Load a hook that can read the stdin JSON (which includes context)
      config = %{
        "PostToolUse" => [
          %{
            "matcher" => "*",
            "hooks" => [
              %{
                "type" => "command",
                "command" =>
                  "cat | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(\"tool_result\", \"MISSING\"))'"
              }
            ]
          }
        ]
      }

      :ok = HookEngine.load_config(@engine_name, config)

      event_data =
        EventData.new(
          event_type: "PostToolUse",
          tool_name: "Bash",
          tool_args: %{},
          context: %{"result" => "test_result", "duration_ms" => 150}
        )

      result = HookEngine.process_event(@engine_name, "PostToolUse", event_data)
      assert result.executed_hooks == 1
      assert String.contains?(hd(result.results).stdout, "test_result")
    end
  end

  describe "CallbackAdapter idempotency" do
    test "repeated register/1 does not create duplicate callbacks" do
      # Register twice
      assert :ok = CallbackAdapter.register(@engine_name)
      assert :ok = CallbackAdapter.register(@engine_name)

      pre_callbacks = Callbacks.get_callbacks(:pre_tool_call)
      post_callbacks = Callbacks.get_callbacks(:post_tool_call)

      # Should have exactly one pre and one post callback from the adapter
      assert length(pre_callbacks) == 1
      assert length(post_callbacks) == 1
    end

    test "repeated register/1 does not cause duplicate execution" do
      # Register twice
      :ok = CallbackAdapter.register(@engine_name)
      :ok = CallbackAdapter.register(@engine_name)

      # Load a hook that produces observable output
      config = %{
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "echo idempotent"}]}
        ]
      }

      :ok = HookEngine.load_config(@engine_name, config)

      # Trigger the callback via Callbacks.trigger
      results = Callbacks.trigger_raw(:pre_tool_call, ["Bash", %{}, nil])

      # Should be exactly one result (not duplicated)
      assert length(results) == 1
      # The result should be nil (hook didn't block)
      assert hd(results) == nil
    end

    test "engine reference is updated on re-register" do
      # Register with first engine
      :ok = CallbackAdapter.register(@engine_name)

      # Verify engine ref stored
      assert CallbackAdapter.get_engine_ref() == @engine_name

      # Register with a different engine name
      other_name = :other_engine_for_idempotency_test

      # Start another engine
      {:ok, _pid} = HookEngine.start_link(name: other_name, strict_validation: false)

      :ok = CallbackAdapter.register(other_name)

      # Engine ref should now point to the new engine
      assert CallbackAdapter.get_engine_ref() == other_name

      # And still only one callback registered
      assert length(Callbacks.get_callbacks(:pre_tool_call)) == 1

      GenServer.stop(other_name, :normal, 1000)
    end

    test "stable function captures compare equal" do
      # Verify that named function captures are equal across evaluations
      f1 = &CallbackAdapter.pre_tool_callback/3
      f2 = &CallbackAdapter.pre_tool_callback/3
      assert f1 == f2

      g1 = &CallbackAdapter.post_tool_callback/5
      g2 = &CallbackAdapter.post_tool_callback/5
      assert g1 == g2
    end
  end

  describe "CallbackAdapter end-to-end through Callbacks" do
    test "pre_tool_call through Callbacks reaches HookEngine" do
      :ok = CallbackAdapter.register(@engine_name)

      config = %{
        "PreToolUse" => [
          %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "echo hooked"}]}
        ]
      }

      :ok = HookEngine.load_config(@engine_name, config)

      # Trigger via the Callbacks system (not directly)
      results = Callbacks.trigger_raw(:pre_tool_call, ["Bash", %{}, nil])

      # Should have one result from the adapter
      assert length(results) == 1
      assert hd(results) == nil
    end

    test "post_tool_call through Callbacks reaches HookEngine" do
      :ok = CallbackAdapter.register(@engine_name)

      config = %{
        "PostToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "echo post_hook"}]}
        ]
      }

      :ok = HookEngine.load_config(@engine_name, config)

      # Trigger via the Callbacks system
      results = Callbacks.trigger_raw(:post_tool_call, ["Bash", %{}, "result", 100, nil])

      # Post hooks don't block, so adapter returns nil
      assert length(results) == 1
      assert hd(results) == nil
    end

    test "blocking pre_tool_call returns %{blocked: true} through Callbacks" do
      :ok = CallbackAdapter.register(@engine_name)

      config = %{
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "exit 1"}]}
        ]
      }

      :ok = HookEngine.load_config(@engine_name, config)

      # Trigger via the Callbacks system
      results = Callbacks.trigger_raw(:pre_tool_call, ["Bash", %{}, nil])

      assert length(results) == 1
      result = hd(results)
      assert result.blocked == true
    end
  end

  describe "CallbackAdapter supervision/restart resilience" do
    test "adapter uses registered name, survives engine restart" do
      :ok = CallbackAdapter.register(@engine_name)

      # Kill the engine
      GenServer.stop(@engine_name, :normal, 1000)

      # Engine is dead — adapter should fail-open
      result = CallbackAdapter.handle_pre_tool_call(@engine_name, "Bash", %{})
      assert result == nil

      # Restart the engine with the same name
      {:ok, _pid} = HookEngine.start_link(name: @engine_name, strict_validation: false)

      # Adapter should work again because it references by name
      result2 = CallbackAdapter.handle_pre_tool_call(@engine_name, "Bash", %{})
      assert result2 == nil

      # Load a blocking config and verify it works
      config = %{
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "exit 1"}]}
        ]
      }

      :ok = HookEngine.load_config(@engine_name, config)

      result3 = CallbackAdapter.handle_pre_tool_call(@engine_name, "Bash", %{})
      assert result3.blocked == true
    end
  end
end
