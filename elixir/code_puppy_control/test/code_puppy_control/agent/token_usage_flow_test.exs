defmodule CodePuppyControl.Agent.TokenUsageFlowTest do
  @moduledoc """
  Integration test proving token usage data flows from LLM response
  through Agent.Loop to TokenLedger.

  Creates a mock LLM that returns realistic token counts, runs a single
  turn via Agent.Loop, then verifies TokenLedger recorded actual numbers
  (not zeros).

  Refs: code_puppy-4s8.7 (TokenLedger integration)
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop
  alias CodePuppyControl.TokenLedger

  # ---------------------------------------------------------------------------
  # Minimal mock agent — just enough for Loop.start_link
  # ---------------------------------------------------------------------------

  defmodule TokenTestAgent do
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :token_test_agent

    @impl true
    def system_prompt(_ctx), do: "You are a token-counting test agent."

    @impl true
    def allowed_tools, do: []

    @impl true
    def model_preference, do: "test-model"

    @impl true
    def on_tool_result(_tool, _result, state), do: {:cont, state}
  end

  # ---------------------------------------------------------------------------
  # Mock LLM that returns usage data in the response
  # ---------------------------------------------------------------------------

  defmodule UsageLLM do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.LLM

    @expected_usage %{
      prompt_tokens: 1500,
      completion_tokens: 300,
      cached_tokens: 200
    }

    @impl true
    def stream_chat(_messages, _tools, _opts, cb) do
      # Emit text via the normal provider-style callback events
      cb.({:part_start, %{type: :text, index: 0, id: nil}})

      cb.(
        {:part_delta,
         %{
           type: :text,
           index: 0,
           text: "Done counting tokens.",
           name: nil,
           arguments: nil
         }}
      )

      cb.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})

      cb.(
        {:done,
         %{
           id: "msg-usage-1",
           model: "test-model",
           content: nil,
           tool_calls: [],
           finish_reason: "stop",
           usage: @expected_usage
         }}
      )

      # Return value carries usage — this is what Streaming.accumulate_response reads
      {:ok,
       %{
         text: "Done counting tokens.",
         tool_calls: [],
         usage: @expected_usage
       }}
    end

    def expected_usage, do: @expected_usage
  end

  # ---------------------------------------------------------------------------
  # Mock LLM that returns usage via string keys (simulates OpenAI format)
  # ---------------------------------------------------------------------------

  defmodule StringKeyUsageLLM do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.LLM

    @expected_usage %{
      "prompt_tokens" => 2000,
      "completion_tokens" => 400,
      "cached_tokens" => 100
    }

    @impl true
    def stream_chat(_messages, _tools, _opts, cb) do
      cb.({:part_start, %{type: :text, index: 0, id: nil}})

      cb.(
        {:part_delta,
         %{
           type: :text,
           index: 0,
           text: "String-key usage response.",
           name: nil,
           arguments: nil
         }}
      )

      cb.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})

      cb.(
        {:done,
         %{
           id: "msg-str-1",
           model: "test-model",
           content: nil,
           tool_calls: [],
           finish_reason: "stop",
           usage: @expected_usage
         }}
      )

      {:ok,
       %{
         text: "String-key usage response.",
         tool_calls: [],
         usage: @expected_usage
       }}
    end

    def expected_usage, do: @expected_usage
  end

  # ---------------------------------------------------------------------------
  # Mock LLM with NO usage (baseline — verifies zeros when absent)
  # ---------------------------------------------------------------------------

  defmodule NoUsageLLM do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.LLM

    @impl true
    def stream_chat(_messages, _tools, _opts, cb) do
      cb.({:part_start, %{type: :text, index: 0, id: nil}})

      cb.(
        {:part_delta,
         %{
           type: :text,
           index: 0,
           text: "No usage data.",
           name: nil,
           arguments: nil
         }}
      )

      cb.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})

      cb.(
        {:done,
         %{
           id: "msg-nousage-1",
           model: "test-model",
           content: nil,
           tool_calls: [],
           finish_reason: "stop",
           usage: nil
         }}
      )

      {:ok, %{text: "No usage data.", tool_calls: []}}
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # Clear TokenLedger between tests — it's supervised by the app
    if Process.whereis(TokenLedger) do
      TokenLedger.clear()
    else
      {:ok, _pid} = TokenLedger.start_link()
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "token usage flow: LLM response → TokenLedger" do
    test "records prompt_tokens and completion_tokens from LLM response" do
      expected = UsageLLM.expected_usage()
      run_id = "token-flow-1"

      {:ok, pid} =
        Loop.start_link(TokenTestAgent, [%{role: "user", content: "Hello"}],
          run_id: run_id,
          llm_module: UsageLLM,
          max_turns: 1
        )

      result = Loop.run_until_done(pid, 10_000)
      assert result == :ok

      state = Loop.get_state(pid)
      assert state.completed == true
      assert state.turn_number == 1

      # Verify TokenLedger recorded the actual token counts
      summary = TokenLedger.run_summary(run_id)

      assert summary.total_attempts >= 1,
             "Expected at least 1 recorded attempt, got #{summary.total_attempts}"

      assert summary.prompt_tokens == expected.prompt_tokens,
             "Expected prompt_tokens=#{expected.prompt_tokens}, got #{summary.prompt_tokens}"

      assert summary.completion_tokens == expected.completion_tokens,
             "Expected completion_tokens=#{expected.completion_tokens}, got #{summary.completion_tokens}"

      assert summary.cached_tokens == expected.cached_tokens,
             "Expected cached_tokens=#{expected.cached_tokens}, got #{summary.cached_tokens}"

      assert summary.total_tokens == expected.prompt_tokens + expected.completion_tokens,
             "Expected total_tokens=#{expected.prompt_tokens + expected.completion_tokens}, got #{summary.total_tokens}"

      GenServer.stop(pid, :normal)
    end

    test "handles string-keyed usage (OpenAI format)" do
      expected = StringKeyUsageLLM.expected_usage()
      run_id = "token-flow-strkeys"

      {:ok, pid} =
        Loop.start_link(TokenTestAgent, [%{role: "user", content: "Hello"}],
          run_id: run_id,
          llm_module: StringKeyUsageLLM,
          max_turns: 1
        )

      result = Loop.run_until_done(pid, 10_000)
      assert result == :ok

      summary = TokenLedger.run_summary(run_id)

      assert summary.prompt_tokens == expected["prompt_tokens"],
             "Expected prompt_tokens=#{expected["prompt_tokens"]}, got #{summary.prompt_tokens}"

      assert summary.completion_tokens == expected["completion_tokens"],
             "Expected completion_tokens=#{expected["completion_tokens"]}, got #{summary.completion_tokens}"

      assert summary.cached_tokens == expected["cached_tokens"],
             "Expected cached_tokens=#{expected["cached_tokens"]}, got #{summary.cached_tokens}"

      GenServer.stop(pid, :normal)
    end

    test "records zeros when LLM returns no usage data" do
      run_id = "token-flow-nousage"

      {:ok, pid} =
        Loop.start_link(TokenTestAgent, [%{role: "user", content: "Hello"}],
          run_id: run_id,
          llm_module: NoUsageLLM,
          max_turns: 1
        )

      result = Loop.run_until_done(pid, 10_000)
      assert result == :ok

      summary = TokenLedger.run_summary(run_id)

      assert summary.prompt_tokens == 0,
             "Expected prompt_tokens=0 when no usage, got #{summary.prompt_tokens}"

      assert summary.completion_tokens == 0,
             "Expected completion_tokens=0 when no usage, got #{summary.completion_tokens}"

      assert summary.cached_tokens == 0,
             "Expected cached_tokens=0 when no usage, got #{summary.cached_tokens}"

      GenServer.stop(pid, :normal)
    end

    test "records usage with correct model name from agent" do
      run_id = "token-flow-model"

      {:ok, pid} =
        Loop.start_link(TokenTestAgent, [%{role: "user", content: "Hello"}],
          run_id: run_id,
          llm_module: UsageLLM,
          max_turns: 1
        )

      result = Loop.run_until_done(pid, 10_000)
      assert result == :ok

      summary = TokenLedger.run_summary(run_id)

      # TokenTestAgent.model_preference() returns "test-model"
      assert "test-model" in summary.models_used,
             "Expected 'test-model' in models_used, got #{inspect(summary.models_used)}"

      GenServer.stop(pid, :normal)
    end
  end
end
