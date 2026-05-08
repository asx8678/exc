defmodule CodePuppyControl.REPL.SendToAgentTest do
  @moduledoc """
  Tests for send_to_agent/2 (tested via handle_input/2) and the
  Agent.LLMAdapter provider contract.

  Extracted from loop_test.exs (Phase 3 + Phase 4).
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.REPL.Loop
  alias CodePuppyControl.Tools.AgentCatalogue

  # ---------------------------------------------------------------------------
  # Mock LLM for send_to_agent/2 tests
  # ---------------------------------------------------------------------------

  defmodule REPLTestMockLLM do
    @moduledoc """
    Mock LLM module for REPL Loop send_to_agent/2 tests.

    Implements `CodePuppyControl.Agent.LLM` behaviour with controllable
    responses and error injection via an Elixir Agent process.
    """
    @behaviour CodePuppyControl.Agent.LLM

    def ensure_started do
      case Elixir.Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def set_response(response) when is_map(response) do
      ensure_started()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :response, response))
    end

    def set_error(reason) do
      ensure_started()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :error, reason))
    end

    def reset do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        _ -> Elixir.Agent.update(__MODULE__, fn _ -> %{} end)
      end
    end

    def last_opts do
      case Process.whereis(__MODULE__) do
        nil -> nil
        _ -> Elixir.Agent.get(__MODULE__, & &1)[:last_opts]
      end
    end

    def stop do
      try do
        Elixir.Agent.stop(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end

    @impl true
    def stream_chat(_messages, _tools, opts, callback_fn) do
      ensure_started()

      Elixir.Agent.update(__MODULE__, &Map.put(&1, :last_opts, opts))

      state = Elixir.Agent.get(__MODULE__, & &1)

      cond do
        state[:error] ->
          {:error, state[:error]}

        state[:response] ->
          resp = state[:response]

          if resp[:text] do
            callback_fn.({:text, resp.text})
          end

          if resp[:tool_calls] do
            for tc <- resp[:tool_calls] do
              callback_fn.({:tool_call, tc.name, tc.arguments, tc.id})
            end
          end

          callback_fn.({:done, :complete})
          {:ok, resp}

        true ->
          {:error, :no_mock_configured}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shared setup helpers
  # ---------------------------------------------------------------------------

  defp setup_mock_llm_and_session(_context) do
    # (code_puppy-i1n) Ensure Agent.State.Supervisor is alive —
    # Loop.handle_input calls ensure_agent_state_for which needs
    # the DynamicSupervisor to start child processes.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Agent.State.Supervisor
    )

    session_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    prev_llm = Application.get_env(:code_puppy_control, :repl_llm_module)
    Application.put_env(:code_puppy_control, :repl_llm_module, REPLTestMockLLM)
    REPLTestMockLLM.reset()

    try do
      AgentCatalogue.discover_agent_modules()
    catch
      _, _ -> :ok
    end

    on_exit(fn ->
      if prev_llm do
        Application.put_env(:code_puppy_control, :repl_llm_module, prev_llm)
      else
        Application.delete_env(:code_puppy_control, :repl_llm_module)
      end

      REPLTestMockLLM.stop()

      try do
        State.clear_messages(session_id, "code_puppy")
      catch
        _, _ -> :ok
      end

      # Clean up any renderer process started for this session.
      case Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id) do
        [] ->
          :ok

        [{pid, _}] ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, 1_000)
            catch
              :exit, _ -> :ok
            end
          end
      end
    end)

    state = %Loop{
      session_id: session_id,
      agent: "code_puppy",
      model: "claude-sonnet-4-20250514",
      running: true
    }

    {:ok, state: state, session_id: session_id}
  end

  # ===========================================================================
  # send_to_agent/2 tests (Phase 3)
  # ===========================================================================
  #
  # send_to_agent/2 is private, so we test it through the public
  # handle_input/2 which routes non-command, non-passthrough input to it.

  describe "send_to_agent/2 via handle_input/2 — happy path" do
    setup :setup_mock_llm_and_session

    test "dispatches prompt, streams response, persists both messages", %{
      state: state,
      session_id: session_id
    } do
      REPLTestMockLLM.set_response(%{text: "Hello, human!", tool_calls: []})

      _output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("Hi there", state)
        end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2

      assert [
               %{"role" => "user", "parts" => [%{"type" => "text", "text" => "Hi there"}]},
               %{
                 "role" => "assistant",
                 "parts" => [%{"type" => "text", "text" => "Hello, human!"}]
               }
             ] =
               messages
    end

    test "multi-turn conversation remembers first prompt", %{
      state: state,
      session_id: session_id
    } do
      REPLTestMockLLM.set_response(%{text: "First reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        Loop.handle_input("First prompt", state)
      end)

      REPLTestMockLLM.set_response(%{text: "Second reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        Loop.handle_input("Second prompt", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 4

      roles = Enum.map(messages, &Map.get(&1, "role"))
      assert roles == ["user", "assistant", "user", "assistant"]

      # Extract text from parts-based message format
      contents =
        Enum.map(messages, fn msg ->
          msg |> Map.get("parts") |> hd() |> Map.get("text")
        end)

      assert contents == ["First prompt", "First reply", "Second prompt", "Second reply"]
    end
  end

  describe "send_to_agent/2 via handle_input/2 — error paths" do
    setup :setup_mock_llm_and_session

    test "LLM error: prints error, rolls back user message, REPL continues", %{
      state: state,
      session_id: session_id
    } do
      REPLTestMockLLM.set_error(:rate_limited)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          # REPL must survive the error — handle_input returns :continue
          assert {:continue, ^state} = Loop.handle_input("Hello", state)
        end)

      # Error marker should appear in output
      assert output =~ "⚠" or output =~ "\e[31m"

      # Agent.State should be empty — the user message was rolled back
      messages = State.get_messages(session_id, "code_puppy")
      assert messages == []
    end

    test "unknown agent: prints error, does not touch Agent.State, REPL continues", %{
      session_id: session_id
    } do
      bad_state = %Loop{
        session_id: session_id,
        agent: "this-agent-does-not-exist",
        model: "claude-sonnet-4-20250514",
        running: true
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^bad_state} = Loop.handle_input("Hi", bad_state)
        end)

      assert output =~ "Unknown agent" or output =~ "⚠"

      # No messages should have been appended for this agent
      messages = State.get_messages(session_id, "this-agent-does-not-exist")
      assert messages == []
    end
  end

  describe "send_to_agent/2 via handle_input/2 — model override" do
    setup :setup_mock_llm_and_session

    test "model override from REPL state flows to llm_module.stream_chat opts", %{
      state: state
    } do
      state = %{state | model: "gpt-4o-2024-08-06"}
      REPLTestMockLLM.set_response(%{text: "ok", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        Loop.handle_input("test", state)
      end)

      # The mock records the opts it received; the :model key should match
      # the model override from the REPL state
      assert Keyword.get(REPLTestMockLLM.last_opts(), :model) == "gpt-4o-2024-08-06"
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

    def set_response(text) do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :text, text))
    end

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
