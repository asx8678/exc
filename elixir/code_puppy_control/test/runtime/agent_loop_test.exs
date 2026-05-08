defmodule CodePuppyControl.Runtime.AgentLoopTest do
  @moduledoc """
  Tests for Agent.Loop GenServer — lifecycle, turn execution, cancellation,
  compaction integration, and event emission.

  Uses a mock agent module and mock LLM to avoid real LLM calls.
  async: false because GenServer processes are registered globally.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.{Loop, Turn, Events}
  alias CodePuppyControl.EventBus

  # ---------------------------------------------------------------------------
  # Mock Agent Module
  # ---------------------------------------------------------------------------

  defmodule MockAgent do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :mock_agent

    @impl true
    def system_prompt(_context), do: "You are a test assistant."

    @impl true
    def allowed_tools, do: [:test_tool]

    @impl true
    def model_preference, do: "test-model"

    @impl true
    def on_tool_result(_tool_name, result, state),
      do: {:cont, Map.put(state, :last_result, result)}
  end

  # ---------------------------------------------------------------------------
  # Mock LLM Module
  # ---------------------------------------------------------------------------

  defmodule MockLLM do
    @moduledoc false

    @spec stream_chat([map()], [atom()], keyword(), fun()) :: {:ok, map()} | {:error, term()}
    def stream_chat(messages, _tools, _opts, _callback) do
      # Simple mock: respond to last user message
      last_user =
        Enum.find(messages, fn m -> m[:role] == "user" || m["role"] == "user" end)

      text =
        case last_user do
          %{content: c} when is_binary(c) -> "Mock response to: #{c}"
          %{"content" => c} when is_binary(c) -> "Mock response to: #{c}"
          _ -> "Mock response"
        end

      {:ok, %{text: text, tool_calls: []}}
    end
  end

  # ---------------------------------------------------------------------------
  # Test Setup
  # ---------------------------------------------------------------------------

  setup do
    # Subscribe to events for verification
    :ok = EventBus.subscribe_global()

    on_exit(fn ->
      # Clean up any subscribed topics
      EventBus.unsubscribe_global()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  describe "start_link/3" do
    test "starts an agent loop process" do
      {:ok, pid} =
        Loop.start_link(MockAgent, [%{role: "user", content: "Hello"}],
          run_id: "loop-test-#{System.unique_integer([:positive])}",
          llm_module: MockLLM,
          max_turns: 1
        )

      assert is_pid(pid)
      GenServer.stop(pid, :normal)
    end

    test "generates a unique run_id if not provided" do
      {:ok, pid} =
        Loop.start_link(MockAgent, [%{role: "user", content: "Hi"}],
          llm_module: MockLLM,
          max_turns: 1
        )

      state = Loop.get_state(pid)
      assert String.starts_with?(state.run_id, "agent-")
      GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # State Introspection
  # ---------------------------------------------------------------------------

  describe "get_state/1" do
    test "returns current loop state" do
      run_id = "state-test-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loop.start_link(MockAgent, [%{role: "user", content: "test"}],
          run_id: run_id,
          session_id: "session-1",
          llm_module: MockLLM,
          max_turns: 5
        )

      state = Loop.get_state(pid)

      assert state.run_id == run_id
      assert state.session_id == "session-1"
      assert state.turn_number == 0
      assert state.max_turns == 5
      assert state.cancelled == false
      assert state.completed == false
      assert state.message_count == 1

      GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Cancellation
  # ---------------------------------------------------------------------------

  describe "cancel/1" do
    test "sets cancelled flag" do
      {:ok, pid} =
        Loop.start_link(MockAgent, [%{role: "user", content: "cancel me"}],
          run_id: "cancel-test-#{System.unique_integer([:positive])}",
          llm_module: MockLLM,
          max_turns: 1
        )

      :ok = Loop.cancel(pid)
      state = Loop.get_state(pid)
      assert state.cancelled == true

      GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Run Until Done
  # ---------------------------------------------------------------------------

  describe "run_until_done/2" do
    @tag capture_log: true
    test "completes with text-only response in one turn" do
      run_id = "done-test-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loop.start_link(MockAgent, [%{role: "user", content: "Hello"}],
          run_id: run_id,
          llm_module: MockLLM,
          max_turns: 1
        )

      result = Loop.run_until_done(pid, 10_000)
      assert result == :ok

      state = Loop.get_state(pid)
      assert state.completed == true
      assert state.turn_number == 1

      GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Agent Events
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Mock LLM Module (captures system prompt for assertion)
  # ---------------------------------------------------------------------------

  defmodule CapturingMockLLM do
    @moduledoc false
    # Uses an Agent to store the system_prompt across process boundaries
    # (the GenServer loop runs in its own process, so Process dict won't work).

    @table :capturing_mock_llm_ets

    @spec stream_chat([map()], [atom()], keyword(), fun()) :: {:ok, map()} | {:error, term()}
    def stream_chat(_messages, _tools, opts, _callback) do
      system_prompt = Keyword.get(opts, :system_prompt, "")
      :ets.insert(@table, {:system_prompt, system_prompt})
      {:ok, %{text: "Mock response", tool_calls: []}}
    end

    @doc "Initializes ETS table for capturing prompts (call from test setup)."
    @spec setup() :: :ok
    def setup do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      else
        :ets.delete_all_objects(@table)
      end

      :ok
    end

    @doc "Retrieves the system prompt captured by the last stream_chat call."
    @spec get_captured_prompt() :: String.t() | nil
    def get_captured_prompt do
      case :ets.lookup(@table, :system_prompt) do
        [{:system_prompt, prompt}] -> prompt
        [] -> nil
      end
    end

    @doc "Clears the captured system prompt."
    @spec reset() :: :ok
    def reset do
      :ets.delete_all_objects(@table)
      :ok
    end
  end

  describe "Agent.Loop integration with PromptMixin" do
    @tag capture_log: true
    test "system_prompt includes platform info and identity via get_full_system_prompt" do
      CapturingMockLLM.setup()

      run_id = "prompt-mixin-test-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loop.start_link(MockAgent, [%{role: "user", content: "Hello"}],
          run_id: run_id,
          llm_module: CapturingMockLLM,
          max_turns: 1
        )

      :ok = Loop.run_until_done(pid, 10_000)

      captured = CapturingMockLLM.get_captured_prompt()

      # Base prompt from MockAgent
      assert captured =~ "You are a test assistant."

      # Platform info injected by PromptMixin.get_full_system_prompt
      assert captured =~ "# Environment"
      assert captured =~ "- Platform:"
      assert captured =~ "- Shell:"

      # Identity injected by PromptMixin.get_full_system_prompt
      assert captured =~ "Your ID is"
      assert captured =~ "mock_agent-"

      GenServer.stop(pid, :normal)
    end

    @tag capture_log: true
    test "system_prompt includes load_prompt callback additions" do
      CapturingMockLLM.setup()

      CodePuppyControl.Callbacks.clear(:load_prompt)
      CodePuppyControl.Callbacks.register(:load_prompt, fn -> "Integration test instruction" end)

      run_id = "prompt-callback-test-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loop.start_link(MockAgent, [%{role: "user", content: "Hello"}],
          run_id: run_id,
          llm_module: CapturingMockLLM,
          max_turns: 1
        )

      :ok = Loop.run_until_done(pid, 10_000)

      captured = CapturingMockLLM.get_captured_prompt()

      assert captured =~ "# Custom Instructions"
      assert captured =~ "Integration test instruction"

      CodePuppyControl.Callbacks.clear(:load_prompt)
      GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Agent Events
  # ---------------------------------------------------------------------------

  describe "agent events" do
    test "Agent.Events.builds correctly structured events" do
      run_id = "event-test-#{System.unique_integer([:positive])}"

      event = Events.turn_started(run_id, "session-1", 1)
      assert event.type == "agent_turn_started"
      assert event.run_id == run_id
      assert event.turn_number == 1

      stream_event = Events.llm_stream(run_id, "session-1", "hello")
      assert stream_event.type == "agent_llm_stream"
      assert stream_event.chunk == "hello"

      tool_start = Events.tool_call_start(run_id, "session-1", "read_file", %{}, "tc-1")
      assert tool_start.type == "agent_tool_call_start"
      assert tool_start.tool_name == "read_file"

      tool_end = Events.tool_call_end(run_id, "session-1", "read_file", {:ok, "data"}, "tc-1")
      assert tool_end.type == "agent_tool_call_end"

      turn_end = Events.turn_ended(run_id, "session-1", 1, :done)
      assert turn_end.type == "agent_turn_ended"
      assert turn_end.reason == "done"

      run_completed = Events.run_completed(run_id, "session-1", %{turns: 1})
      assert run_completed.type == "agent_run_completed"

      run_failed = Events.run_failed(run_id, "session-1", "timeout")
      assert run_failed.type == "agent_run_failed"
      assert run_failed.error == "timeout"
    end

    test "Agent.Events.to_json/1 and from_json/1 round-trip" do
      event = Events.turn_started("run-1", "s-1", 1)
      {:ok, json} = Events.to_json(event)
      {:ok, decoded} = Events.from_json(json)
      assert decoded["type"] == "agent_turn_started"
      assert decoded["run_id"] == "run-1"
    end

    test "Agent.Events.from_json/1 rejects non-map JSON" do
      assert {:error, :invalid_event_format} = Events.from_json("[1,2,3]")
    end
  end

  # ---------------------------------------------------------------------------
  # Turn State Machine
  # ---------------------------------------------------------------------------

  describe "Turn state machine" do
    test "full lifecycle: idle → calling_llm → streaming → done" do
      turn = Turn.new(1)
      assert turn.state == :idle

      {:ok, turn} = Turn.start_llm_call(turn)
      assert turn.state == :calling_llm

      {:ok, turn} = Turn.start_streaming(turn)
      assert turn.state == :streaming

      {:ok, turn} = Turn.append_text(turn, "Hello ")
      {:ok, turn} = Turn.append_text(turn, "World")
      assert turn.accumulated_text == "Hello World"

      # No pending tools → start_tool_calls transitions to :done
      {:ok, turn} = Turn.start_tool_calls(turn)
      assert turn.state == :done
    end

    test "lifecycle with tool calls: idle → streaming → tool_calling → tool_awaiting → done" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)

      # Add tool call
      tool_call = %{id: "tc-1", name: :read_file, arguments: %{path: "/tmp"}}
      {:ok, turn} = Turn.add_tool_call(turn, tool_call)
      assert Turn.has_pending_tools?(turn)

      # Start tool dispatch
      {:ok, turn} = Turn.start_tool_calls(turn)
      assert turn.state == :tool_calling

      # Await tools
      {:ok, turn} = Turn.await_tools(turn)
      assert turn.state == :tool_awaiting

      # Complete tool
      {:ok, turn} = Turn.complete_tool(turn, "tc-1", {:ok, "file content"})
      assert turn.state == :done
      refute Turn.has_pending_tools?(turn)
    end

    test "invalid transitions return error" do
      turn = Turn.new(1)

      # Can't stream from idle
      assert {:error, :invalid_transition} = Turn.start_streaming(turn)

      # Can't append text from idle
      assert {:error, :invalid_transition} = Turn.append_text(turn, "hi")
    end

    test "fail transitions to error state from any state" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.fail(turn, "something went wrong")
      assert turn.state == :error
      assert turn.error == "something went wrong"
    end

    test "terminal? returns true for done and error states" do
      idle = Turn.new(1)
      refute Turn.terminal?(idle)

      {:ok, done} = Turn.start_llm_call(idle)
      {:ok, done} = Turn.start_streaming(done)
      {:ok, done} = Turn.start_tool_calls(done)
      assert Turn.terminal?(done)

      {:ok, errored} = Turn.fail(idle, "boom")
      assert Turn.terminal?(errored)
    end

    test "summary/1 returns expected fields" do
      turn = Turn.new(3)
      summary = Turn.summary(turn)

      assert summary.turn_number == 3
      assert summary.state == :idle
      assert summary.text_length == 0
      assert summary.tool_calls_requested == 0
      assert summary.error == nil
    end

    test "elapsed_ms returns nil for unstarted turn" do
      turn = Turn.new(1)
      assert Turn.elapsed_ms(turn) == nil
    end
  end
end
