defmodule CodePuppyControl.Agent.CompactionRecoveryTest do
  @moduledoc """
  Regression tests for compaction recovery in Agent.Loop.

  Before the code-puppy-3o7.9.1 B1 fix, when the BudgetEnforcer detected
  :context_budget_exceeded before an LLM call, do_llm_stream/2 called
  Compaction.compact_messages/1 but discarded the result (assigned to
  unused _state_compacted). The turn was immediately failed with no retry,
  wasting the compaction effort and never calling the LLM.

  The fix extracts budget-check + LLM-call logic into
  do_llm_stream_with_budget_check/3, parameterized by an attempt atom:
  - On :first_attempt with :context_budget_exceeded: capture compacted state
    and recurse with :second_attempt so the LLM receives compacted messages.
  - On :second_attempt with :context_budget_exceeded: fail the turn
    (at most one retry).
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop

  # ---------------------------------------------------------------------------
  # Mock Agent Module
  # ---------------------------------------------------------------------------

  defmodule RecoveryTestAgent do
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :compaction_recovery_agent

    @impl true
    def system_prompt(_ctx), do: "You are a compaction recovery test agent."

    @impl true
    def allowed_tools, do: [:echo_tool]

    @impl true
    def model_preference, do: "test-model"

    @impl true
    def on_tool_result(_tool, _result, state), do: {:cont, state}
  end

  # ---------------------------------------------------------------------------
  # Recording Mock LLM — records messages it receives via ETS
  # ---------------------------------------------------------------------------

  defmodule RecordingMockLLM do
    @moduledoc false
    @table :compaction_recovery_mock_llm_ets

    @behaviour CodePuppyControl.Agent.LLM

    def setup do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      else
        :ets.delete_all_objects(@table)
      end

      :ets.insert(@table, {:call_count, 0})
      :ets.insert(@table, {:last_messages, nil})
      :ok
    end

    def set_response(response) do
      :ets.insert(@table, {:response, response})
      :ok
    end

    @spec get_call_count() :: non_neg_integer()
    def get_call_count do
      case :ets.lookup(@table, :call_count) do
        [{:call_count, count}] -> count
        [] -> 0
      end
    end

    @spec get_last_messages() :: [map()] | nil
    def get_last_messages do
      case :ets.lookup(@table, :last_messages) do
        [{:last_messages, msgs}] -> msgs
        [] -> nil
      end
    end

    @impl true
    def stream_chat(messages, _tools, _opts, callback_fn) do
      count =
        case :ets.lookup(@table, :call_count) do
          [{:call_count, c}] -> c
          [] -> 0
        end

      :ets.insert(@table, {:call_count, count + 1})
      :ets.insert(@table, {:last_messages, messages})

      response =
        case :ets.lookup(@table, :response) do
          [{:response, resp}] -> resp
          [] -> %{text: "Default response", tool_calls: []}
        end

      case response do
        %{text: text, tool_calls: tool_calls} when is_list(tool_calls) ->
          if is_binary(text) and text != "", do: callback_fn.({:text, text})

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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Create a message with both "content" (for MessageProcessor token estimation
  # used by BudgetEnforcer) and "parts" (for Estimator.estimate_message_tokens
  # used by Compaction's split phase).
  #
  # Each message has ~25K chars of content:
  # - MessageProcessor.estimate_message_tokens ≈ ceil(25000 / 2.5) = 10_000 tokens
  # - Estimator.estimate_message_tokens ≈ ceil(25000 / 4.0) ≈ 6_250 tokens
  defp big_message(i, char_count \\ 25_000) do
    text = String.duplicate("x", char_count) <> " msg #{i}"

    %{
      "role" => "user",
      "content" => text,
      "parts" => [%{"part_kind" => "text", "content" => text}]
    }
  end

  setup do
    RecordingMockLLM.setup()
    RecordingMockLLM.set_response(%{text: "Compaction recovery response", tool_calls: []})
    :ok
  end

  # ===========================================================================
  # Primary Regression Test
  # ===========================================================================

  describe "compaction recovery regression (code-puppy-3o7.9.1 B1 fix)" do
    @tag capture_log: true
    test "after budget-exceeded compaction, LLM is called with compacted messages" do
      run_id = "compact-recovery-#{System.unique_integer([:positive])}"

      # 60 messages with ~25K chars each:
      #   MessageProcessor.estimate_batch_tokens ≈ 60 × 10_000 = 600K
      #   BudgetEnforcer safe_limit = floor(128_000 × 0.9) = 115_200
      #   600K + 4096 > 115_200 → context_budget_exceeded on first attempt
      #
      #   After Path A compaction (count-based, keep ~12 messages):
      #     12 × 10_000 = 120K + 4096 > 115_200 → still exceeded
      #
      #   After Path B compaction (budget-recovery, keep ~3 messages):
      #     3 × 10_000 = 30K + 4096 < 115_200 → passes, LLM called
      messages = for i <- 1..60, do: big_message(i)

      {:ok, pid} =
        Loop.start_link(RecoveryTestAgent, messages,
          llm_module: RecordingMockLLM,
          run_id: run_id,
          compaction_opts: [trigger_messages: 50, keep_fraction: 0.2, min_keep: 3],
          max_turns: 1
        )

      # BEFORE THE FIX: run_turn returned {:error, {:context_budget_exceeded, _}}
      # because the compacted state was discarded and the turn failed immediately.
      # AFTER THE FIX: compaction recovery retries and the LLM is called.
      result = Loop.run_turn(pid)

      assert result == :ok,
             "Expected :ok after compaction recovery, got: #{inspect(result)}. " <>
               "This would fail before the B1 fix — compacted state was discarded."

      # Verify the LLM was actually called (before the fix, it wouldn't be)
      assert RecordingMockLLM.get_call_count() >= 1,
             "LLM must be called at least once after compaction recovery. " <>
               "Before the B1 fix, the LLM was never called — compacted state was discarded."

      # Verify the LLM received compacted messages, not the original 60
      llm_messages = RecordingMockLLM.get_last_messages()

      assert length(llm_messages) < 60,
             "LLM should receive compacted messages (#{length(llm_messages)}), " <>
               "not the original 60. This would fail before the B1 fix — " <>
               "compacted state was discarded so LLM was never called."

      # Compaction should reduce to a small fraction of original count
      assert length(llm_messages) <= 15,
             "Two-stage compaction (count-based + budget-recovery) should " <>
               "reduce messages to <= 15, got #{length(llm_messages)}"

      GenServer.stop(pid)
    end

    @tag capture_log: true
    test "compaction recovery produces a successful agent response" do
      run_id = "compact-recovery-response-#{System.unique_integer([:positive])}"

      messages = for i <- 1..60, do: big_message(i)

      {:ok, pid} =
        Loop.start_link(RecoveryTestAgent, messages,
          llm_module: RecordingMockLLM,
          run_id: run_id,
          compaction_opts: [trigger_messages: 50, keep_fraction: 0.2, min_keep: 3],
          max_turns: 1
        )

      assert :ok = Loop.run_turn(pid)

      # The loop state should reflect the completed turn
      state = Loop.get_state(pid)
      assert state.turn_number == 1
      assert state.completed == true

      # Final messages include the assistant response after compaction
      final_messages = Loop.get_messages(pid)

      assistant_texts =
        final_messages
        |> Enum.filter(fn m -> m[:role] == "assistant" end)
        |> Enum.map(fn m -> m[:content] end)
        |> Enum.filter(&is_binary/1)

      assert "Compaction recovery response" in assistant_texts,
             "Assistant response must appear in final messages after compaction recovery. " <>
               "Got: #{inspect(assistant_texts)}"

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Retry-Limit Test
  # ===========================================================================

  describe "compaction recovery retry limit" do
    @tag capture_log: true
    test "turn fails when budget still exceeded after compaction retry" do
      run_id = "compact-recovery-fail-#{System.unique_integer([:positive])}"

      # 60 messages with high min_keep (15) prevents effective second compaction:
      #   After Path A: max(0.2 × 60, 15) = 15 messages
      #   Budget: 15 × 10_000 = 150K > 111K → still exceeded
      #   After Path B: max(0.2 × 15, 15) = 15 messages (min_keep dominates)
      #   Budget: 15 × 10_000 = 150K > 111K → STILL exceeded on second attempt
      #   → Turn fails with context_budget_exceeded
      messages = for i <- 1..60, do: big_message(i)

      {:ok, pid} =
        Loop.start_link(RecoveryTestAgent, messages,
          llm_module: RecordingMockLLM,
          run_id: run_id,
          compaction_opts: [trigger_messages: 50, keep_fraction: 0.2, min_keep: 15],
          max_turns: 1
        )

      result = Loop.run_turn(pid)

      assert {:error, {:context_budget_exceeded, _msg}} = result,
             "Expected context_budget_exceeded after compaction recovery fails, " <>
               "got: #{inspect(result)}. The fix allows exactly one retry — " <>
               "if budget still exceeded, turn must fail."

      # LLM should NOT have been called (budget exceeded even after retry)
      assert RecordingMockLLM.get_call_count() == 0,
             "LLM should not be called when budget remains exceeded after " <>
               "compaction retry. Got #{RecordingMockLLM.get_call_count()} calls."

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Normal Path — No Budget Exceeded
  # ===========================================================================

  describe "compaction without budget exceeded" do
    @tag capture_log: true
    test "normal compaction path when budget is not exceeded" do
      run_id = "compact-normal-#{System.unique_integer([:positive])}"

      # 60 messages with SMALL content — compaction triggers (count > 50)
      # but budget never exceeds (total tokens ≈ 60 × 4 = 240 << 111K)
      small_msg = fn i ->
        %{
          "role" => "user",
          "content" => "small message #{i}",
          "parts" => [%{"part_kind" => "text", "content" => "small message #{i}"}]
        }
      end

      messages = for i <- 1..60, do: small_msg.(i)

      {:ok, pid} =
        Loop.start_link(RecoveryTestAgent, messages,
          llm_module: RecordingMockLLM,
          run_id: run_id,
          compaction_opts: [trigger_messages: 50, keep_fraction: 0.2, min_keep: 10],
          max_turns: 1
        )

      # Should complete normally — no budget recovery needed
      assert :ok = Loop.run_turn(pid)

      # LLM called exactly once (no budget-recovery retry)
      assert RecordingMockLLM.get_call_count() == 1,
             "LLM should be called exactly once when budget is fine. " <>
               "Got #{RecordingMockLLM.get_call_count()} calls."

      GenServer.stop(pid)
    end
  end
end
