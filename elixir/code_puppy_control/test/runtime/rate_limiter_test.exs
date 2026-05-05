defmodule CodePuppyControl.Runtime.RateLimiterTest do
  @moduledoc """
  Tests for RateLimiter — adaptive token-bucket rate limiting with
  circuit breaker.

  Validates acquire/release, 429 handling, capacity adaptation, and
  circuit breaker state transitions.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.RateLimiter
  alias CodePuppyControl.RateLimiter.{Bucket, Adaptive}

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RateLimiter)
    RateLimiter.clear()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Acquire
  # ---------------------------------------------------------------------------

  describe "acquire/2" do
    test "returns :ok when capacity is available" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 200_000)
      assert :ok = RateLimiter.acquire("test-model")
    end

    test "returns :ok without explicit set_limits (auto-creates)" do
      # acquire should auto-create buckets with defaults
      result = RateLimiter.acquire("auto-model")
      assert result == :ok or match?({:wait, _}, result)
    end

    test "returns {:wait, ms} when RPM bucket is exhausted" do
      RateLimiter.set_limits("low-rpm", rpm: 1, tpm: 200_000)

      # First acquire should succeed
      assert :ok = RateLimiter.acquire("low-rpm")

      # Second should be rate-limited
      result = RateLimiter.acquire("low-rpm")
      assert match?({:wait, _ms}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Record Response
  # ---------------------------------------------------------------------------

  describe "record_response/3" do
    test "records 429 and opens circuit" do
      RateLimiter.set_limits("429-model", rpm: 60, tpm: 200_000)

      RateLimiter.record_response("429-model", 429, [])
      RateLimiter.ping()

      # Circuit should be open
      assert RateLimiter.circuit_open?("429-model")
    end

    test "records 200 and does not open circuit" do
      RateLimiter.set_limits("ok-model", rpm: 60, tpm: 200_000)

      RateLimiter.record_response("ok-model", 200, [])
      RateLimiter.ping()

      refute RateLimiter.circuit_open?("ok-model")
    end

    test "non-4xx/200 errors do not affect circuit" do
      RateLimiter.set_limits("err-model", rpm: 60, tpm: 200_000)

      RateLimiter.record_response("err-model", 500, [])
      RateLimiter.ping()

      refute RateLimiter.circuit_open?("err-model")
    end
  end

  # ---------------------------------------------------------------------------
  # Stats
  # ---------------------------------------------------------------------------

  describe "stats/1" do
    test "returns stats map with expected keys" do
      RateLimiter.set_limits("stats-model", rpm: 60, tpm: 200_000)

      stats = RateLimiter.stats("stats-model")

      assert Map.has_key?(stats, :model_name)
      assert Map.has_key?(stats, :rpm)
      assert Map.has_key?(stats, :tpm)
      assert Map.has_key?(stats, :circuit_state)
      assert Map.has_key?(stats, :capacity_ratio)
      assert Map.has_key?(stats, :total_429s)
    end
  end

  # ---------------------------------------------------------------------------
  # Clear
  # ---------------------------------------------------------------------------

  describe "clear/0" do
    test "clears all rate limiter state" do
      RateLimiter.set_limits("clear-model", rpm: 60, tpm: 200_000)
      RateLimiter.record_response("clear-model", 429, [])

      # Flush the GenServer mailbox before calling clear/0.
      # record_response/3 for 429s sends an async cast — if clear/0
      # runs before the GenServer processes the cast, the cast handler
      # will re-insert :open state into ETS after clear wipes it.
      # A synchronous ping forces the cast to be processed first.
      :pong = RateLimiter.ping()

      RateLimiter.clear()

      # After clear, circuit should not be open
      refute RateLimiter.circuit_open?("clear-model")
    end
  end

  # ---------------------------------------------------------------------------
  # Bucket (unit-level)
  # ---------------------------------------------------------------------------

  describe "Bucket operations" do
    setup do
      # Create the ETS table if not exists
      if :ets.whereis(:rate_limiter_buckets) == :undefined do
        Bucket.create_table()
      else
        Bucket.clear()
      end

      :ok
    end

    test "init_bucket creates bucket with full tokens" do
      clock = fn -> 0 end
      :ok = Bucket.init_bucket({"test", :rpm}, 60, clock)

      assert {:ok, %{tokens: 60, capacity: 60}} = Bucket.info({"test", :rpm})
    end

    test "take decrements tokens" do
      clock = fn -> 0 end
      Bucket.init_bucket({"take-test", :rpm}, 10, clock)

      assert :ok = Bucket.take({"take-test", :rpm}, 1, clock)

      {:ok, info} = Bucket.info({"take-test", :rpm})
      assert info.tokens == 9
    end

    test "take returns {:wait, ms} when insufficient tokens" do
      clock = fn -> 0 end
      Bucket.init_bucket({"empty-test", :rpm}, 1, clock)

      # Take the one available token
      assert :ok = Bucket.take({"empty-test", :rpm}, 1, clock)

      # Now bucket is empty, next take should wait
      assert {:wait, _ms} = Bucket.take({"empty-test", :rpm}, 1, clock)
    end

    test "refill adds tokens up to capacity" do
      clock = fn -> 0 end
      Bucket.init_bucket({"refill-test", :rpm}, 10, clock)

      # Consume all tokens
      Bucket.take({"refill-test", :rpm}, 10, clock)

      # Refill with some time passed
      later_clock = fn -> 1_000 end
      Bucket.refill({"refill-test", :rpm}, 1.0, later_clock)

      {:ok, info} = Bucket.info({"refill-test", :rpm})
      assert info.tokens > 0
      assert info.tokens <= 10
    end

    test "tokens never exceed capacity after refill" do
      clock = fn -> 0 end
      Bucket.init_bucket({"cap-test", :rpm}, 5, clock)

      # Wait a very long time (should cap at capacity)
      later_clock = fn -> 1_000_000_000 end
      Bucket.refill({"cap-test", :rpm}, 1.0, later_clock)

      {:ok, info} = Bucket.info({"cap-test", :rpm})
      assert info.tokens <= 5
    end

    test "set_capacity updates capacity and caps tokens" do
      clock = fn -> 0 end
      Bucket.init_bucket({"cap-update", :rpm}, 100, clock)

      :ok = Bucket.set_capacity({"cap-update", :rpm}, 50)

      {:ok, info} = Bucket.info({"cap-update", :rpm})
      assert info.capacity == 50
      assert info.tokens <= 50
    end
  end

  # ---------------------------------------------------------------------------
  # Adaptive (unit-level)
  # ---------------------------------------------------------------------------

  describe "Adaptive circuit breaker" do
    setup do
      if :ets.whereis(:rate_limiter_circuits) == :undefined do
        Adaptive.create_table()
      else
        Adaptive.clear()
      end

      :ok
    end

    test "initial state is closed with full capacity" do
      Adaptive.ensure("init-model", fn -> 0 end)

      assert {:ok, info} = Adaptive.info("init-model")
      assert info.circuit_state == :closed
      assert info.capacity_ratio == 1.0
    end

    test "on_rate_limit opens circuit and halves capacity" do
      Adaptive.ensure("429-model", fn -> 0 end)

      {:open, _cooldown} =
        Adaptive.on_rate_limit("429-model",
          cooldown_ms: 10_000,
          min_capacity: 1,
          nominal_capacity: 60
        )

      assert {:ok, info} = Adaptive.info("429-model")
      assert info.circuit_state == :open
      assert info.capacity_ratio < 1.0
      assert info.total_429s == 1
    end

    test "on_success closes half-open circuit" do
      Adaptive.ensure("half-open-model", fn -> 0 end)

      # Open the circuit first
      Adaptive.on_rate_limit("half-open-model",
        cooldown_ms: 10_000,
        min_capacity: 1,
        nominal_capacity: 60
      )

      # Manually set to half_open
      :ets.update_element(:rate_limiter_circuits, "half-open-model", {2, :half_open})

      # Success should close it
      new_state = Adaptive.on_success("half-open-model")
      assert new_state == :closed
    end

    test "maybe_half_open transitions open → half_open after cooldown" do
      now = System.monotonic_time()
      Adaptive.ensure("cooldown-model", fn -> now end)

      # Open with a short cooldown
      Adaptive.on_rate_limit("cooldown-model",
        cooldown_ms: 1,
        min_capacity: 1,
        nominal_capacity: 60
      )

      # Wait a moment for cooldown to expire
      Process.sleep(50)

      result =
        Adaptive.maybe_half_open("cooldown-model",
          cooldown_ms: 1,
          clock: fn -> System.monotonic_time() end
        )

      assert result == :half_open
    end

    test "capacity_ratio never goes below min_capacity/nominal ratio" do
      Adaptive.ensure("min-ratio-model", fn -> 0 end)

      # Hit with multiple 429s
      for _ <- 1..10 do
        Adaptive.on_rate_limit("min-ratio-model",
          cooldown_ms: 10_000,
          min_capacity: 1,
          nominal_capacity: 60
        )
      end

      assert {:ok, info} = Adaptive.info("min-ratio-model")
      # min_capacity/nominal = 1/60 ≈ 0.0167
      assert info.capacity_ratio >= 1.0 / 60.0
    end

    test "circuit_state/1 returns :closed for unknown model" do
      assert Adaptive.circuit_state("unknown-model-xyz") == :closed
    end

    test "capacity_ratio/1 returns 1.0 for unknown model" do
      assert Adaptive.capacity_ratio("unknown-model-xyz") == 1.0
    end
  end
end
