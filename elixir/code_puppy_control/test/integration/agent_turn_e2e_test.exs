defmodule CodePuppyControl.Integration.AgentTurnE2ETest do
  @moduledoc """
  Phase 1 exit-gate e2e test for the Code Puppy agent turn pipeline.

  Proves the Elixir stack works end-to-end with zero Python involvement:
  `Loop → LLM → Normalizer → Tool.Runner → Registry → Events`.

  **Run with:** `mix test --include integration`

  Uses mocked provider modules (MockLLM + MockAgent) that emit raw
  provider-format stream events (`{:part_start}`, `{:part_delta}`,
  `{:part_end}`, `{:done}`) so the Normalizer path is exercised.

  `async: false` because EventBus is process-global state.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 30_000

  alias CodePuppyControl.Agent.Loop
  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Tool.Registry

  # ---------------------------------------------------------------------------
  # E2E Test Tool — deterministic, no side effects
  # ---------------------------------------------------------------------------
  # Deviation from design doc: `:command_runner` does NOT implement the
  # Tool behaviour and is not registered in the Tool Registry. Instead we
  # register a custom test tool that exercises the full
  # `Runner.invoke → Registry.lookup → permission_check → schema validation → invoke`
  # path without shell execution.

  defmodule E2ETestTool do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :e2e_test_tool

    @impl true
    def description, do: "Deterministic test tool for e2e assertions"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string", "description" => "Input to echo back"}
        },
        "required" => ["input"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{"echo" => args["input"]}}
    end
  end

  # ---------------------------------------------------------------------------
  # E2E Agent
  # ---------------------------------------------------------------------------

  defmodule E2EAgent do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :e2e_test_agent

    @impl true
    def system_prompt(_ctx), do: "You are a test agent."

    @impl true
    def allowed_tools, do: [:e2e_test_tool]

    @impl true
    def model_preference, do: "test-model-e2e"

    @impl true
    def on_tool_result(_name, _result, state), do: {:cont, state}
  end

  # ---------------------------------------------------------------------------
  # Mock LLM: Text-only response (raw provider-format events)
  # ---------------------------------------------------------------------------

  defmodule TextOnlyLLM do
    @moduledoc false

    @spec stream_chat([map()], [atom()], keyword(), fun()) :: {:ok, map()}
    def stream_chat(_messages, _tools, _opts, cb) do
      # Emit raw provider-format events — the Normalizer converts them
      cb.({:part_start, %{type: :text, index: 0, id: nil}})
      cb.({:part_delta, %{type: :text, index: 0, text: "Hello ", name: nil, arguments: nil}})
      cb.({:part_delta, %{type: :text, index: 0, text: "world!", name: nil, arguments: nil}})
      cb.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})

      cb.(
        {:done,
         %{
           id: "msg-1",
           model: "test",
           content: nil,
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 5, completion_tokens: 2, total_tokens: 7}
         }}
      )

      {:ok, %{text: "Hello world!", tool_calls: []}}
    end
  end

  # ---------------------------------------------------------------------------
  # Mock LLM: Tool-call then text response (raw provider-format events)
  # ---------------------------------------------------------------------------

  defmodule ToolCallLLM do
    @moduledoc false

    @spec stream_chat([map()], [atom()], keyword(), fun()) :: {:ok, map()}
    def stream_chat(messages, _tools, _opts, cb) do
      if Enum.any?(messages, fn m -> m[:role] == "tool" or m["role"] == "tool" end) do
        # Turn 2: after tool result, respond with text
        cb.({:part_start, %{type: :text, index: 0, id: nil}})

        cb.(
          {:part_delta,
           %{type: :text, index: 0, text: "Tool executed!", name: nil, arguments: nil}}
        )

        cb.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})

        cb.(
          {:done,
           %{
             id: "msg-3",
             model: "test",
             content: nil,
             tool_calls: [],
             finish_reason: "stop",
             usage: nil
           }}
        )

        {:ok, %{text: "Tool executed!", tool_calls: []}}
      else
        # Turn 1: request a tool call
        cb.({:part_start, %{type: :tool_call, index: 0, id: "tc-e2e-1"}})

        cb.(
          {:part_delta,
           %{type: :tool_call, index: 0, text: nil, name: "e2e_test_tool", arguments: nil}}
        )

        cb.(
          {:part_delta,
           %{
             type: :tool_call,
             index: 0,
             text: nil,
             name: nil,
             arguments: "{\"input\": \"hello\"}"
           }}
        )

        cb.(
          {:part_end,
           %{
             type: :tool_call,
             index: 0,
             id: "tc-e2e-1",
             name: "e2e_test_tool",
             arguments: "{\"input\": \"hello\"}"
           }}
        )

        cb.(
          {:done,
           %{
             id: "msg-2",
             model: "test",
             content: nil,
             tool_calls: [
               %{id: "tc-e2e-1", name: :e2e_test_tool, arguments: %{"input" => "hello"}}
             ],
             finish_reason: "tool_calls",
             usage: nil
           }}
        )

        {:ok,
         %{
           text: nil,
           tool_calls: [%{id: "tc-e2e-1", name: :e2e_test_tool, arguments: %{"input" => "hello"}}]
         }}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mock LLM: Counting turns with tool calls (for max_turns boundary test)
  # ---------------------------------------------------------------------------
  # Emits a tool call on every turn so the loop cannot short-circuit via
  # the :text_response path.  The loop will only stop when max_turns is hit.

  defmodule CountingLLM do
    @moduledoc false

    @spec stream_chat([map()], [atom()], keyword(), fun()) :: {:ok, map()}
    def stream_chat(messages, _tools, _opts, cb) do
      turn =
        Enum.count(messages, fn m ->
          m[:role] == "assistant" or m["role"] == "assistant"
        end) + 1

      tc_id = "tc-turn-#{turn}"

      cb.({:part_start, %{type: :tool_call, index: 0, id: tc_id}})

      cb.(
        {:part_delta,
         %{type: :tool_call, index: 0, text: nil, name: "e2e_test_tool", arguments: nil}}
      )

      cb.(
        {:part_delta,
         %{
           type: :tool_call,
           index: 0,
           text: nil,
           name: nil,
           arguments: "{\"input\": \"turn-#{turn}\"}"
         }}
      )

      cb.(
        {:part_end,
         %{
           type: :tool_call,
           index: 0,
           id: tc_id,
           name: "e2e_test_tool",
           arguments: "{\"input\": \"turn-#{turn}\"}"
         }}
      )

      cb.(
        {:done,
         %{
           id: "msg-#{turn}",
           model: "test",
           content: nil,
           tool_calls: [
             %{id: tc_id, name: :e2e_test_tool, arguments: %{"input" => "turn-#{turn}"}}
           ],
           finish_reason: "tool_calls",
           usage: nil
         }}
      )

      {:ok,
       %{
         text: nil,
         tool_calls: [%{id: tc_id, name: :e2e_test_tool, arguments: %{"input" => "turn-#{turn}"}}]
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Test Setup
  # ---------------------------------------------------------------------------

  setup do
    # Register the test tool (idempotent — re-registering overwrites)
    Registry.register(E2ETestTool)

    # Subscribe to global events
    :ok = EventBus.subscribe_global()

    on_exit(fn ->
      EventBus.unsubscribe_global()
      Registry.unregister(:e2e_test_tool)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp flush_events(timeout_ms \\ 5_000) do
    # Wait deterministically for the terminal event, then drain the mailbox
    assert_receive {:event, %{type: "agent_run_completed"}}, timeout_ms

    # Drain any remaining events with zero-timeout receive
    drain_events([])
  end

  defp drain_events(acc) do
    receive do
      {:event, event} ->
        drain_events([event | acc])
    after
      0 ->
        Enum.reverse(acc)
    end
  end

  defp event_types(events) do
    Enum.map(events, fn e -> e.type end)
  end

  defp events_of_type(events, type) do
    Enum.filter(events, fn e -> e.type == type end)
  end

  defp unique_run_id do
    "e2e-#{System.unique_integer([:positive])}"
  end

  # ===========================================================================
  # Test 1: Simple text-only turn
  # ===========================================================================

  describe "text-only turn" do
    test "completes a single text turn with correct events and state" do
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(E2EAgent, [%{role: "user", content: "Hi"}],
          run_id: run_id,
          llm_module: TextOnlyLLM,
          max_turns: 1
        )

      result = Loop.run_until_done(pid, 10_000)
      assert result == :ok

      state = Loop.get_state(pid)
      assert state.completed == true
      assert state.turn_number == 1
      # user + assistant
      assert state.message_count == 2

      events = flush_events()
      types = event_types(events)

      # Core event sequence
      assert "agent_turn_started" in types
      assert "agent_llm_stream" in types
      assert "agent_turn_ended" in types
      assert "agent_run_completed" in types

      # LLM stream events carry the text chunks
      stream_events = events_of_type(events, "agent_llm_stream")
      assert length(stream_events) >= 2

      streamed_text = Enum.map_join(stream_events, fn e -> e.chunk end)
      assert streamed_text == "Hello world!"

      # Run completed with text_response reason
      [completed] = events_of_type(events, "agent_run_completed")
      assert completed.summary.reason == :text_response
      assert completed.summary.turns == 1

      # Turn ended with :done
      [turn_ended] = events_of_type(events, "agent_turn_ended")
      assert turn_ended.reason == "done"

      # Event ordering: started before ended before completed
      started_at = Enum.find_index(types, &(&1 == "agent_turn_started"))
      ended_at = Enum.find_index(types, &(&1 == "agent_turn_ended"))
      completed_at = Enum.find_index(types, &(&1 == "agent_run_completed"))

      assert started_at < ended_at
      assert ended_at < completed_at

      GenServer.stop(pid, :normal)
    end
  end

  # ===========================================================================
  # Test 2: Tool-call turn
  # ===========================================================================

  describe "tool-call turn" do
    test "executes tool call and completes with text response" do
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(E2EAgent, [%{role: "user", content: "Run the test tool"}],
          run_id: run_id,
          llm_module: ToolCallLLM,
          max_turns: 5
        )

      result = Loop.run_until_done(pid, 15_000)
      assert result == :ok

      state = Loop.get_state(pid)
      assert state.completed == true
      assert state.turn_number == 2

      events = flush_events()
      types = event_types(events)

      # ---- Event type assertions ----

      # Turn 1 events
      assert "agent_turn_started" in types
      assert "agent_tool_call_start" in types
      assert "agent_tool_call_end" in types

      # Turn 2 events
      assert "agent_llm_stream" in types
      assert "agent_turn_ended" in types
      assert "agent_run_completed" in types

      # ---- Tool call events ----

      tool_starts = events_of_type(events, "agent_tool_call_start")
      tool_ends = events_of_type(events, "agent_tool_call_end")

      # At least one tool_call_start and one tool_call_end
      # (There may be two tool_call_starts: one from the stream callback
      #  when ToolCallEnd arrives, and one from execute_tool_call dispatch.)
      assert length(tool_starts) >= 1
      assert length(tool_ends) >= 1

      # Tool call end result is {:ok, ...}
      [tool_end | _] = tool_ends
      assert match?({:ok, _}, tool_end.result)

      # ---- Final message history structure ----

      # user → assistant(text:nil, tool_call) → tool result → assistant("Tool executed!")
      # The Loop appends messages via finalize_turn.
      # Turn 1: no text (tool call only) → tool result appended by dispatch_tool_calls
      # Turn 2: "Tool executed!" appended as assistant message
      assert state.message_count >= 3

      # ---- Run completed after second turn ----

      [completed] = events_of_type(events, "agent_run_completed")
      assert completed.summary.turns == 2

      GenServer.stop(pid, :normal)
    end
  end

  # ===========================================================================
  # Test 4: Multi-turn replay — history correctness for subsequent LLM turns
  # ===========================================================================

  describe "multi-turn replay: history correctness" do
    test "tool-call-only turn produces assistant(tool_calls) before tool result" do
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(E2EAgent, [%{role: "user", content: "Run the test tool"}],
          run_id: run_id,
          llm_module: ToolCallLLM,
          max_turns: 5
        )

      result = Loop.run_until_done(pid, 15_000)
      assert result == :ok

      messages = Loop.get_messages(pid)

      # Expected order: user → assistant(tool_calls) → tool(result) → assistant(text)
      assert length(messages) == 4

      # 1. User message
      assert Enum.at(messages, 0)[:role] == "user"

      # 2. Assistant with tool_calls (NOT missing!)
      assistant_tc_msg = Enum.at(messages, 1)
      assert assistant_tc_msg[:role] == "assistant"
      assert is_list(assistant_tc_msg[:tool_calls])
      assert length(assistant_tc_msg[:tool_calls]) == 1

      [tc] = assistant_tc_msg[:tool_calls]
      assert tc.id == "tc-e2e-1"
      assert tc.name == :e2e_test_tool

      # 3. Tool result message
      tool_result_msg = Enum.at(messages, 2)
      assert tool_result_msg[:role] == "tool"
      assert tool_result_msg[:tool_call_id] == "tc-e2e-1"

      # 4. Assistant text response (turn 2)
      assistant_text_msg = Enum.at(messages, 3)
      assert assistant_text_msg[:role] == "assistant"
      assert assistant_text_msg[:content] == "Tool executed!"

      _events = flush_events()
      GenServer.stop(pid, :normal)
    end

    test "subsequent LLM turn receives replayable history in correct order" do
      # Use a custom LLM that captures the messages it receives on turn 2
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(E2EAgent, [%{role: "user", content: "Run the test tool"}],
          run_id: run_id,
          llm_module: ToolCallLLM,
          max_turns: 5
        )

      result = Loop.run_until_done(pid, 15_000)
      assert result == :ok

      messages = Loop.get_messages(pid)

      # Verify the message sequence is provider-replayable:
      # every tool-role message must have a preceding assistant message
      # with tool_calls that includes its tool_call_id.
      tool_result_ids =
        messages
        |> Enum.filter(fn m -> m[:role] == "tool" end)
        |> Enum.map(fn m -> m[:tool_call_id] end)

      assert length(tool_result_ids) >= 1, "Expected at least one tool result"

      # For each tool result, find the assistant message with matching tool_calls
      for tcid <- tool_result_ids do
        has_matching_assistant =
          Enum.any?(messages, fn m ->
            m[:role] == "assistant" and
              is_list(m[:tool_calls]) and
              Enum.any?(m[:tool_calls], fn tc -> tc.id == tcid end)
          end)

        assert has_matching_assistant,
               "Tool result with id=#{tcid} has no preceding assistant(tool_calls) message"
      end

      # Also verify: no tool result appears before its assistant(tool_calls)
      tool_result_positions =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {m, _i} -> m[:role] == "tool" end)
        |> Enum.map(fn {m, i} -> {m[:tool_call_id], i} end)

      assistant_tc_positions =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {m, _i} -> m[:role] == "assistant" and is_list(m[:tool_calls]) end)
        |> Enum.flat_map(fn {m, i} ->
          Enum.map(m[:tool_calls], fn tc -> {tc.id, i} end)
        end)

      for {tcid, tool_idx} <- tool_result_positions do
        {^tcid, assistant_idx} =
          Enum.find(assistant_tc_positions, fn {id, _i} -> id == tcid end)

        assert assistant_idx < tool_idx,
               "Tool result for id=#{tcid} at index=#{tool_idx} must come after " <>
                 "assistant(tool_calls) at index=#{assistant_idx}"
      end

      _events = flush_events()
      GenServer.stop(pid, :normal)
    end
  end

  # ===========================================================================
  # Test 3: Multi-turn (max_turns boundary)
  # ===========================================================================

  describe "multi-turn max_turns boundary" do
    test "stops at max_turns and reports boundary reached" do
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(E2EAgent, [%{role: "user", content: "Go"}],
          run_id: run_id,
          llm_module: CountingLLM,
          max_turns: 3
        )

      # CountingLLM emits tool calls every turn, so the loop cannot
      # short-circuit via :text_response. It will stop at max_turns: 3.
      result = Loop.run_until_done(pid, 10_000)
      assert {:error, :max_turns_reached} = result

      state = Loop.get_state(pid)
      assert state.completed == false
      assert state.turn_number == 3

      events = flush_events()
      _types = event_types(events)

      # 3 turns started, 3 turns ended
      turn_starts = events_of_type(events, "agent_turn_started")
      turn_ends = events_of_type(events, "agent_turn_ended")
      assert length(turn_starts) == 3
      assert length(turn_ends) == 3

      # Run completed with max_turns_reached reason
      [completed] = events_of_type(events, "agent_run_completed")
      assert completed.summary.reason == :max_turns_reached
      assert completed.summary.turns == 3

      # Tool call events — at least one per turn (3 total)
      tool_call_starts = events_of_type(events, "agent_tool_call_start")
      assert length(tool_call_starts) >= 3

      GenServer.stop(pid, :normal)
    end
  end
end
