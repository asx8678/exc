defmodule CodePuppyControl.TokenLedger.LedgerTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.TokenLedger

  setup do
    # Clear the ledger instead of restarting it.
    # TokenLedger is supervised by the application - we must not kill it.
    if Process.whereis(TokenLedger) do
      TokenLedger.clear()
    else
      {:ok, _pid} = TokenLedger.start_link()
    end

    :ok
  end

  describe "record_attempt/3" do
    test "records a basic attempt" do
      assert :ok =
               TokenLedger.record_attempt("run-1", "gpt-4o",
                 prompt_tokens: 100,
                 completion_tokens: 50
               )

      summary = TokenLedger.run_summary("run-1")
      assert summary.total_attempts == 1
      assert summary.prompt_tokens == 100
      assert summary.completion_tokens == 50
      assert summary.total_tokens == 150
    end

    test "records multiple attempts for same run" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100, completion_tokens: 50)
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 200, completion_tokens: 100)
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 50, completion_tokens: 25)

      summary = TokenLedger.run_summary("run-1")
      assert summary.total_attempts == 3
      assert summary.prompt_tokens == 350
      assert summary.completion_tokens == 175
      assert summary.total_tokens == 525
      assert summary.successful == 3
      assert summary.failed == 0
    end

    test "records attempts for different runs" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100)
      TokenLedger.record_attempt("run-2", "gpt-4o", prompt_tokens: 200)

      assert TokenLedger.run_summary("run-1").prompt_tokens == 100
      assert TokenLedger.run_summary("run-2").prompt_tokens == 200
    end

    test "auto-computes cost when not specified" do
      TokenLedger.record_attempt("run-1", "gpt-4o-2024-11-20", prompt_tokens: 1_000_000)

      summary = TokenLedger.run_summary("run-1")
      assert summary.cost_cents == 250
    end

    test "accepts explicit cost_cents" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100, cost_cents: 999)

      summary = TokenLedger.run_summary("run-1")
      assert summary.cost_cents == 999
    end

    test "tracks cached tokens" do
      TokenLedger.record_attempt("run-1", "gpt-4o",
        prompt_tokens: 1000,
        completion_tokens: 500,
        cached_tokens: 300
      )

      summary = TokenLedger.run_summary("run-1")
      assert summary.prompt_tokens == 1000
      assert summary.cached_tokens == 300
      assert summary.total_tokens == 1500
    end

    test "tracks failed attempts" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100, status: :error)

      summary = TokenLedger.run_summary("run-1")
      assert summary.total_attempts == 1
      assert summary.successful == 0
      assert summary.failed == 1
    end

    test "tracks mixed success/failure" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100, status: :ok)
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 200, status: :error)
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 50, status: :ok)

      summary = TokenLedger.run_summary("run-1")
      assert summary.total_attempts == 3
      assert summary.successful == 2
      assert summary.failed == 1
    end

    test "tracks models used" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100)
      TokenLedger.record_attempt("run-1", "claude-sonnet-4-20250514", prompt_tokens: 100)

      summary = TokenLedger.run_summary("run-1")
      assert MapSet.member?(summary.models_used, "gpt-4o")
      assert MapSet.member?(summary.models_used, "claude-sonnet-4-20250514")
    end
  end

  describe "session_summary/1" do
    test "aggregates across runs in a session" do
      TokenLedger.record_attempt("run-1", "gpt-4o",
        session_id: "sess-1",
        prompt_tokens: 100,
        completion_tokens: 50
      )

      TokenLedger.record_attempt("run-2", "gpt-4o",
        session_id: "sess-1",
        prompt_tokens: 200,
        completion_tokens: 100
      )

      summary = TokenLedger.session_summary("sess-1")
      assert summary.total_attempts == 2
      assert summary.prompt_tokens == 300
      assert summary.completion_tokens == 150
      assert summary.total_tokens == 450
    end

    test "does not mix sessions" do
      TokenLedger.record_attempt("run-1", "gpt-4o", session_id: "sess-1", prompt_tokens: 100)
      TokenLedger.record_attempt("run-2", "gpt-4o", session_id: "sess-2", prompt_tokens: 200)

      assert TokenLedger.session_summary("sess-1").prompt_tokens == 100
      assert TokenLedger.session_summary("sess-2").prompt_tokens == 200
    end

    test "handles nil session_id" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100)
      assert TokenLedger.session_summary("nonexistent").total_attempts == 0
    end

    test "returns empty summary for unknown session" do
      summary = TokenLedger.session_summary("unknown-session")
      assert summary.total_attempts == 0
      assert summary.prompt_tokens == 0
    end
  end

  describe "model_rollup/1" do
    test "aggregates across all runs for a model" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100, completion_tokens: 50)
      TokenLedger.record_attempt("run-2", "gpt-4o", prompt_tokens: 200, completion_tokens: 100)

      rollup = TokenLedger.model_rollup("gpt-4o")
      assert rollup.total_attempts == 2
      assert rollup.prompt_tokens == 300
      assert rollup.completion_tokens == 150
    end

    test "separates models" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100)
      TokenLedger.record_attempt("run-1", "claude-sonnet-4-20250514", prompt_tokens: 200)

      gpt_rollup = TokenLedger.model_rollup("gpt-4o")
      claude_rollup = TokenLedger.model_rollup("claude-sonnet-4-20250514")

      assert gpt_rollup.prompt_tokens == 100
      assert claude_rollup.prompt_tokens == 200
    end

    test "returns empty summary for unknown model" do
      rollup = TokenLedger.model_rollup("unknown-model")
      assert rollup.total_attempts == 0
    end
  end

  describe "run_attempts/1" do
    test "returns all attempts for a run" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100)
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 200)
      TokenLedger.record_attempt("run-2", "gpt-4o", prompt_tokens: 50)

      attempts = TokenLedger.run_attempts("run-1")
      assert length(attempts) == 2
      assert Enum.all?(attempts, fn a -> a.run_id == "run-1" end)
    end

    test "returns empty list for unknown run" do
      assert TokenLedger.run_attempts("unknown") == []
    end
  end

  describe "concurrent writes" do
    test "handles concurrent record_attempt calls" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            TokenLedger.record_attempt("run-concurrent", "gpt-4o",
              prompt_tokens: i,
              completion_tokens: i * 2
            )
          end)
        end

      Task.await_many(tasks, 5_000)

      summary = TokenLedger.run_summary("run-concurrent")
      assert summary.total_attempts == 50
      assert summary.prompt_tokens == 1275
      assert summary.completion_tokens == 2550
    end

    test "handles concurrent writes from different runs" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            run_id = "run-#{rem(i, 3)}"
            TokenLedger.record_attempt(run_id, "gpt-4o", prompt_tokens: 100)
          end)
        end

      Task.await_many(tasks, 5_000)

      for run_id <- ["run-0", "run-1", "run-2"] do
        summary = TokenLedger.run_summary(run_id)
        assert summary.total_attempts > 0
      end
    end
  end

  describe "clear/0" do
    test "clears all data" do
      TokenLedger.record_attempt("run-1", "gpt-4o", prompt_tokens: 100)
      TokenLedger.record_attempt("run-2", "gpt-4o", session_id: "sess-1", prompt_tokens: 200)

      TokenLedger.clear()

      assert TokenLedger.run_summary("run-1").total_attempts == 0
      assert TokenLedger.run_summary("run-2").total_attempts == 0
      assert TokenLedger.session_summary("sess-1").total_attempts == 0
      assert TokenLedger.model_rollup("gpt-4o").total_attempts == 0
    end
  end
end
