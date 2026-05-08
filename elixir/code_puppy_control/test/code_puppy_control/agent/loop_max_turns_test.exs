defmodule CodePuppyControl.Agent.LoopMaxTurnsTest do
  @moduledoc """
  Focused tests for caller-facing max-turns behavior.

  Verifies that max-turns exhaustion correctly returns and propagates
  `:max_turns_reached` to callers through all public entry points:

    - `run_until_done/2` return value
    - `get_state/1` introspection (turn_number, completed, cancelled)
    - `get_messages/1` preservation across turns
    - Event emission (`agent_run_completed` with `summary.reason == :max_turns_reached`)

  After Wave 1 B3, the Loop publishes an `agent_run_completed` event with
  `%{reason: :max_turns_reached, turns: n}` before returning.  These tests
  prove that a "caller" (REPL, agent runner, or tool) sees the correct
  run-status after max-turns termination — not just the internal Loop return.

  async: false because {Agent, GenServer, Process.register} state is
  process-global and EventBus subscription is per-test.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop
  alias CodePuppyControl.EventBus

  # ---------------------------------------------------------------------------
  # Caller-facing agent (real Behaviour)
  # ---------------------------------------------------------------------------

  defmodule CallerAgent do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :caller_agent
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
  # Caller-facing mock LLM (persistent Agent, shared per suite)
  # ---------------------------------------------------------------------------

  defmodule CallerLLM do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.LLM

    def start_link do
      case Agent.start(fn -> %{response: nil, sequence: [], call_count: 0} end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def set_response(response) do
      Agent.update(__MODULE__, fn _ -> %{response: response, sequence: [], call_count: 0} end)
    end

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
    def stream_chat(_messages, _tools, _opts, callback_fn) do
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
        %{text: text, tool_calls: tool_calls} when is_list(tool_calls) ->
          if text, do: callback_fn.({:text, text})

          for tc <- tool_calls do
            callback_fn.({:tool_call, tc.name, tc.arguments, tc.id})
          end

        %{text: text} ->
          callback_fn.({:text, text})

        _ ->
          :ok
      end

      callback_fn.({:done, :complete})
      {:ok, response}
    end
  end

  # ---------------------------------------------------------------------------
  # Mock tool
  # ---------------------------------------------------------------------------

  defmodule Tool.EchoTool do
    def execute(%{"input" => input}), do: {:ok, "echo: #{input}"}
    def execute(_), do: {:ok, "echo"}
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    {:ok, _pid} = CallerLLM.start_link()

    # Subscribe to global events for caller-facing assertion
    :ok = EventBus.subscribe_global()

    on_exit(fn ->
      CallerLLM.stop()
      EventBus.unsubscribe_global()
    end)

    :ok
  end

  # ===========================================================================
  # Basic max-turns exhaustion: run_until_done return + state + messages
  # ===========================================================================

  describe "run_until_done/2 — max-turns exhaustion" do
    test "returns {:error, :max_turns_reached} and preserves caller state" do
      # Agent always returns tool calls so the loop cannot short-circuit
      CallerLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-1", name: :echo_tool, arguments: %{"input" => "hi"}}]
      })

      {:ok, pid} =
        Loop.start_link(CallerAgent, [%{role: "user", content: "run"}],
          llm_module: CallerLLM,
          run_id: "mt-caller-basic-#{System.unique_integer([:positive])}",
          max_turns: 3,
          compaction_enabled: false
        )

      # Caller-facing: run_until_done returns expected tuple
      assert {:error, :max_turns_reached} = Loop.run_until_done(pid, 10_000)

      # Caller-facing: get_state introspection
      state = Loop.get_state(pid)
      assert state.turn_number == 3
      assert state.completed == false
      assert state.cancelled == false

      # Caller-facing: get_messages preserved after max-turns
      messages = Loop.get_messages(pid)

      assert length(messages) >= 3,
             "Expected at least [user, assistant(tc), tool(result)], got #{length(messages)}"

      user_msg = Enum.at(messages, 0)
      assert user_msg[:role] == "user"
      assert user_msg[:content] == "run"

      GenServer.stop(pid)
    end

    test "emits agent_run_completed event with max_turns_reached summary" do
      CallerLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-ev-1", name: :echo_tool, arguments: %{"input" => "ev"}}]
      })

      run_id = "mt-caller-events-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loop.start_link(CallerAgent, [],
          llm_module: CallerLLM,
          run_id: run_id,
          max_turns: 3,
          compaction_enabled: false
        )

      assert {:error, :max_turns_reached} = Loop.run_until_done(pid, 10_000)

      # Collect run events via PubSub
      events = collect_events(500)

      # Caller-facing: agent_run_completed event propagated
      completed_events =
        Enum.filter(events, fn e -> e[:type] == "agent_run_completed" end)

      assert length(completed_events) == 1,
             "Expected 1 agent_run_completed event, got #{length(completed_events)}"

      [completed] = completed_events

      assert completed.summary.reason == :max_turns_reached,
             "Expected reason :max_turns_reached, got: #{inspect(completed.summary.reason)}"

      assert completed.summary.turns == 3,
             "Expected turns 3, got: #{inspect(completed.summary.turns)}"

      assert completed.run_id == run_id

      # Events include turn lifecycle and tool call events
      event_types = Enum.map(events, fn e -> e[:type] end)

      assert "agent_turn_started" in event_types,
             "Expected agent_turn_started in events: #{inspect(event_types)}"

      assert "agent_tool_call_start" in event_types,
             "Expected agent_tool_call_start in events: #{inspect(event_types)}"

      assert "agent_tool_call_end" in event_types,
             "Expected agent_tool_call_end in events: #{inspect(event_types)}"

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Multi-turn message preservation under max-turns
  # ===========================================================================

  describe "multi-turn message preservation under max-turns" do
    test "preserves all assistant(tool_calls) + tool_result messages across turns" do
      CallerLLM.set_sequence([
        %{
          text: nil,
          tool_calls: [%{id: "tc-seq-1", name: :echo_tool, arguments: %{"input" => "a"}}]
        },
        %{
          text: nil,
          tool_calls: [%{id: "tc-seq-2", name: :echo_tool, arguments: %{"input" => "b"}}]
        },
        %{text: "Done", tool_calls: []}
      ])

      {:ok, pid} =
        Loop.start_link(CallerAgent, [%{role: "user", content: "start"}],
          llm_module: CallerLLM,
          run_id: "mt-seq-#{System.unique_integer([:positive])}",
          max_turns: 2,
          compaction_enabled: false
        )

      # Should hit max_turns=2 before the text-response turn
      assert {:error, :max_turns_reached} = Loop.run_until_done(pid, 10_000)

      messages = Loop.get_messages(pid)

      # Expected: [user, assistant(tc-1), tool(result-1), assistant(tc-2), tool(result-2)]
      assert length(messages) == 5,
             "Expected 5 messages after 2 tool-call turns, got #{length(messages)}"

      # User message preserved
      assert Enum.at(messages, 0)[:role] == "user"
      assert Enum.at(messages, 0)[:content] == "start"

      # Turn 1: assistant with tool_call
      asst1 = Enum.at(messages, 1)
      assert asst1[:role] == "assistant"
      assert asst1[:content] == nil
      assert length(asst1[:tool_calls]) == 1
      assert hd(asst1[:tool_calls]).id == "tc-seq-1"

      # Turn 1: tool result
      tool1 = Enum.at(messages, 2)
      assert tool1[:role] == "tool"
      assert tool1[:tool_call_id] == "tc-seq-1"

      # Turn 2: assistant with tool_call
      asst2 = Enum.at(messages, 3)
      assert asst2[:role] == "assistant"
      assert asst2[:content] == nil
      assert length(asst2[:tool_calls]) == 1
      assert hd(asst2[:tool_calls]).id == "tc-seq-2"

      # Turn 2: tool result
      tool2 = Enum.at(messages, 4)
      assert tool2[:role] == "tool"
      assert tool2[:tool_call_id] == "tc-seq-2"

      GenServer.stop(pid)
    end

    test "stops before final text-response turn when max_turns is tight" do
      # max_turns=1: only 1 turn allowed, should not reach the text-response turn
      CallerLLM.set_sequence([
        %{
          text: nil,
          tool_calls: [%{id: "tc-tight-1", name: :echo_tool, arguments: %{"input" => "x"}}]
        },
        %{text: "Would complete here but max_turns stops us", tool_calls: []}
      ])

      {:ok, pid} =
        Loop.start_link(CallerAgent, [%{role: "user", content: "go"}],
          llm_module: CallerLLM,
          run_id: "mt-tight-#{System.unique_integer([:positive])}",
          max_turns: 1,
          compaction_enabled: false
        )

      assert {:error, :max_turns_reached} = Loop.run_until_done(pid, 10_000)
      assert Loop.get_state(pid).turn_number == 1

      messages = Loop.get_messages(pid)

      # [user, assistant(tc-1), tool(result-1)]
      assert length(messages) == 3,
             "Expected 3 messages with max_turns=1, got #{length(messages)}"

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Edge: max_turns=1 (immediate boundary)
  # ===========================================================================

  describe "max_turns boundary edge cases" do
    test "max_turns=1 stops after first tool-call turn" do
      CallerLLM.set_response(%{
        text: nil,
        tool_calls: [%{id: "tc-edge-1", name: :echo_tool, arguments: %{"input" => "edge"}}]
      })

      {:ok, pid} =
        Loop.start_link(CallerAgent, [],
          llm_module: CallerLLM,
          run_id: "mt-edge-1-#{System.unique_integer([:positive])}",
          max_turns: 1,
          compaction_enabled: false
        )

      assert {:error, :max_turns_reached} = Loop.run_until_done(pid, 10_000)

      state = Loop.get_state(pid)
      assert state.turn_number == 1
      assert state.completed == false

      GenServer.stop(pid)
    end

    test "max_turns=0 raises or returns immediately" do
      CallerLLM.set_response(%{text: "Should not be called", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(CallerAgent, [],
          llm_module: CallerLLM,
          run_id: "mt-edge-0-#{System.unique_integer([:positive])}",
          max_turns: 0,
          compaction_enabled: false
        )

      # With max_turns=0, turn_number (0) >= max_turns (0) on first check
      result = Loop.run_until_done(pid, 5_000)

      # Either the loop returns immediately, or it's an error
      assert result == {:error, :max_turns_reached} or result == {:error, :invalid_config}

      state = Loop.get_state(pid)
      assert state.turn_number == 0
      assert state.completed == false

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

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
