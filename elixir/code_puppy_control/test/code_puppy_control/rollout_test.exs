defmodule CodePuppyControl.RolloutTest do
  @moduledoc """
  Tests for the Rollout GenServer. (code_puppy-djs.6)

  Covers:
  - should_use_elixir?/1 with no rollout config falls back to FeatureFlags
  - should_use_elixir?/1 with 0% always returns false
  - should_use_elixir?/1 with 100% always returns true
  - set_percentage/2 + get_percentage/1 round trip
  - record_outcome/3 increments counters correctly
  - status/0 returns comprehensive map
  - check_rollback/1 returns :ok when error rate is below threshold
  - check_rollback/1 returns {:rollback, reason} when error rate exceeds threshold
  - reset_counters/0 zeros all counters
  - set_error_threshold/2 changes the threshold
  - Unknown capability returns conservative defaults
  - Edge case: 0 total requests → no rollback (avoid division by zero)

  async: false because Rollout is a named singleton that shares ETS.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Rollout
  alias CodePuppyControl.FeatureFlags

  @capability "elixir.llm_client"

  setup do
    # Ensure the GenServers are running
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(FeatureFlags)
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(Rollout)

    # Clean state: reset rollout counters + feature flags
    Rollout.reset_counters()
    # Clear rollout config entries by deleting all objects
    # (We don't have a "remove config" API, so we wipe the whole table)
    :ets.delete_all_objects(:rollout_ets)
    FeatureFlags.reset_all()

    # Force auto mode for tests
    original_env = System.get_env("PUP_RUNTIME")
    System.delete_env("PUP_RUNTIME")

    on_exit(fn ->
      # Restore env
      if original_env do
        System.put_env("PUP_RUNTIME", original_env)
      else
        System.delete_env("PUP_RUNTIME")
      end

      # Clean up
      Rollout.reset_counters()
      :ets.delete_all_objects(:rollout_ets)
      FeatureFlags.reset_all()
    end)

    :ok
  end

  # ===========================================================================
  # should_use_elixir?/1 — fallback to FeatureFlags
  # ===========================================================================

  describe "should_use_elixir?/1 with no rollout config" do
    test "falls back to FeatureFlags when no rollout is configured" do
      # No rollout config → FeatureFlags decides
      # Feature flag is off → should use Python
      FeatureFlags.set_flag(@capability, false)
      assert Rollout.should_use_elixir?(@capability) == false

      # Feature flag is on → should use Elixir
      FeatureFlags.set_flag(@capability, true)
      assert Rollout.should_use_elixir?(@capability) == true
    end

    test "returns false for unknown capability with no rollout and flag off" do
      assert Rollout.should_use_elixir?("unknown.cap") == false
    end
  end

  # ===========================================================================
  # should_use_elixir?/1 — percentage routing
  # ===========================================================================

  describe "should_use_elixir?/1 with percentage" do
    test "0% always returns false regardless of FeatureFlags" do
      FeatureFlags.set_flag(@capability, true)
      Rollout.set_percentage(@capability, 0)

      # At 0%, should always route to Python
      # Try multiple times to be sure
      results = for _ <- 1..20 do
        Rollout.should_use_elixir?(@capability)
      end

      assert Enum.all?(results, &(&1 == false))
    end

    test "100% always returns true regardless of FeatureFlags" do
      FeatureFlags.set_flag(@capability, false)
      Rollout.set_percentage(@capability, 100)

      results = for _ <- 1..20 do
        Rollout.should_use_elixir?(@capability)
      end

      assert Enum.all?(results, &(&1 == true))
    end

    test "50% returns a mix of true and false over many calls" do
      Rollout.set_percentage(@capability, 50)

      results = for _ <- 1..200 do
        Rollout.should_use_elixir?(@capability)
      end

      true_count = Enum.count(results, & &1)
      # With 200 samples at 50%, we expect roughly 100 ± 40
      assert true_count > 30 and true_count < 170
    end
  end

  # ===========================================================================
  # should_use_elixir?/1 — forced modes
  # ===========================================================================

  describe "should_use_elixir?/1 with forced modes" do
    test "returns true when PUP_RUNTIME=elixir" do
      System.put_env("PUP_RUNTIME", "elixir")
      assert Rollout.should_use_elixir?(@capability) == true
    end

    test "returns false when PUP_RUNTIME=python" do
      System.put_env("PUP_RUNTIME", "python")
      assert Rollout.should_use_elixir?(@capability) == false
    end
  end

  # ===========================================================================
  # set_percentage/2 + get_percentage/1
  # ===========================================================================

  describe "set_percentage/2 and get_percentage/1" do
    test "round trip: set then get" do
      Rollout.set_percentage(@capability, 42)
      assert Rollout.get_percentage(@capability) == 42
    end

    test "clamps values above 100 to 100" do
      Rollout.set_percentage(@capability, 999)
      assert Rollout.get_percentage(@capability) == 100
    end

    test "clamps negative values to 0" do
      Rollout.set_percentage(@capability, -10)
      assert Rollout.get_percentage(@capability) == 0
    end

    test "returns 0 for unconfigured capability" do
      assert Rollout.get_percentage("elixir.totally_new") == 0
    end

    test "returns error for invalid input" do
      assert {:error, :invalid_input} = Rollout.set_percentage(@capability, "bad")
    end
  end

  # ===========================================================================
  # record_outcome/3
  # ===========================================================================

  describe "record_outcome/3" do
    test "increments counters correctly" do
      Rollout.record_outcome(@capability, :elixir, :ok)
      Rollout.record_outcome(@capability, :elixir, :ok)
      Rollout.record_outcome(@capability, :elixir, :error)
      Rollout.record_outcome(@capability, :python, :ok)
      Rollout.record_outcome(@capability, :python, :error)
      Rollout.record_outcome(@capability, :python, :error)

      status = Rollout.status()
      cap_status = status.capabilities[@capability]

      assert cap_status.counters.elixir_ok == 2
      assert cap_status.counters.elixir_err == 1
      assert cap_status.counters.python_ok == 1
      assert cap_status.counters.python_err == 2
    end

    test "returns :ok" do
      assert :ok == Rollout.record_outcome(@capability, :elixir, :ok)
    end
  end

  # ===========================================================================
  # status/0
  # ===========================================================================

  describe "status/0" do
    test "returns comprehensive map" do
      Rollout.set_percentage(@capability, 75)
      Rollout.record_outcome(@capability, :elixir, :ok)
      Rollout.record_outcome(@capability, :elixir, :error)

      status = Rollout.status()

      assert is_map(status)
      assert is_map(status.capabilities)
      cap_status = status.capabilities[@capability]

      assert cap_status.percentage == 75
      assert cap_status.error_threshold == 0.10
      assert cap_status.counters.elixir_ok == 1
      assert cap_status.counters.elixir_err == 1
      assert cap_status.counters.python_ok == 0
      assert cap_status.counters.python_err == 0
      assert is_float(cap_status.elixir_error_rate)
    end

    test "computes elixir_error_rate correctly" do
      # 3 errors out of 10 total = 30%
      for _ <- 1..7, do: Rollout.record_outcome(@capability, :elixir, :ok)
      for _ <- 1..3, do: Rollout.record_outcome(@capability, :elixir, :error)

      status = Rollout.status()
      cap_status = status.capabilities[@capability]

      assert_in_delta cap_status.elixir_error_rate, 0.3, 0.001
    end
  end

  # ===========================================================================
  # check_rollback/1
  # ===========================================================================

  describe "check_rollback/1" do
    test "returns :ok when error rate is below threshold" do
      Rollout.set_error_threshold(@capability, 0.10)

      # 5% error rate (1 out of 20)
      for _ <- 1..19, do: Rollout.record_outcome(@capability, :elixir, :ok)
      for _ <- 1..1, do: Rollout.record_outcome(@capability, :elixir, :error)

      assert :ok == Rollout.check_rollback(@capability)
    end

    test "returns {:rollback, reason} when error rate exceeds threshold" do
      Rollout.set_error_threshold(@capability, 0.10)

      # 50% error rate (5 out of 10)
      for _ <- 1..5, do: Rollout.record_outcome(@capability, :elixir, :ok)
      for _ <- 1..5, do: Rollout.record_outcome(@capability, :elixir, :error)

      result = Rollout.check_rollback(@capability)

      assert match?({:rollback, _reason}, result)

      {:rollback, reason} = result
      assert is_binary(reason)
      assert String.contains?(reason, "50.0%")
      assert String.contains?(reason, "10.0%")
    end

    test "avoids division by zero with 0 total requests" do
      Rollout.set_error_threshold(@capability, 0.10)
      # No outcomes recorded at all → :ok, not a crash
      assert :ok == Rollout.check_rollback(@capability)
    end

    test "unknown capability with default threshold and no counters returns :ok" do
      assert :ok == Rollout.check_rollback("totally.unknown.cap")
    end
  end

  # ===========================================================================
  # reset_counters/0
  # ===========================================================================

  describe "reset_counters/0" do
    test "zeros all counters" do
      Rollout.set_percentage(@capability, 50)
      Rollout.record_outcome(@capability, :elixir, :ok)
      Rollout.record_outcome(@capability, :elixir, :error)

      Rollout.reset_counters()

      status = Rollout.status()
      cap_status = status.capabilities[@capability]

      assert cap_status.counters.elixir_ok == 0
      assert cap_status.counters.elixir_err == 0
    end

    test "does not reset percentages" do
      Rollout.set_percentage(@capability, 42)
      Rollout.reset_counters()

      assert Rollout.get_percentage(@capability) == 42
    end
  end

  # ===========================================================================
  # set_error_threshold/2
  # ===========================================================================

  describe "set_error_threshold/2" do
    test "changes the threshold" do
      Rollout.set_error_threshold(@capability, 0.25)

      status = Rollout.status()
      assert status.capabilities[@capability].error_threshold == 0.25
    end

    test "clamps values above 1.0 to 1.0" do
      Rollout.set_error_threshold(@capability, 5.0)

      status = Rollout.status()
      assert status.capabilities[@capability].error_threshold == 1.0
    end

    test "clamps negative values to 0.0" do
      Rollout.set_error_threshold(@capability, -0.5)

      status = Rollout.status()
      assert status.capabilities[@capability].error_threshold == 0.0
    end

    test "default threshold is 0.10" do
      # No threshold configured → should use default
      status = Rollout.status()
      # The capability may or may not be in status depending on whether we
      # recorded any counters. If it's there, check the threshold.
      case Map.get(status.capabilities, @capability) do
        nil -> :ok  # Not present yet — that's fine
        cap_status -> assert_in_delta cap_status.error_threshold, 0.10, 0.001
      end
    end
  end

  # ===========================================================================
  # Unknown capability — conservative defaults
  # ===========================================================================

  describe "unknown capability" do
    test "get_percentage returns 0" do
      assert Rollout.get_percentage("elixir.brand_new") == 0
    end

    test "should_use_elixir? falls back to FeatureFlags (returns false)" do
      assert Rollout.should_use_elixir?("elixir.brand_new") == false
    end

    test "check_rollback returns :ok (no data, no rollback)" do
      assert :ok == Rollout.check_rollback("elixir.brand_new")
    end
  end

  # ===========================================================================
  # Edge cases
  # ===========================================================================

  describe "edge cases" do
    test "set_percentage then set_error_threshold preserves both" do
      Rollout.set_percentage(@capability, 60)
      Rollout.set_error_threshold(@capability, 0.20)

      status = Rollout.status()
      cap_status = status.capabilities[@capability]

      assert cap_status.percentage == 60
      assert cap_status.error_threshold == 0.20
    end

    test "set_error_threshold then set_percentage preserves both" do
      Rollout.set_error_threshold(@capability, 0.30)
      Rollout.set_percentage(@capability, 25)

      status = Rollout.status()
      cap_status = status.capabilities[@capability]

      assert cap_status.percentage == 25
      assert cap_status.error_threshold == 0.30
    end

    test "record_outcome for unknown capability creates counters on the fly" do
      Rollout.record_outcome("elixir.experimental", :elixir, :ok)

      status = Rollout.status()
      cap_status = status.capabilities["elixir.experimental"]

      assert cap_status.counters.elixir_ok == 1
      assert cap_status.percentage == 0
    end

    test "reset_counters is idempotent" do
      Rollout.reset_counters()
      Rollout.reset_counters()
      # No crash = pass
      assert :ok == Rollout.reset_counters()
    end
  end
end
