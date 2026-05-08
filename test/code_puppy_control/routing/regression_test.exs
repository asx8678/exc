defmodule CodePuppyControl.Routing.RegressionTest do
  @moduledoc """
  Regression tests for critical routing bugs (fixes).

  These tests verify:
  1. availability_service is actually called from context (not hardcoded)
  2. LastResort bare struct doesn't crash on nil models
  3. RoundRobin with global mode actually rotates between models
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Routing.Strategy
  alias CodePuppyControl.Routing.Strategies.FallbackChain
  alias CodePuppyControl.Routing.Strategies.LastResort
  alias CodePuppyControl.Routing.Strategies.RoundRobin

  # ============================================================================
  # Regression Test 1: Injected availability_service is actually called
  # ============================================================================

  describe "availability_service injection (fix)" do
    defmodule MockAvailability do
      @moduledoc "Mock availability service for testing injection"

      def select_first_available(models) do
        # Always return the second model to prove this mock was called
        case models do
          [_first, second | _rest] -> %{selected_model: second, skipped: 1}
          [only] -> %{selected_model: only, skipped: 0}
          [] -> %{selected_model: nil, skipped: 0}
        end
      end
    end

    test "FallbackChain calls injected availability_service from context" do
      chain = %FallbackChain{models: ["first", "second", "third"]}
      context = %{availability_service: MockAvailability}

      # Mock always returns second model
      assert Strategy.select(chain, context) == {:ok, "second"}
    end

    test "FallbackChain uses default ModelAvailability when no service in context" do
      chain = %FallbackChain{models: ["a", "b", "c"]}

      # Without injected service, should use default (which selects first available)
      assert Strategy.select(chain, %{}) == {:ok, "a"}
    end

    test "injected service receives excluded models filtered list" do
      defmodule RecordingAvailability do
        @moduledoc "Records the models it receives"

        def select_first_available(models) do
          # Send models to test process for verification
          send(self(), {:received_models, models})
          %{selected_model: List.first(models), skipped: 0}
        end
      end

      chain = %FallbackChain{models: ["a", "b", "c", "d"]}
      context = %{availability_service: RecordingAvailability, excluded_models: ["a", "c"]}

      Strategy.select(chain, context)

      # Should receive filtered list, not original
      assert_received {:received_models, ["b", "d"]}
    end
  end

  # ============================================================================
  # Regression Test 2: LastResort bare struct doesn't crash
  # ============================================================================

  describe "LastResort nil/empty handling (fix)" do
    test "bare %LastResort{} struct with nil models returns error" do
      # The struct now defaults to empty list, but nil should still be handled
      strategy = %LastResort{models: nil}

      # Should return error, not crash
      assert Strategy.select(strategy, %{}) == {:error, :no_last_resort_models}
    end

    test "bare %LastResort{} struct with default empty list returns error" do
      # Since we changed defstruct to have default empty list
      strategy = %LastResort{}

      # Should return error, not crash
      assert Strategy.select(strategy, %{}) == {:error, :no_last_resort_models}
    end

    test "%LastResort.new() creates struct with default models" do
      strategy = LastResort.new()

      # Should have default models configured
      assert strategy.models == ["gpt-4o-mini", "gemini-2.5-flash"]

      # And should successfully select first
      assert Strategy.select(strategy, %{}) == {:ok, "gpt-4o-mini"}
    end

    test "%LastResort.new([]) with empty explicit list returns error" do
      strategy = LastResort.new([])

      assert strategy.models == []
      assert Strategy.select(strategy, %{}) == {:error, :no_last_resort_models}
    end
  end

  # ============================================================================
  # Regression Test 3: RoundRobin actually rotates with use_global: true
  # ============================================================================

  describe "RoundRobin rotation (fix)" do
    # Use async: false for these tests since they share the global RoundRobinModel
    alias CodePuppyControl.RoundRobinModel

    setup do
      # Configure the global RoundRobinModel for these tests
      RoundRobinModel.configure(models: ["model-a", "model-b", "model-c"])
      :ok
    end

    test "global mode rotates through models on consecutive calls" do
      models = ["model-a", "model-b", "model-c"]

      # Create strategy with global mode (now the default)
      strategy = %RoundRobin{use_global: true}

      # Multiple calls should return different models (rotation)
      results =
        for _ <- 1..6 do
          case Strategy.select(strategy, %{}) do
            {:ok, model} -> model
            error -> error
          end
        end

      # Should cycle through all models and repeat
      assert Enum.take(results, 3) == models
      assert Enum.drop(results, 3) == models
    end

    test "global mode ignores excluded_models (documented behavior)" do
      # NOTE: When use_global: true, the strategy delegates to RoundRobinModel
      # which handles rotation independently. The excluded_models context is
      # only used in local mode (use_global: false).
      strategy = %RoundRobin{use_global: true}
      context = %{excluded_models: ["model-a"]}

      results =
        for _ <- 1..3 do
          case Strategy.select(strategy, context) do
            {:ok, model} -> model
            error -> error
          end
        end

      # Global mode ignores excluded_models - returns all models in rotation
      assert results == ["model-a", "model-b", "model-c"]
    end

    test "local mode respects excluded_models by filtering before selection" do
      # Local mode filters excluded_models and returns first available
      strategy = %RoundRobin{models: ["model-a", "model-b", "model-c"], use_global: false}
      context = %{excluded_models: ["model-a"]}

      # Should skip model-a and return model-b
      assert Strategy.select(strategy, context) == {:ok, "model-b"}
    end

    test "local mode (use_global: false) consistently returns first model - documented behavior" do
      # This tests the documented behavior: local mode doesn't maintain state
      strategy = %RoundRobin{models: ["x", "y", "z"], use_global: false}

      # All calls return the same first model (no rotation without state)
      results =
        for _ <- 1..3 do
          {:ok, model} = Strategy.select(strategy, %{})
          model
        end

      assert results == ["x", "x", "x"]
    end

    test "local mode with excluded_models selects first non-excluded" do
      strategy = %RoundRobin{models: ["a", "b", "c"], use_global: false}
      context = %{excluded_models: ["a"]}

      assert Strategy.select(strategy, context) == {:ok, "b"}
    end
  end

  # ============================================================================
  # Integration: All fixes work together
  # ============================================================================

  describe "integration: all fixes work together" do
    defmodule IntegrationMockAvailability do
      @moduledoc "Mock that marks some models as unavailable"

      def select_first_available(models) do
        # Simulate that first model is unavailable
        case models do
          [] -> %{selected_model: nil, skipped: 0}
          [_first | rest] -> %{selected_model: List.first(rest) || List.first(models), skipped: 1}
        end
      end
    end

    test "full routing chain with injected availability and fallbacks" do
      # Test a realistic scenario: primary strategy with availability check,
      # falls back to last resort

      # First strategy with mock availability (skips first model)
      primary = %FallbackChain{models: ["primary-a", "primary-b"]}
      context = %{availability_service: IntegrationMockAvailability}

      # Should get primary-b because mock skips primary-a
      assert Strategy.select(primary, context) == {:ok, "primary-b"}

      # Last resort with bare struct should not crash
      last_resort = %LastResort{}
      assert Strategy.select(last_resort, %{}) == {:error, :no_last_resort_models}

      # Last resort with explicit models should work
      last_resort_with = %LastResort{models: ["emergency"]}
      assert Strategy.select(last_resort_with, %{}) == {:ok, "emergency"}
    end
  end
end
