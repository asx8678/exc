defmodule CodePuppyControl.RateLimiter.AdaptiveTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.RateLimiter.Adaptive

  @table Adaptive.table()

  setup do
    if :ets.info(@table) == :undefined do
      Adaptive.create_table()
    end

    Adaptive.clear()
    :ok
  end

  describe "ensure/2" do
    test "creates a closed circuit with full capacity" do
      Adaptive.ensure("model-a")
      assert {:ok, info} = Adaptive.info("model-a")
      assert info.circuit_state == :closed
      assert info.capacity_ratio == 1.0
      assert info.total_429s == 0
    end

    test "is idempotent" do
      Adaptive.ensure("model-a")
      Adaptive.on_rate_limit("model-a", clock: fn -> 1000 end)
      Adaptive.ensure("model-a")
      assert Adaptive.circuit_state("model-a") == :open
    end
  end

  describe "on_rate_limit/2" do
    test "opens the circuit and halves capacity" do
      Adaptive.ensure("model-a")
      {:open, cooldown} = Adaptive.on_rate_limit("model-a", clock: fn -> 1000 end)

      assert cooldown == 10_000
      assert Adaptive.circuit_state("model-a") == :open
      assert Adaptive.capacity_ratio("model-a") == 0.5
    end

    test "doubles cooldown on repeated 429 while open" do
      Adaptive.ensure("model-a")
      {:open, cd1} = Adaptive.on_rate_limit("model-a", clock: fn -> 1000 end)
      {:open, cd2} = Adaptive.on_rate_limit("model-a", clock: fn -> 2000 end)

      assert cd2 == cd1 * 2
    end

    test "429 during half_open reopens with doubled cooldown" do
      Adaptive.ensure("model-a")
      Adaptive.on_rate_limit("model-a", clock: fn -> 1000 end)
      :ets.update_element(@table, "model-a", {2, :half_open})

      {:open, cooldown} =
        Adaptive.on_rate_limit("model-a",
          cooldown_ms: 10_000,
          clock: fn -> 2000 end
        )

      assert cooldown == 20_000
    end

    test "capacity ratio floors at min_capacity/nominal_capacity" do
      Adaptive.ensure("model-a")

      for _ <- 1..20 do
        Adaptive.on_rate_limit("model-a",
          min_capacity: 1,
          nominal_capacity: 60,
          clock: fn -> System.monotonic_time() end
        )
      end

      ratio = Adaptive.capacity_ratio("model-a")
      assert ratio >= 1.0 / 60
    end
  end

  describe "on_success/2" do
    test "closes a half-open circuit" do
      Adaptive.ensure("model-a")
      Adaptive.on_rate_limit("model-a", clock: fn -> 1000 end)
      :ets.update_element(@table, "model-a", {2, :half_open})

      state = Adaptive.on_success("model-a", clock: fn -> 5000 end)
      assert state == :closed
      assert Adaptive.circuit_state("model-a") == :closed
    end

    test "increments consecutive_ok in closed state" do
      Adaptive.ensure("model-a")
      for _ <- 1..9, do: Adaptive.on_success("model-a", clock: fn -> System.monotonic_time() end)
      {:ok, info} = Adaptive.info("model-a")
      assert info.consecutive_ok == 9
      assert info.capacity_ratio == 1.0
    end

    test "grows capacity after batch of 10 successes" do
      Adaptive.ensure("model-a")
      Adaptive.on_rate_limit("model-a", clock: fn -> 1000 end)

      # Transition to closed state (simulating tick loop recovery)
      :ets.update_element(@table, "model-a", {2, :closed})

      ratio_before = Adaptive.capacity_ratio("model-a")
      assert ratio_before == 0.5

      for _ <- 1..10, do: Adaptive.on_success("model-a", clock: fn -> System.monotonic_time() end)

      ratio_after = Adaptive.capacity_ratio("model-a")
      assert ratio_after > ratio_before
      assert ratio_after <= 1.0
    end

    test "on_success on open circuit stays open" do
      Adaptive.ensure("model-a")
      Adaptive.on_rate_limit("model-a", clock: fn -> 1000 end)
      assert Adaptive.circuit_state("model-a") == :open

      state = Adaptive.on_success("model-a", clock: fn -> 5000 end)
      assert state == :open
      assert Adaptive.circuit_state("model-a") == :open
    end
  end

  describe "maybe_half_open/2" do
    test "transitions open to half_open after cooldown" do
      {:ok, agent} = Agent.start_link(fn -> 1000 end)
      clock_fn = fn -> Agent.get(agent, & &1) end

      Adaptive.ensure("model-a")
      Adaptive.on_rate_limit("model-a", cooldown_ms: 5000, clock: clock_fn)

      assert Adaptive.maybe_half_open("model-a", cooldown_ms: 5000, clock: clock_fn) == :open

      Agent.update(agent, fn _ -> 7000 end)
      assert Adaptive.maybe_half_open("model-a", cooldown_ms: 5000, clock: clock_fn) == :half_open

      Agent.stop(agent)
    end
  end

  describe "capacity_ratio/1" do
    test "returns 1.0 for unknown model" do
      assert Adaptive.capacity_ratio("unknown") == 1.0
    end
  end

  describe "circuit_state/1" do
    test "returns :closed for unknown model" do
      assert Adaptive.circuit_state("unknown") == :closed
    end
  end

  describe "reset/1" do
    test "removes adaptive state" do
      Adaptive.ensure("model-a")
      Adaptive.on_rate_limit("model-a", clock: fn -> 1000 end)
      Adaptive.reset("model-a")
      assert :not_found = Adaptive.info("model-a")
    end
  end
end
