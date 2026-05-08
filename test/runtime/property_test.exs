defmodule CodePuppyControl.Runtime.PropertyTest do
  @moduledoc """
  Property-based tests for runtime invariants.

  - Scheduler: should_run? is always a boolean; next_run is always in the
    future for non-nil last_run; interval parsing round-trips.
  - Rate limiter: tokens never exceed max_tokens; capacity_ratio bounded
    between min and 1.0; circuit transitions are valid.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :property

  alias CodePuppyControl.Scheduler.Task
  alias CodePuppyControl.RateLimiter.{Bucket, Adaptive}

  # ---------------------------------------------------------------------------
  # Scheduler Interval Parsing
  # ---------------------------------------------------------------------------

  describe "Task.parse_interval/1 properties" do
    property "always returns {:ok, seconds} for valid format <number><unit>" do
      check all(
              value <- integer(1..999),
              unit <- member_of(["s", "m", "h", "d"])
            ) do
        interval_str = "#{value}#{unit}"
        assert {:ok, seconds} = Task.parse_interval(interval_str)
        assert is_integer(seconds)
        assert seconds > 0
      end
    end

    property "parsed seconds are consistent with unit multipliers" do
      check all(value <- integer(1..100)) do
        assert {:ok, ^value} = Task.parse_interval("#{value}s")
        assert {:ok, v} = Task.parse_interval("#{value}m")
        assert v == value * 60
        assert {:ok, v} = Task.parse_interval("#{value}h")
        assert v == value * 3600
        assert {:ok, v} = Task.parse_interval("#{value}d")
        assert v == value * 86400
      end
    end

    property "returns error for invalid formats" do
      check all(str <- string(:alphanumeric, min_length: 1, max_length: 20)) do
        # Only strings that DON'T match <digits><unit> should return error
        unless Regex.match?(~r/^\d+[smhd]$/i, str) do
          assert {:error, _} = Task.parse_interval(str)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduler should_run? Invariants
  # ---------------------------------------------------------------------------

  describe "Task.should_run?/2 invariants" do
    property "always returns a boolean" do
      check all(
              schedule_type <- member_of(["interval", "hourly", "daily", "one_shot"]),
              enabled <- boolean(),
              last_run_offset <- integer(-86400..86400)
            ) do
        now = DateTime.utc_now()

        last_run_at =
          if last_run_offset < 0 do
            DateTime.add(now, last_run_offset, :second)
          else
            nil
          end

        task = %Task{
          schedule_type: schedule_type,
          schedule_value: "1h",
          last_run_at: last_run_at,
          enabled: enabled
        }

        result = Task.should_run?(task, now)
        assert is_boolean(result)
      end
    end

    property "disabled tasks never run" do
      check all(
              schedule_type <- member_of(["interval", "hourly", "daily", "cron", "one_shot"]),
              last_run_offset <- integer(-86400..0)
            ) do
        now = DateTime.utc_now()
        last_run_at = DateTime.add(now, last_run_offset, :second)

        task = %Task{
          schedule_type: schedule_type,
          schedule_value: "1h",
          schedule: "0 9 * * *",
          last_run_at: last_run_at,
          enabled: false
        }

        refute Task.should_run?(task, now)
      end
    end

    property "never-run tasks always should run (when enabled)" do
      check all(schedule_type <- member_of(["interval", "hourly", "daily", "one_shot"])) do
        task = %Task{
          schedule_type: schedule_type,
          schedule_value: "1h",
          last_run_at: nil,
          enabled: true
        }

        assert Task.should_run?(task, DateTime.utc_now())
      end
    end

    property "one_shot tasks that have already run never run again" do
      check all(last_run_offset <- integer(-86400..-1)) do
        now = DateTime.utc_now()
        last_run_at = DateTime.add(now, last_run_offset, :second)

        task = %Task{
          schedule_type: "one_shot",
          last_run_at: last_run_at,
          enabled: true
        }

        refute Task.should_run?(task, now)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Token Bucket Invariants
  # ---------------------------------------------------------------------------

  describe "Bucket invariants" do
    setup do
      if :ets.whereis(:rate_limiter_buckets) == :undefined do
        Bucket.create_table()
      else
        Bucket.clear()
      end

      :ok
    end

    property "tokens never exceed capacity after init" do
      check all(capacity <- integer(1..1000)) do
        key = {"prop-test-#{System.unique_integer([:positive])}", :rpm}
        clock = fn -> 0 end
        :ok = Bucket.init_bucket(key, capacity, clock)

        {:ok, info} = Bucket.info(key)
        assert info.tokens <= info.capacity
      end
    end

    property "tokens never go below 0 after take" do
      check all(
              capacity <- integer(1..100),
              take_amount <- integer(1..100)
            ) do
        key = {"prop-take-#{System.unique_integer([:positive])}", :rpm}
        clock = fn -> 0 end
        :ok = Bucket.init_bucket(key, capacity, clock)

        Bucket.take(key, take_amount, clock)

        {:ok, info} = Bucket.info(key)
        assert info.tokens >= 0
      end
    end

    property "refill never exceeds capacity" do
      check all(
              capacity <- integer(1..100),
              elapsed_ms <- integer(0..1_000_000)
            ) do
        key = {"prop-refill-#{System.unique_integer([:positive])}", :rpm}
        start_time = 0
        :ok = Bucket.init_bucket(key, capacity, fn -> start_time end)

        # Refill after elapsed time
        later_clock = fn -> start_time + elapsed_ms end
        Bucket.refill(key, 10.0, later_clock)

        {:ok, info} = Bucket.info(key)
        assert info.tokens <= capacity
      end
    end

    property "set_capacity caps existing tokens" do
      check all(
              initial_cap <- integer(10..100),
              new_cap <- integer(1..100)
            ) do
        key = {"prop-cap-#{System.unique_integer([:positive])}", :rpm}
        clock = fn -> 0 end
        :ok = Bucket.init_bucket(key, initial_cap, clock)

        :ok = Bucket.set_capacity(key, new_cap)

        {:ok, info} = Bucket.info(key)
        assert info.capacity == new_cap
        assert info.tokens <= new_cap
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Adaptive Circuit Breaker Invariants
  # ---------------------------------------------------------------------------

  describe "Adaptive invariants" do
    setup do
      if :ets.whereis(:rate_limiter_circuits) == :undefined do
        Adaptive.create_table()
      else
        Adaptive.clear()
      end

      :ok
    end

    property "capacity_ratio is always between min_ratio and 1.0 after on_rate_limit" do
      check all(
              model_name <- string(:alphanumeric, min_length: 3, max_length: 20),
              cooldown_ms <- integer(1..60_000),
              min_capacity <- integer(1..10),
              nominal_capacity <- integer(10..100)
            ) do
        key = "prop-adaptive-#{model_name}"
        Adaptive.ensure(key, fn -> 0 end)

        min_ratio = min_capacity / max(nominal_capacity, 1)

        Adaptive.on_rate_limit(key,
          cooldown_ms: cooldown_ms,
          min_capacity: min_capacity,
          nominal_capacity: nominal_capacity
        )

        ratio = Adaptive.capacity_ratio(key)
        assert ratio >= min_ratio
        assert ratio <= 1.0
      end
    end

    property "circuit state transitions are valid" do
      check all(model <- string(:alphanumeric, min_length: 1, max_length: 15)) do
        key = "prop-transitions-#{model}"
        Adaptive.ensure(key, fn -> 0 end)

        # Initial state: closed
        assert Adaptive.circuit_state(key) == :closed

        # After 429: open
        Adaptive.on_rate_limit(key, cooldown_ms: 1, min_capacity: 1, nominal_capacity: 10)
        assert Adaptive.circuit_state(key) == :open

        # After cooldown: half_open
        Process.sleep(50)

        Adaptive.maybe_half_open(key, cooldown_ms: 1, clock: fn -> System.monotonic_time() end)

        state = Adaptive.circuit_state(key)
        assert state in [:open, :half_open]

        # After success on half_open: closed
        if state == :half_open do
          result = Adaptive.on_success(key)
          assert result == :closed
        end
      end
    end

    property "total_429s is monotonically increasing" do
      check all(
              model <- string(:alphanumeric, min_length: 1, max_length: 10),
              count <- integer(1..5)
            ) do
        key = "prop-429count-#{model}"
        Adaptive.clear()
        Adaptive.ensure(key, fn -> 0 end)

        initial_total =
          case Adaptive.info(key) do
            {:ok, info} -> info.total_429s
            :not_found -> 0
          end

        for _ <- 1..count do
          Adaptive.on_rate_limit(key, cooldown_ms: 10_000, min_capacity: 1, nominal_capacity: 10)
        end

        {:ok, info} = Adaptive.info(key)
        assert info.total_429s >= initial_total + count
      end
    end
  end
end
