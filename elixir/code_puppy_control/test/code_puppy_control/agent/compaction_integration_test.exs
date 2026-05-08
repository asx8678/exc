defmodule CodePuppyControl.Agent.CompactionIntegrationTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop

  # ---------------------------------------------------------------------------
  # Mock Agent Module
  # ---------------------------------------------------------------------------

  defmodule TestAgent do
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :compaction_test_agent

    @impl true
    def system_prompt(_ctx), do: "You are a compaction test agent."

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
      case Agent.start(fn -> %{} end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def set_response(response) do
      Agent.update(__MODULE__, fn _ -> %{response: response} end)
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
      response = Agent.get(__MODULE__, fn state -> state.response end)

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
  # Helpers
  # ---------------------------------------------------------------------------

  defp parts_message(i) do
    %{
      "parts" => [
        %{
          "part_kind" => "text",
          "content" =>
            "Message number #{i}. This is a message with enough content " <>
              "to have reasonable token estimates for the compaction algorithm."
        }
      ]
    }
  end

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

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    {:ok, _pid} = MockLLM.start_link()
    on_exit(fn -> MockLLM.stop() end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests — Compaction Configuration
  # ---------------------------------------------------------------------------

  describe "compaction configuration" do
    test "compaction is enabled by default" do
      {:ok, pid} = Loop.start_link(TestAgent, [], llm_module: MockLLM, run_id: "cfg-1")
      state = Loop.get_state(pid)
      assert state.compaction_enabled == true
      GenServer.stop(pid)
    end

    test "compaction can be disabled via start opts" do
      {:ok, pid} =
        Loop.start_link(TestAgent, [],
          llm_module: MockLLM,
          run_id: "cfg-2",
          compaction_enabled: false
        )

      state = Loop.get_state(pid)
      assert state.compaction_enabled == false
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Compaction Triggered During Loop
  # ---------------------------------------------------------------------------

  describe "compaction during loop execution" do
    test "compaction is triggered when message count exceeds threshold" do
      run_id = "compact-trigger-1"

      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")
      Process.sleep(10)

      # 160 messages in parts format — above default trigger of 150
      messages = for i <- 1..160, do: parts_message(i)

      MockLLM.set_response(%{text: "Done!", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, messages,
          llm_module: MockLLM,
          run_id: run_id
        )

      :ok = Loop.run_turn(pid)

      events = collect_events(500)

      compacted_event =
        Enum.find(events, fn e -> e[:type] == "agent_messages_compacted" end)

      assert compacted_event != nil,
             "Expected agent_messages_compacted event, got: #{inspect(Enum.map(events, & &1[:type]))}"

      assert compacted_event[:stats][:original_count] == 160
      assert compacted_event[:stats][:compacted_count] < 160

      state = Loop.get_state(pid)
      # Messages should be reduced after compaction (+ 1 for assistant)
      assert state.message_count < 161

      GenServer.stop(pid)
    end

    test "compaction is NOT triggered when message count is below threshold" do
      run_id = "compact-no-trigger-1"

      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")
      Process.sleep(10)

      # Only 10 messages — well below default trigger of 150
      messages = for i <- 1..10, do: parts_message(i)

      MockLLM.set_response(%{text: "Done!", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, messages,
          llm_module: MockLLM,
          run_id: run_id
        )

      :ok = Loop.run_turn(pid)

      events = collect_events(500)

      compacted_event =
        Enum.find(events, fn e -> e[:type] == "agent_messages_compacted" end)

      assert compacted_event == nil, "Should not compact with only 10 messages"

      state = Loop.get_state(pid)
      # 10 original + 1 assistant
      assert state.message_count == 11

      GenServer.stop(pid)
    end

    test "compaction respects custom trigger_messages from compaction_opts" do
      run_id = "compact-custom-trigger-1"

      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")
      Process.sleep(10)

      # 30 messages with parts format (below default 150 but above custom trigger of 20)
      messages = for i <- 1..30, do: parts_message(i)

      MockLLM.set_response(%{text: "Done!", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, messages,
          llm_module: MockLLM,
          run_id: run_id,
          compaction_opts: [trigger_messages: 20, min_keep: 5]
        )

      :ok = Loop.run_turn(pid)

      events = collect_events(500)

      compacted_event =
        Enum.find(events, fn e -> e[:type] == "agent_messages_compacted" end)

      assert compacted_event != nil,
             "Expected compaction with custom trigger_messages: 20"

      assert compacted_event[:stats][:original_count] == 30

      GenServer.stop(pid)
    end

    test "compaction can be disabled and messages pass through unchanged" do
      run_id = "compact-disabled-1"

      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")
      Process.sleep(10)

      # 160 messages (above default trigger, but compaction is disabled)
      messages = for i <- 1..160, do: parts_message(i)

      MockLLM.set_response(%{text: "Done!", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, messages,
          llm_module: MockLLM,
          run_id: run_id,
          compaction_enabled: false
        )

      :ok = Loop.run_turn(pid)

      events = collect_events(500)

      compacted_event =
        Enum.find(events, fn e -> e[:type] == "agent_messages_compacted" end)

      assert compacted_event == nil, "Should not compact when compaction_enabled: false"

      state = Loop.get_state(pid)
      # 160 original + 1 assistant
      assert state.message_count == 161

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Compaction Event Shape
  # ---------------------------------------------------------------------------

  describe "compaction event shape" do
    test "event contains all expected stat fields" do
      run_id = "compact-event-shape-1"

      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")
      Process.sleep(10)

      messages = for i <- 1..160, do: parts_message(i)

      MockLLM.set_response(%{text: "Done!", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, messages,
          llm_module: MockLLM,
          run_id: run_id
        )

      :ok = Loop.run_turn(pid)

      events = collect_events(500)

      compacted_event =
        Enum.find(events, fn e -> e[:type] == "agent_messages_compacted" end)

      assert compacted_event != nil

      stats = compacted_event[:stats]
      assert Map.has_key?(stats, :original_count)
      assert Map.has_key?(stats, :compacted_count)
      assert Map.has_key?(stats, :dropped_by_filter)
      assert Map.has_key?(stats, :truncated_count)
      assert Map.has_key?(stats, :summarize_count)
      assert Map.has_key?(stats, :protected_count)

      assert compacted_event[:run_id] == run_id

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Compaction Across Multiple Turns
  # ---------------------------------------------------------------------------

  describe "compaction across multiple turns" do
    test "compaction runs each turn if messages stay above threshold" do
      run_id = "compact-multi-1"

      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")
      Process.sleep(10)

      messages = for i <- 1..160, do: parts_message(i)

      # Tool call response keeps the loop going
      MockLLM.set_response(%{
        text: "Using tool",
        tool_calls: [%{id: "tc-1", name: :echo_tool, arguments: %{"input" => "hi"}}]
      })

      {:ok, pid} =
        Loop.start_link(TestAgent, messages,
          llm_module: MockLLM,
          run_id: run_id,
          max_turns: 3
        )

      {:error, :max_turns_reached} = Loop.run_until_done(pid, 10_000)

      events = collect_events(500)

      compacted_events =
        Enum.filter(events, fn e -> e[:type] == "agent_messages_compacted" end)

      # Should have at least one compaction event
      assert length(compacted_events) >= 1

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Edge Cases
  # ---------------------------------------------------------------------------

  describe "compaction edge cases" do
    test "compaction with empty initial messages does not crash" do
      run_id = "compact-empty-1"

      MockLLM.set_response(%{text: "Done!", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, [],
          llm_module: MockLLM,
          run_id: run_id
        )

      :ok = Loop.run_turn(pid)

      state = Loop.get_state(pid)
      # 0 original + 1 assistant
      assert state.message_count == 1

      GenServer.stop(pid)
    end

    test "compaction runs with message format using parts key" do
      run_id = "compact-parts-1"

      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")
      Process.sleep(10)

      messages = for i <- 1..160, do: parts_message(i)

      MockLLM.set_response(%{text: "Done!", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(TestAgent, messages,
          llm_module: MockLLM,
          run_id: run_id
        )

      :ok = Loop.run_turn(pid)

      events = collect_events(500)

      compacted_event =
        Enum.find(events, fn e -> e[:type] == "agent_messages_compacted" end)

      assert compacted_event != nil

      state = Loop.get_state(pid)
      assert state.message_count < 161

      GenServer.stop(pid)
    end
  end
end
