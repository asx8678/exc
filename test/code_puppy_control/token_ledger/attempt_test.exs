defmodule CodePuppyControl.TokenLedger.AttemptTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TokenLedger.Attempt

  describe "new/3" do
    test "creates an attempt with defaults" do
      attempt = Attempt.new("run-1", "gpt-4o")

      assert attempt.run_id == "run-1"
      assert attempt.model == "gpt-4o"
      assert attempt.prompt_tokens == 0
      assert attempt.completion_tokens == 0
      assert attempt.cached_tokens == 0
      assert attempt.total_tokens == 0
      assert attempt.cost_cents == 0
      assert attempt.status == :ok
      assert attempt.session_id == nil
      assert is_integer(attempt.timestamp)
    end

    test "computes total_tokens from prompt + completion" do
      attempt = Attempt.new("run-1", "gpt-4o", prompt_tokens: 100, completion_tokens: 50)
      assert attempt.total_tokens == 150
    end

    test "preserves cached_tokens separately" do
      attempt =
        Attempt.new("run-1", "gpt-4o",
          prompt_tokens: 100,
          completion_tokens: 50,
          cached_tokens: 30
        )

      assert attempt.prompt_tokens == 100
      assert attempt.cached_tokens == 30
      assert attempt.total_tokens == 150
    end

    test "accepts session_id" do
      attempt = Attempt.new("run-1", "gpt-4o", session_id: "sess-123")
      assert attempt.session_id == "sess-123"
    end

    test "accepts explicit cost_cents" do
      attempt = Attempt.new("run-1", "gpt-4o", cost_cents: 42)
      assert attempt.cost_cents == 42
    end

    test "accepts explicit timestamp" do
      attempt = Attempt.new("run-1", "gpt-4o", timestamp: 1_700_000_000_000)
      assert attempt.timestamp == 1_700_000_000_000
    end

    test "accepts error status" do
      attempt = Attempt.new("run-1", "gpt-4o", status: :error)
      assert attempt.status == :error
    end
  end

  describe "to_map/1" do
    test "converts to string-keyed map" do
      attempt =
        Attempt.new("run-1", "gpt-4o",
          prompt_tokens: 100,
          completion_tokens: 50,
          cached_tokens: 20,
          session_id: "sess-1",
          cost_cents: 10
        )

      map = Attempt.to_map(attempt)

      assert map["run_id"] == "run-1"
      assert map["model"] == "gpt-4o"
      assert map["prompt_tokens"] == 100
      assert map["completion_tokens"] == 50
      assert map["cached_tokens"] == 20
      assert map["total_tokens"] == 150
      assert map["session_id"] == "sess-1"
      assert map["cost_cents"] == 10
      assert map["status"] == :ok
      assert is_integer(map["timestamp"])
    end

    test "preserves error status" do
      attempt = Attempt.new("run-1", "gpt-4o", status: :error)
      map = Attempt.to_map(attempt)
      assert map["status"] == :error
    end
  end

  describe "struct invariants" do
    test "enforces required keys" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Attempt, model: "gpt-4o")
      end

      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Attempt, run_id: "run-1")
      end
    end

    test "total_tokens is independent of cached_tokens" do
      # cached_tokens should NOT affect total_tokens
      attempt =
        Attempt.new("run-1", "gpt-4o",
          prompt_tokens: 100,
          completion_tokens: 50,
          cached_tokens: 80
        )

      # total = prompt + completion (cached is a subset of prompt, not additional)
      assert attempt.total_tokens == 150
      assert attempt.cached_tokens == 80
    end
  end
end
