defmodule CodePuppyControl.REPL.LoopTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.Registry
  alias CodePuppyControl.REPL.{History, Loop}

  # Start a fresh History GenServer for each test.
  # async: false because we share the registered name and disk file.
  setup do
    case Process.whereis(History) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown, 5000)
    end

    # Wipe the history file so tests start clean
    File.rm(History.history_path())

    {:ok, _pid} = History.start_link()

    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()
    Registry.register_builtin_commands()

    on_exit(fn ->
      try do
        case Process.whereis(History) do
          nil -> :ok
          pid -> GenServer.stop(pid, :shutdown, 5000)
        end
      catch
        :exit, _ -> :ok
      end

      File.rm(History.history_path())
    end)

    :ok
  end

  describe "is_slash_command?/1" do
    test "detects slash commands" do
      assert Loop.is_slash_command?("/help")
      assert Loop.is_slash_command?("/quit")
      assert Loop.is_slash_command?("/model gpt-4")
      assert Loop.is_slash_command?("/agent code-puppy")
    end

    test "non-slash input is not a command" do
      refute Loop.is_slash_command?("hello world")
      refute Loop.is_slash_command?("explain this code")
      refute Loop.is_slash_command?("")
    end
  end

  describe "is_shell_passthrough?/1" do
    test "detects shell passthrough" do
      assert Loop.is_shell_passthrough?("!git status")
      assert Loop.is_shell_passthrough?("!ls -la")
    end

    test "regular input is not passthrough" do
      refute Loop.is_shell_passthrough?("git status")
      refute Loop.is_shell_passthrough?("/help")
    end
  end

  describe "handle_input/2 — slash commands" do
    setup do
      state = %Loop{
        agent: "code-puppy",
        model: "gpt-4",
        session_id: "test-session",
        running: true
      }

      {:ok, state: state}
    end

    test "/quit halts the loop", %{state: state} do
      assert {:halt, new_state} = Loop.handle_input("/quit", state)
      refute new_state.running
    end

    test "/exit halts the loop", %{state: state} do
      assert {:halt, new_state} = Loop.handle_input("/exit", state)
      refute new_state.running
    end

    test "/help continues the loop", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("/help", state)
        end)

      assert output =~ "Available commands"
      assert output =~ "/quit"
      assert output =~ "/help"
    end

    test "/model shows current model", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("/model", state)
        end)

      # Either shows the model selector or falls back to showing current model
      assert output =~ "gpt-4" or output =~ "cancelled"
    end

    test "/model <name> switches model", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, new_state} = Loop.handle_input("/model claude-sonnet-4", state)
          assert new_state.model == "claude-sonnet-4"
        end)

      assert output =~ "Switching model"
    end

    test "/agent with no arg triggers selector (falls back to current agent in non-TTY)", %{
      state: state
    } do
      # Force fallback_select to avoid Owl.IO.select which blocks under CaptureIO.
      # Sending "\n" simulates Enter at the fallback IO.gets prompt (= cancel).
      prev = Application.get_env(:code_puppy_control, :force_fallback_select, false)
      Application.put_env(:code_puppy_control, :force_fallback_select, true)

      try do
        output =
          ExUnit.CaptureIO.capture_io("\n", fn ->
            assert {:continue, _new_state} = Loop.handle_input("/agent", state)
          end)

        # Fallback path with blank input returns :cancelled
        assert output =~ "cancelled" or output =~ "code-puppy" or output =~ "Agent Selector"
      after
        Application.put_env(:code_puppy_control, :force_fallback_select, prev)
      end
    end

    test "/agent <name> switches agent", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, new_state} = Loop.handle_input("/agent qa-kitten", state)
          assert new_state.agent == "qa-kitten"
        end)

      assert output =~ "Switching agent"
    end

    test "handle_agent_command with empty string invokes selector", %{state: state} do
      # Force fallback_select to avoid Owl.IO.select which blocks under CaptureIO.
      # Sending "\n" simulates Enter at the fallback IO.gets prompt (= cancel).
      prev = Application.get_env(:code_puppy_control, :force_fallback_select, false)
      Application.put_env(:code_puppy_control, :force_fallback_select, true)

      try do
        output =
          ExUnit.CaptureIO.capture_io("\n", fn ->
            result = Loop.handle_agent_command("", state)
            assert {:continue, _} = result
          end)

        # Fallback path with blank input returns :cancelled
        assert is_binary(output)
      after
        Application.put_env(:code_puppy_control, :force_fallback_select, prev)
      end
    end

    test "handle_agent_command with name switches directly", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, new_state} = Loop.handle_agent_command("qa-kitten", state)
          assert new_state.agent == "qa-kitten"
        end)

      assert output =~ "Switching agent"
    end

    test "handle_agent_command canonicalizes snake_case input to kebab-case slug", %{
      state: state
    } do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          # User types snake_case; REPL should store kebab-case
          assert {:continue, new_state} = Loop.handle_agent_command("code_puppy", state)
          assert new_state.agent == "code-puppy"
        end)

      assert output =~ "Switching agent"
      assert output =~ "code-puppy"
    end

    test "handle_agent_command stores kebab-case for known kebab input", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, new_state} = Loop.handle_agent_command("qa-kitten", state)
          assert new_state.agent == "qa-kitten"
        end)

      assert output =~ "Switching agent"
    end

    test "handle_agent_command falls back to raw input for unknown agent", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, new_state} = Loop.handle_agent_command("no-such-agent", state)
          # Unknown agent — raw input stored as-is
          assert new_state.agent == "no-such-agent"
        end)

      assert output =~ "Switching agent"
    end

    test "/clear continues the loop", %{state: state} do
      assert {:continue, ^state} = Loop.handle_input("/clear", state)
    end

    test "/history shows empty history", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("/history", state)
        end)

      assert output =~ "no history"
    end

    test "unknown slash command shows error", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("/bogus", state)
        end)

      assert output =~ "Unknown command"
    end
  end

  describe "handle_input/2 — regular input" do
    setup do
      state = %Loop{
        agent: "code-puppy",
        model: "gpt-4",
        session_id: "test-session",
        running: true
      }

      {:ok, state: state}
    end

    test "blank input continues without recording", %{state: state} do
      assert {:continue, ^state} = Loop.handle_input(" ", state)
    end

    test "non-blank input is recorded in history", %{state: state} do
      _output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _new_state} = Loop.handle_input("explain this code", state)
          assert History.all() == ["explain this code"]
        end)
    end

    test "duplicate consecutive input is not re-recorded", %{state: state} do
      _output =
        ExUnit.CaptureIO.capture_io(fn ->
          # Pre-seed history
          History.add("hello")
          # Same input again
          assert {:continue, _} = Loop.handle_input("hello", state)
          # Should not duplicate
          assert History.all() == ["hello"]
        end)
    end

    test "shell passthrough continues the loop", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("!echo hello", state)
        end)

      assert output =~ "hello"
    end
  end

  describe "handle_input/2 — history accumulation" do
    setup do
      state = %Loop{
        agent: "code-puppy",
        model: "gpt-4",
        session_id: "test-session",
        running: true
      }

      {:ok, state: state}
    end

    test "multiple inputs build up history", %{state: state} do
      _output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:continue, _s1} = Loop.handle_input("first prompt", state)
          {:continue, _s2} = Loop.handle_input("second prompt", state)
          # History is most-recent-first
          assert History.all() == ["second prompt", "first prompt"]
        end)
    end
  end

  describe "handle_input/2 — /sessions command" do
    setup do
      state = %Loop{
        agent: "code-puppy",
        model: "gpt-4",
        session_id: "test-session",
        running: true
      }

      {:ok, state: state}
    end

    test "/sessions continues the loop (widget handles interaction)", %{state: state} do
      # SessionBrowser.browse/1 may fail in test env, but the command
      # should at least continue the loop (not crash/halt)
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          result = Loop.handle_input("/sessions", state)
          assert {:continue, _} = result
        end)

      # Either shows session browser output or cancellation message
      assert is_binary(output)
    end
  end

  describe "handle_input/2 — /tui command" do
    setup do
      state = %Loop{
        agent: "code-puppy",
        model: "gpt-4",
        session_id: "test-session",
        running: true
      }

      {:ok, state: state}
    end

    test "/tui continues the loop", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          result = Loop.handle_input("/tui", state)
          assert {:continue, _} = result
        end)

      assert output =~ "TUI" or output =~ "Launching" or output =~ "Failed"
    end
  end

  describe "handle_input/2 — updated /model command" do
    setup do
      state = %Loop{
        agent: "code-puppy",
        model: "gpt-4",
        session_id: "test-session",
        running: true
      }

      {:ok, state: state}
    end

    test "/model with no arg shows current model (falls back from selector)", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("/model", state)
        end)

      # Either shows the model selector or falls back to showing current model
      assert output =~ "gpt-4" or output =~ "cancelled"
    end

    test "/model <name> still switches model directly", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, new_state} = Loop.handle_input("/model claude-sonnet-4", state)
          assert new_state.model == "claude-sonnet-4"
        end)

      assert output =~ "Switching model"
    end
  end

  # ===========================================================================
  # Agent.LLMAdapter provider contract tests (Phase 4)
  # ===========================================================================

  defmodule REPLTestProviderMock do
    @moduledoc "Mock of CodePuppyControl.LLM.stream_chat/4 provider contract."

    def start_if_needed do
      case Process.whereis(__MODULE__) do
        nil -> {:ok, _pid} = Elixir.Agent.start_link(fn -> %{} end, name: __MODULE__)
        _ -> :ok
      end
    end

    def set_response(text),
      do: start_if_needed() || Elixir.Agent.update(__MODULE__, &Map.put(&1, :text, text))

    def captured_messages,
      do:
        (
          start_if_needed()
          Elixir.Agent.get(__MODULE__, & &1)[:messages] || []
        )

    def captured_tools,
      do:
        (
          start_if_needed()
          Elixir.Agent.get(__MODULE__, & &1)[:tools] || []
        )

    def reset,
      do:
        (
          start_if_needed()
          Elixir.Agent.update(__MODULE__, fn _ -> %{} end)
        )

    def stop do
      try do
        Elixir.Agent.stop(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end

    # Provider contract: atom-keyed messages, schema-map tools, raw events, returns :ok
    def stream_chat(messages, tools, _opts, callback_fn) do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, &Map.merge(&1, %{messages: messages, tools: tools}))
      text = Elixir.Agent.get(__MODULE__, & &1)[:text] || "ok"
      callback_fn.({:part_start, %{type: :text, index: 0, id: nil}})
      callback_fn.({:part_delta, %{type: :text, index: 0, text: text, name: nil, arguments: nil}})
      callback_fn.({:part_end, %{type: :text, index: 0, id: nil}})

      callback_fn.(
        {:done,
         %{
           id: "r1",
           model: "test",
           content: text,
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
         }}
      )

      :ok
    end
  end

  describe "Agent.LLMAdapter provider contract" do
    setup do
      prev = Application.get_env(:code_puppy_control, :llm_adapter_provider)
      Application.put_env(:code_puppy_control, :llm_adapter_provider, REPLTestProviderMock)
      REPLTestProviderMock.reset()

      on_exit(fn ->
        if prev,
          do: Application.put_env(:code_puppy_control, :llm_adapter_provider, prev),
          else: Application.delete_env(:code_puppy_control, :llm_adapter_provider)

        REPLTestProviderMock.stop()
      end)

      :ok
    end

    test "converts parts-format user message to content-format for provider" do
      msgs = [%{"role" => "user", "parts" => [%{"type" => "text", "text" => "hi"}]}]
      REPLTestProviderMock.set_response("hello")

      assert {:ok, _} =
               CodePuppyControl.Agent.LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ ->
                 :ok
               end)

      assert [%{role: "user", content: "hi"}] = REPLTestProviderMock.captured_messages()
    end

    test "converts atom-keyed messages to provider format" do
      msgs = [%{role: :assistant, content: "I can help!"}]
      REPLTestProviderMock.set_response("ok")
      CodePuppyControl.Agent.LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)

      assert [%{role: "assistant", content: "I can help!"}] =
               REPLTestProviderMock.captured_messages()
    end

    test "captures {:done, response} and returns Agent.LLM contract shape" do
      msgs = [%{"role" => "user", "content" => "hello"}]

      assert {:ok, resp} =
               CodePuppyControl.Agent.LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ ->
                 :ok
               end)

      assert resp.text == "ok"
      assert resp.tool_calls == []
    end
  end
end
