defmodule CodePuppyControl.RateLimiterTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.RateLimiter
  alias CodePuppyControl.RateLimiter.{Bucket, Adaptive}

  setup do
    # (code_puppy-i1n) Ensure RateLimiter.Supervisor and its child are alive.
    # If a prior test killed a supervised process, the supervisor subtree
    # may be dead.  Restarting the supervisor recovers the RateLimiter.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.RateLimiter.Supervisor
    )

    if Process.whereis(RateLimiter) do
      RateLimiter.ping()
    else
      # Supervisor is alive but RateLimiter child might not be;
      # restart_child recovers it from the child spec.
      try do
        Supervisor.restart_child(CodePuppyControl.RateLimiter.Supervisor, RateLimiter)
      catch
        :exit, _ -> :ok
      end
    end

    RateLimiter.clear()
    :ok
  end

  describe "acquire/2" do
    test "returns :ok for first request on unknown model" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      assert :ok = RateLimiter.acquire("test-model")
    end

    test "returns :ok with custom estimated tokens" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      assert :ok = RateLimiter.acquire("test-model", estimated_tokens: 5000)
    end

    test "returns {:wait, ms} when RPM bucket is empty" do
      RateLimiter.set_limits("test-model", rpm: 2, tpm: 100_000)
      assert :ok = RateLimiter.acquire("test-model")
      assert :ok = RateLimiter.acquire("test-model")
      assert {:wait, ms} = RateLimiter.acquire("test-model")
      assert ms > 0
    end

    test "returns {:wait, ms} when TPM bucket is empty" do
      RateLimiter.set_limits("test-model", rpm: 100, tpm: 1000)
      assert :ok = RateLimiter.acquire("test-model", estimated_tokens: 1000)
      assert {:wait, ms} = RateLimiter.acquire("test-model", estimated_tokens: 1)
      assert ms > 0
    end

    test "returns {:wait, ms} when circuit is open" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      Adaptive.ensure("test-model")
      Adaptive.on_rate_limit("test-model", clock: fn -> 1000 end)
      assert {:wait, ms} = RateLimiter.acquire("test-model")
      assert ms > 0
    end
  end

  describe "record_response/3" do
    test "on 429, opens circuit and reduces capacity" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      RateLimiter.record_response("test-model", 429, [{"retry-after", "10"}])
      RateLimiter.ping()

      assert Adaptive.circuit_state("test-model") == :open
      assert Adaptive.capacity_ratio("test-model") == 0.5
    end

    test "on 200, signals success to adaptive module" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      RateLimiter.record_response("test-model", 429, [])
      RateLimiter.ping()

      :ets.update_element(Adaptive.table(), "test-model", {2, :half_open})
      RateLimiter.record_response("test-model", 200, [])
      assert Adaptive.circuit_state("test-model") == :closed
    end

    test "on 500, no effect on rate limiting" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      RateLimiter.record_response("test-model", 500, [])
      assert Adaptive.circuit_state("test-model") == :closed
      assert Adaptive.capacity_ratio("test-model") == 1.0
    end
  end

  describe "record_rate_limit/2" do
    test "reduces bucket capacities" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      RateLimiter.record_rate_limit("test-model")
      RateLimiter.ping()

      {:ok, rpm_info} = Bucket.info({"test-model", :rpm})
      {:ok, tpm_info} = Bucket.info({"test-model", :tpm})

      assert rpm_info.capacity == 30
      assert tpm_info.capacity == 50_000
    end

    test "uses custom retry_after_ms" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      RateLimiter.record_rate_limit("test-model", 5000)
      RateLimiter.ping()

      {:ok, info} = Adaptive.info("test-model")
      assert info.circuit_state == :open
    end
  end

  describe "stats/1" do
    test "returns comprehensive stats for a model" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)

      stats = RateLimiter.stats("test-model")
      assert stats.model_name == "test-model"
      assert stats.rpm.capacity == 60
      assert stats.tpm.capacity == 100_000
      assert stats.circuit_state == :closed
      assert stats.capacity_ratio == 1.0
      assert stats.total_429s == 0
    end

    test "reflects rate limiting state" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      RateLimiter.record_rate_limit("test-model")
      RateLimiter.ping()

      stats = RateLimiter.stats("test-model")
      assert stats.circuit_state == :open
      assert stats.capacity_ratio == 0.5
      assert stats.total_429s == 1
    end
  end

  describe "circuit_open?/1" do
    test "returns false for unknown model" do
      refute RateLimiter.circuit_open?("unknown")
    end

    test "returns true when circuit is open" do
      Adaptive.ensure("test-model")
      Adaptive.on_rate_limit("test-model", clock: fn -> 1000 end)
      assert RateLimiter.circuit_open?("test-model")
    end
  end

  describe "429 during half_open doubles cooldown" do
    test "reopens circuit with doubled multiplier" do
      RateLimiter.set_limits("test-model", rpm: 60, tpm: 100_000)
      RateLimiter.record_rate_limit("test-model", 5000)
      RateLimiter.ping()

      :ets.update_element(Adaptive.table(), "test-model", {2, :half_open})
      RateLimiter.record_response("test-model", 429, [])
      RateLimiter.ping()

      assert Adaptive.circuit_state("test-model") == :open
      {:ok, info} = Adaptive.info("test-model")
      assert info.cooldown_multiplier == 2.0
    end
  end
end
