defmodule CodePuppyControl.Agent.LoopTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop

  # ---------------------------------------------------------------------------
  # Mock Agent Module
  # ---------------------------------------------------------------------------

  defmodule TestAgent do
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :test_agent

    @impl true
    def system_prompt(_ctx), do: "You are a test agent."

    @impl true
    def allowed_tools, do: [:echo_tool]

    @impl true
    def model_preference, do: "test-model"

    @impl true
    def on_tool_result(_tool, _result, state), do: {:cont, state}
  end

  # ---------------------------------------------------------------------------
  # Mock LLM Module
  # ---------------------------------------------------------------------------

  defmodule MockLLM do
    @behaviour CodePuppyControl.Agent.LLM

    def start_link do
      # Use start instead of start_link to avoid linking issues
      case Agent.start(fn -> %{response: nil, sequence: [], call_count: 0} end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def set_response(response) do
      Agent.update(__MODULE__, fn _ -> %{response: response, sequence: [], call_count: 0} end)
    end

    @doc """
    Set a sequence of responses to return on successive calls.
    Each call to stream_chat/4 pops the next response from the sequence.
    If the sequence is exhausted, falls back to the static :response.
    """
    def set_sequence(responses) when is_list(responses) do
      Agent.update(__MODULE__, fn _ -> %{response: nil, sequence: responses, call_count: 0} end)
    end

    def stop do
      try do
        Agent.stop(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end

    @impl true
    def stream_chat(messages, tools, opts, callback_fn) do
      state = Agent.get(__MODULE__, & &1)

      {response, new_state} =
        case state do
          %{sequence: [resp | rest], call_count: count} ->
            {resp, %{state | sequence: rest, call_count: count + 1}}

          %{sequence: [], response: resp} ->
            {resp, state}
        end

      Agent.update(__MODULE__, fn _ -> new_state end)

      case response do
        %{text: text} when is_binary(text) ->
          callback_fn.({:text, text})

        %{text: text, tool_calls: tool_calls} when is_list(tool_calls) ->
          if text, do: callback_fn.({:text, text})

          for tc <- tool_calls do
            callback_fn.({:tool_call, tc.name, tc.arguments, tc.id})
          end

        _ ->
          :ok
      end

      callback_fn.({:done, :complete})
      {:ok, response}
    end
  end

  # ---------------------------------------------------------------------------
  # Mock Tool — defined here so it's compiled and loadable
  # ---------------------------------------------------------------------------

  defmodule Tool.EchoTool do
    def execute(%{"input" => input}), do: {:ok, "echo: #{input}"}
    def execute(_), do: {:ok, "echo"}
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # Start (or restart) mock LLM for each test
    {:ok, _pid} = MockLLM.start_link()
    on_exit(fn -> MockLLM.stop() end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "start_link/3" do
    test "starts a loop GenServer" do
      {:ok, pid} = Loop.start_link(TestAgent, [], llm_module: MockLLM, run_id: "test-start-1")
      assert Process.alive?(pid)

      state = Loop.get_state(pid)
      assert state.run_id == "test-start-1"
      assert state.agent_module == TestAgent
      assert state.turn_number == 0
      assert state.message_count == 0
      assert state.cancelled == false
      assert state.completed == false

      GenServer.stop(pid)
    end

    test "auto-generates run_id when not provided" do
      {:ok, pid} = Loop.start_link(TestAgent, [], llm_module: MockLLM)
      state = Loop.get_state(pid)
      assert String.starts_with?(state.run_id, "agent-")
      GenServer.stop(pid)
    end
  end

  describe "run_turn/1 — text-only response" do
    test "completes a single text turn" do
      MockLLM.set_response(%{text: "Hello!", tool_calls: []})

      {:ok, pid} = Loop.start_link(TestAgent, [], llm_module: MockLLM, run_id: "test-turn-1")
      assert :ok = Loop.run_turn(pid)

      state = Loop.get_state(pid)
      assert state.turn_number == 1

      GenServer.stop(pid)
    end

    test "accumulates messages after turn" do
      MockLLM.set_response(%{text: "Hi there", tool_calls: []})

      messages = [%{role: "user", content: "hello"}]

      {:ok, pid} =
        Loop.start_link(TestAgent, messages, llm_module: MockLLM, run_id: "test-turn-2")

      :ok = Loop.run_turn(pid)

      state = Loop.get_state(pid)
      # original + assistant response
      assert state.message_count == 2

      GenServer.stop(pid)
    end
  end

  describe "run_until_done/2" do
    test "completes text-only run in one turn" do
      MockLLM.set_response(%{text: "Done!", tool_calls: []})

      {:ok, pid} = Loop.start_link(TestAgent, [], llm_module: MockLLM, run_id: "test-done-1")

      assert :ok = Loop.run_until_done(pid, 5_000)

      state = Loop.get_state(pid)
      assert state.completed == true
      assert state.turn_number == 1

      GenServer.stop(pid)
    end

    test "respects max_turns limit" do
      # Always return a tool call so we keep going
      MockLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-1", name: :echo_tool, arguments: %{"input" => "hi"}}]
      })

      {:ok, pid} =
        Loop.start_link(TestAgent, [],
          llm_module: MockLLM,
          run_id: "test-max-turns",
          max_turns: 3
        )

      assert :ok = Loop.run_until_done(pid, 10_000)

      state = Loop.get_state(pid)
      assert state.turn_number == 3

      GenServer.stop(pid)
    end
  end

  describe "cancel/1" do
    test "cancellation stops the loop" do
      # Use a response with tool calls so the loop would continue
      MockLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-1", name: :echo_tool, arguments: %{"input" => "hi"}}]
      })

      {:ok, pid} =
        Loop.start_link(TestAgent, [],
          llm_module: MockLLM,
          run_id: "test-cancel",
          max_turns: 100
        )

      # Cancel immediately, then try to run
      Loop.cancel(pid)

      # Give the cast a moment to process
      Process.sleep(50)

      result = Loop.run_until_done(pid, 5_000)
      assert {:error, :cancelled} = result

      GenServer.stop(pid)
    end
  end

  describe "event emission" do
    test "emits turn_started and turn_ended events" do
      run_id = "test-events-1"

      # Subscribe BEFORE starting the loop
      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")

      # Small delay to ensure subscription propagates
      Process.sleep(10)

      MockLLM.set_response(%{text: "Hello", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, [],
          llm_module: MockLLM,
          run_id: run_id
        )

      :ok = Loop.run_turn(pid)

      # Collect events with reasonable timeout
      events = collect_events(500)

      # Events have atom keys, not string keys!
      turn_started = Enum.find(events, fn e -> e[:type] == "agent_turn_started" end)
      turn_ended = Enum.find(events, fn e -> e[:type] == "agent_turn_ended" end)

      assert turn_started != nil,
             "Expected agent_turn_started event, got: #{inspect(Enum.map(events, & &1[:type]))}"

      assert turn_started[:turn_number] == 1

      assert turn_ended != nil, "Expected agent_turn_ended event"
      assert turn_ended[:turn_number] == 1

      GenServer.stop(pid)
    end

    test "emits llm_stream events" do
      run_id = "test-events-2"

      # Subscribe BEFORE starting the loop
      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")

      # Small delay to ensure subscription propagates
      Process.sleep(10)

      MockLLM.set_response(%{text: "streaming text", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, [],
          llm_module: MockLLM,
          run_id: run_id
        )

      :ok = Loop.run_turn(pid)

      # Collect events with reasonable timeout
      events = collect_events(500)

      # Events have atom keys, not string keys!
      stream_events = Enum.filter(events, fn e -> e[:type] == "agent_llm_stream" end)

      assert length(stream_events) >= 1,
             "Expected at least one agent_llm_stream event, got: #{inspect(Enum.map(events, & &1[:type]))}"

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Tool-call-only turn: assistant(tool_calls) must precede tool results
  # ===========================================================================

  describe "tool-call-only turn message history" do
    test "assistant message with tool_calls appears before tool result messages" do
      # LLM returns tool-call-only response (no text)
      MockLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-history-1", name: :echo_tool, arguments: %{"input" => "test"}}]
      })

      {:ok, pid} =
        Loop.start_link(TestAgent, [%{role: "user", content: "run tool"}],
          llm_module: MockLLM,
          run_id: "test-tool-history-1",
          max_turns: 2,
          compaction_enabled: false
        )

      :ok = Loop.run_turn(pid)

      messages = Loop.get_messages(pid)

      # Expected: user → assistant(tool_calls) → tool(result)
      assert length(messages) == 3

      # First message is the original user message
      user_msg = Enum.at(messages, 0)
      assert user_msg[:role] == "user"

      # Second message MUST be assistant with tool_calls
      assistant_msg = Enum.at(messages, 1)
      assert assistant_msg[:role] == "assistant"
      assert is_list(assistant_msg[:tool_calls])
      assert length(assistant_msg[:tool_calls]) == 1

      [tc] = assistant_msg[:tool_calls]
      assert tc.id == "tc-history-1"
      assert tc.name == :echo_tool

      # Third message is the tool result
      tool_msg = Enum.at(messages, 2)
      assert tool_msg[:role] == "tool"
      assert tool_msg[:tool_call_id] == "tc-history-1"

      GenServer.stop(pid)
    end

    test "assistant message with both text and tool_calls preserves both" do
      MockLLM.set_response(%{
        text: "Let me check that.",
        tool_calls: [%{id: "tc-mixed-1", name: :echo_tool, arguments: %{"input" => "mixed"}}]
      })

      {:ok, pid} =
        Loop.start_link(TestAgent, [%{role: "user", content: "run tool"}],
          llm_module: MockLLM,
          run_id: "test-tool-history-mixed",
          max_turns: 2,
          compaction_enabled: false
        )

      :ok = Loop.run_turn(pid)

      messages = Loop.get_messages(pid)

      # Expected: user → assistant(text+tool_calls) → tool(result)
      assert length(messages) == 3

      assistant_msg = Enum.at(messages, 1)
      assert assistant_msg[:role] == "assistant"
      assert assistant_msg[:content] == "Let me check that."
      assert is_list(assistant_msg[:tool_calls])
      assert length(assistant_msg[:tool_calls]) == 1

      tool_msg = Enum.at(messages, 2)
      assert tool_msg[:role] == "tool"
      assert tool_msg[:tool_call_id] == "tc-mixed-1"

      GenServer.stop(pid)
    end

    test "tool-call-only turn: content is nil when no accumulated text" do
      MockLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-nil-content", name: :echo_tool, arguments: %{"input" => "nil"}}]
      })

      {:ok, pid} =
        Loop.start_link(TestAgent, [%{role: "user", content: "run tool"}],
          llm_module: MockLLM,
          run_id: "test-tool-nil-content",
          max_turns: 2,
          compaction_enabled: false
        )

      :ok = Loop.run_turn(pid)

      messages = Loop.get_messages(pid)
      assistant_msg = Enum.at(messages, 1)

      # When LLM emits tool calls with no text, content should be nil
      assert assistant_msg[:content] == nil
      assert is_list(assistant_msg[:tool_calls])

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Multi-turn message retention: code-puppy-v2o.1 regression
  # ===========================================================================
  #
  # After a tool-call turn followed by a text-only turn, state.messages MUST
  # contain the full conversation shape:
  #
  #   [user, assistant(tool_calls), tool(result), assistant(text)]
  #
  # The bug manifested as messages being lost between turns, leaving only
  # [user, assistant(text)] in the final history.

  describe "multi-turn message retention (tool-call + text)" do
    test "retains assistant(tool_calls) and tool_result messages across turns" do
      # Use a stateful mock that returns tool-call on turn 1, text on turn 2
      MockLLM.set_sequence([
        %{
          text: nil,
          tool_calls: [%{id: "tc-multi-1", name: :echo_tool, arguments: %{"input" => "hello"}}]
        },
        %{text: "Tool completed successfully.", tool_calls: []}
      ])

      {:ok, pid} =
        Loop.start_link(TestAgent, [%{role: "user", content: "run tool"}],
          llm_module: MockLLM,
          run_id: "test-multi-turn-retention",
          max_turns: 10,
          compaction_enabled: false
        )

      :ok = Loop.run_until_done(pid, 10_000)

      messages = Loop.get_messages(pid)

      # Expected shape: [user, assistant(tool_calls), tool(result), assistant(text)]
      assert length(messages) == 4,
             "Expected 4 messages after tool+text turns, got #{length(messages)}: #{inspect(messages)}"

      # [0] user message preserved
      user_msg = Enum.at(messages, 0)
      assert user_msg[:role] == "user"
      assert user_msg[:content] == "run tool"

      # [1] assistant message with tool_calls preserved
      assistant_tc_msg = Enum.at(messages, 1)
      assert assistant_tc_msg[:role] == "assistant"
      assert is_list(assistant_tc_msg[:tool_calls])
      assert length(assistant_tc_msg[:tool_calls]) == 1

      [tc] = assistant_tc_msg[:tool_calls]
      assert tc.id == "tc-multi-1"
      assert tc.name == :echo_tool

      # [2] tool result message preserved
      tool_result_msg = Enum.at(messages, 2)
      assert tool_result_msg[:role] == "tool"
      assert tool_result_msg[:tool_call_id] == "tc-multi-1"

      # [3] final assistant text message
      assistant_text_msg = Enum.at(messages, 3)
      assert assistant_text_msg[:role] == "assistant"
      assert assistant_text_msg[:content] == "Tool completed successfully."

      GenServer.stop(pid)
    end

    test "retains multiple tool-call+result pairs across turns" do
      # Two tool calls on turn 1, text on turn 2
      MockLLM.set_sequence([
        %{
          text: "Using both tools.",
          tool_calls: [
            %{id: "tc-pair-1", name: :echo_tool, arguments: %{"input" => "first"}},
            %{id: "tc-pair-2", name: :echo_tool, arguments: %{"input" => "second"}}
          ]
        },
        %{text: "Both tools done.", tool_calls: []}
      ])

      {:ok, pid} =
        Loop.start_link(TestAgent, [%{role: "user", content: "run two tools"}],
          llm_module: MockLLM,
          run_id: "test-multi-tool-retention",
          max_turns: 10,
          compaction_enabled: false
        )

      :ok = Loop.run_until_done(pid, 10_000)

      messages = Loop.get_messages(pid)

      # Expected: [user, assistant(text+tool_calls), tool(result1), tool(result2), assistant(text)]
      assert length(messages) == 5,
             "Expected 5 messages, got #{length(messages)}: #{inspect(messages)}"

      # Verify assistant with tool_calls
      asst = Enum.at(messages, 1)
      assert asst[:role] == "assistant"
      assert asst[:content] == "Using both tools."
      assert length(asst[:tool_calls]) == 2

      # Verify both tool results present
      tr1 = Enum.at(messages, 2)
      assert tr1[:role] == "tool"
      assert tr1[:tool_call_id] == "tc-pair-1"

      tr2 = Enum.at(messages, 3)
      assert tr2[:role] == "tool"
      assert tr2[:tool_call_id] == "tc-pair-2"

      # Final text response
      final = Enum.at(messages, 4)
      assert final[:role] == "assistant"
      assert final[:content] == "Both tools done."

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp collect_events(timeout) do
    collect_events([], timeout)
  end

  defp collect_events(acc, timeout) do
    receive do
      {:event, event} -> collect_events([event | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
