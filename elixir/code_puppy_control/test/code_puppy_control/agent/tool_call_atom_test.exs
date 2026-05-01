defmodule CodePuppyControl.Agent.ToolCallAtomTest do
  @moduledoc """
  Regression tests for : provider-emitted tool call names must be
  safely converted from strings to atoms without introducing atom-leak risk.

  The bug: providers return tool call names as strings (e.g. "command_runner"),
  but Agent.Loop allowed_tools and Tool.Runner require atoms. The string→atom
  conversion must only produce atoms that already exist (registered tools),
  never call String.to_atom/1 on untrusted input.

  Three layers are tested:
    1. LLMAdapter.normalize_tool_call — safe_atomize converts known strings
    2. Agent.Loop.dispatch_tool_calls — resolve_tool_name matches against allowed
    3. Tool.Runner.invoke — string names resolved via String.to_existing_atom/1
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.LLMAdapter
  alias CodePuppyControl.Agent.Loop
  alias CodePuppyControl.Tool.{Registry, Runner}

  # ── Stub tool for Registry-based tests ──────────────────────────────────

  defmodule AtomFixTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :atom_fix_tool

    @impl true
    def description, do: "A tool for testing atom fix"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string", "description" => "Input"}
        },
        "required" => ["input"]
      }
    end

    @impl true
    def invoke(%{"input" => input}, _ctx), do: {:ok, "fixed: #{input}"}
  end

  # ── Mock LLM provider (CodePuppyControl.LLM contract) ────────────────────

  defmodule ProviderMock do
    @moduledoc "Configurable mock for the LLM provider layer."

    def start_if_needed do
      case Process.whereis(__MODULE__) do
        nil ->
          {:ok, _pid} = Elixir.Agent.start_link(fn -> %{} end, name: __MODULE__)

        _ ->
          :ok
      end
    end

    def set_response(response) do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :response, response))
    end

    def reset do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, fn _ -> %{} end)
    end

    def stop do
      try do
        Elixir.Agent.stop(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end

    @doc false
    def stream_chat(messages, tools, _opts, callback_fn) do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, &Map.merge(&1, %{messages: messages, tools: tools}))

      state = Elixir.Agent.get(__MODULE__, & &1)

      if state[:response] do
        resp = state[:response]
        callback_fn.({:done, resp})
        :ok
      else
        callback_fn.({:done, %{id: "r1", content: "ok", tool_calls: [], usage: %{}}})
        :ok
      end
    end
  end

  # ── Mock LLM for Agent.Loop tests ──────────────────────────────────────

  defmodule LoopMockLLM do
    @behaviour CodePuppyControl.Agent.LLM

    def start_link do
      case Elixir.Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def set_response(response) do
      Elixir.Agent.update(__MODULE__, fn _ -> %{response: response} end)
    end

    def stop do
      try do
        Elixir.Agent.stop(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end

    @impl true
    def stream_chat(_messages, _tools, _opts, callback_fn) do
      response = Elixir.Agent.get(__MODULE__, fn state -> state.response end)

      case response do
        %{text: text, tool_calls: tool_calls} when is_list(tool_calls) ->
          if text, do: callback_fn.({:text, text})

          for tc <- tool_calls do
            callback_fn.({:tool_call, tc.name, tc.arguments, tc.id})
          end

        %{text: text} when is_binary(text) ->
          callback_fn.({:text, text})

        _ ->
          :ok
      end

      callback_fn.({:done, :complete})
      {:ok, response}
    end
  end

  # ── Test agent for Loop tests ──────────────────────────────────────────

  defmodule TestAgent do
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :atom_test_agent

    @impl true
    def system_prompt(_ctx), do: "You are a test agent for atom fix."

    @impl true
    def allowed_tools, do: [:atom_fix_tool]

    @impl true
    def model_preference, do: "test-model"

    @impl true
    def on_tool_result(_tool, _result, state), do: {:cont, state}
  end

  # ── Legacy tool for Loop dispatch (Tool.EchoTool pattern) ──────────────

  defmodule Tool.AtomFixTool do
    def execute(%{"input" => input}), do: {:ok, "fixed: #{input}"}
    def execute(_), do: {:ok, "fixed"}
  end

  # ===========================================================================
  # 1. LLMAdapter: safe_atomize converts known string names to atoms
  # ===========================================================================

  describe "LLMAdapter: string tool names → atoms" do
    setup do
      # (code_puppy-i1n) Ensure Tool.Registry is alive.
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(CodePuppyControl.Tool.Registry)

      prev = Application.get_env(:code_puppy_control, :llm_adapter_provider)
      Application.put_env(:code_puppy_control, :llm_adapter_provider, ProviderMock)
      ProviderMock.reset()

      :ok = Registry.register(AtomFixTool)

      on_exit(fn ->
        if prev do
          Application.put_env(:code_puppy_control, :llm_adapter_provider, prev)
        else
          Application.delete_env(:code_puppy_control, :llm_adapter_provider)
        end

        Registry.unregister(:atom_fix_tool)
        ProviderMock.stop()
      end)
    end

    test "converts registered string tool name to atom" do
      # Provider returns string-keyed tool call with string name
      tool_calls = [%{"id" => "tc1", "name" => "atom_fix_tool", "arguments" => %{}}]
      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:atom_fix_tool],
                 [model: "test"],
                 fn _ -> :ok end
               )

      [tc] = resp.tool_calls
      # The adapter should have converted "atom_fix_tool" to :atom_fix_tool
      assert tc.name == :atom_fix_tool
    end

    test "converts atom-keyed tool call with string name to atom" do
      # Provider returns atom-keyed tool call with string name
      tool_calls = [%{id: "tc1", name: "atom_fix_tool", arguments: %{}}]
      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:atom_fix_tool],
                 [model: "test"],
                 fn _ -> :ok end
               )

      [tc] = resp.tool_calls
      assert tc.name == :atom_fix_tool
    end

    test "leaves unregistered string tool name as string (no atom leak)" do
      # Provider returns a tool name that has never been registered as an atom.
      # We use a very unlikely name that won't exist in the atom table.
      # Note: we can't test truly arbitrary strings because the test module
      # compilation itself creates atoms. Instead, verify that a string name
      # that doesn't match any registered tool stays as a string.
      tool_calls = [%{id: "tc1", name: "totally_bogus_unregistered_tool_xyz", arguments: %{}}]
      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:atom_fix_tool],
                 [model: "test"],
                 fn _ -> :ok end
               )

      [tc] = resp.tool_calls
      # Unknown string name stays as string — no String.to_atom leak
      assert is_binary(tc.name)
      assert tc.name == "totally_bogus_unregistered_tool_xyz"
    end

    test "unknown string tool name does not leak atoms (direct atom-table check)" do
      # Prove safe_atomize never creates a new atom for an unknown string.
      # We use String.to_existing_atom/1 as a probe — it raises ArgumentError
      # if the atom doesn't exist, WITHOUT creating it. This is immune to
      # concurrent VM atom creation that would make before/after atom_count
      # comparisons flaky.
      unknown = "totally_bogus_unregistered_tool_qwerty_"

      # Pre-condition: the atom must NOT exist in the atom table
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

      tool_calls = [%{id: "tc1", name: unknown, arguments: %{}}]
      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:atom_fix_tool],
                 [model: "test"],
                 fn _ -> :ok end
               )

      # Post-condition: the atom STILL must NOT exist — safe_atomize must not
      # have called String.to_atom/1 on the unknown string
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

      # Also confirm the name stayed as a string
      [tc] = resp.tool_calls
      assert is_binary(tc.name)
      assert tc.name == unknown
    end

    test "atom tool names pass through unchanged" do
      # If the provider somehow returns an atom name, it should pass through
      tool_calls = [%{id: "tc1", name: :atom_fix_tool, arguments: %{}}]
      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:atom_fix_tool],
                 [model: "test"],
                 fn _ -> :ok end
               )

      [tc] = resp.tool_calls
      assert tc.name == :atom_fix_tool
    end

    test "multiple tool calls: mix of registered and unknown names" do
      tool_calls = [
        %{id: "tc1", name: "atom_fix_tool", arguments: %{}},
        %{id: "tc2", name: "unknown_tool_abc123", arguments: %{}}
      ]

      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:atom_fix_tool],
                 [model: "test"],
                 fn _ -> :ok end
               )

      [tc1, tc2] = resp.tool_calls
      assert tc1.name == :atom_fix_tool
      assert is_binary(tc2.name)
      assert tc2.name == "unknown_tool_abc123"
    end
  end

  # ===========================================================================
  # 2. Agent.Loop: resolve_tool_name matches strings against allowed atoms
  # ===========================================================================

  describe "Agent.Loop: string tool names resolved against allowed" do
    setup do
      # (code_puppy-i1n) Ensure Tool.Registry is alive.
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(CodePuppyControl.Tool.Registry)

      {:ok, _pid} = LoopMockLLM.start_link()
      :ok = Registry.register(AtomFixTool)

      on_exit(fn ->
        LoopMockLLM.stop()
        Registry.unregister(:atom_fix_tool)
      end)
    end

    test "string tool name is resolved and dispatched correctly" do
      # LLM returns tool call with STRING name, but allowed_tools has ATOM :atom_fix_tool
      LoopMockLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-1", name: "atom_fix_tool", arguments: %{"input" => "test"}}]
      })

      run_id = "test-atom-fix-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loop.start_link(TestAgent, [],
          llm_module: LoopMockLLM,
          run_id: run_id,
          max_turns: 5,
          compaction_enabled: false
        )

      # The loop should NOT fail — the string "atom_fix_tool" should be
      # resolved to :atom_fix_tool and dispatched via Runner.
      result = Loop.run_until_done(pid, 10_000)
      assert result == :ok

      # Use get_messages/1 (returns raw message list) not get_state/1 (view map)
      messages = Loop.get_messages(pid)

      # Should have at least a tool result message (role "tool")
      tool_messages = Enum.filter(messages, fn m -> m[:role] == "tool" or m["role"] == "tool" end)
      assert length(tool_messages) >= 1, "Expected tool result message, got: #{inspect(messages)}"

      # Prove the tool actually executed successfully — the AtomFixTool
      # returns {:ok, "fixed: test"} for input "test", and format_tool_result/1
      # inspects it, so the content must contain "fixed: test".
      result_content = hd(tool_messages)[:content] || hd(tool_messages)["content"]

      assert result_content =~ "fixed: test",
             "Tool result should contain 'fixed: test', got: #{inspect(result_content)}"

      GenServer.stop(pid)
    end

    test "unknown string tool name is rejected as not-allowed" do
      # LLM returns a tool call with a string name NOT in allowed_tools
      LoopMockLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-1", name: "totally_unknown_xyz", arguments: %{}}]
      })

      run_id = "test-atom-reject-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loop.start_link(TestAgent, [],
          llm_module: LoopMockLLM,
          run_id: run_id,
          max_turns: 5,
          compaction_enabled: false
        )

      result = Loop.run_until_done(pid, 10_000)
      # Should complete (not crash), but the tool call should be rejected
      assert result == :ok

      messages = Loop.get_messages(pid)
      # Should have a tool message with "not available" error
      tool_messages =
        Enum.filter(messages, fn m ->
          role = m[:role] || m["role"]
          role == "tool"
        end)

      assert length(tool_messages) >= 1, "Expected error tool result message"
      error_msg = hd(tool_messages)
      assert error_msg[:content] =~ "not available" or error_msg["content"] =~ "not available"

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # 3. Tool.Runner: string tool names resolved via String.to_existing_atom/1
  # ===========================================================================

  describe "Tool.Runner: string tool names" do
    setup do
      # (code_puppy-i1n) Ensure Tool.Registry is alive.
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(CodePuppyControl.Tool.Registry)

      Registry.clear()
      Registry.register(AtomFixTool)

      on_exit(fn ->
        Registry.clear()
      end)
    end

    test "string name of registered tool resolves and invokes" do
      # :atom_fix_tool is registered, so String.to_existing_atom("atom_fix_tool") works
      assert {:ok, "fixed: hello"} =
               Runner.invoke("atom_fix_tool", %{"input" => "hello"}, %{run_id: "test-str"})
    end

    test "string name of unknown tool returns error without creating atom" do
      # This string has no corresponding atom in the table (very unlikely to exist)
      result = Runner.invoke("no_such_tool_xyzzy_12345", %{}, %{run_id: "test-str-err"})
      assert {:error, reason} = result
      assert String.contains?(reason, "Tool not found")
    end

    test "atom name still works as before" do
      assert {:ok, "fixed: world"} =
               Runner.invoke(:atom_fix_tool, %{"input" => "world"}, %{run_id: "test-atom"})
    end

    test "non-atom non-string name returns error" do
      assert {:error, reason} = Runner.invoke(12345, %{}, %{run_id: "test-invalid"})
      assert String.contains?(reason, "Invalid tool name")
    end
  end
end
