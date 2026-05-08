defmodule CodePuppyControl.Routing.StrategyTest do
  @moduledoc """
  Tests for the Strategy protocol.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Routing.Strategy
  alias CodePuppyControl.Routing.Strategies.FallbackChain
  alias CodePuppyControl.Routing.Strategies.LastResort
  alias CodePuppyControl.Routing.Strategies.RoundRobin

  describe "FallbackChain protocol implementation" do
    test "selects first model when no availability service" do
      chain = %FallbackChain{models: ["a", "b", "c"]}

      assert Strategy.select(chain, %{}) == {:ok, "a"}
    end

    test "returns error for empty models list" do
      chain = %FallbackChain{models: []}

      assert Strategy.select(chain, %{}) == {:error, :no_models_available}
    end

    test "respects excluded_models" do
      chain = %FallbackChain{models: ["a", "b", "c"]}
      context = %{excluded_models: ["a"]}

      assert Strategy.select(chain, context) == {:ok, "b"}
    end

    test "returns error when all models excluded" do
      chain = %FallbackChain{models: ["a", "b"]}
      context = %{excluded_models: ["a", "b"]}

      assert Strategy.select(chain, context) == {:error, :no_models_available}
    end
  end

  describe "LastResort protocol implementation" do
    test "selects first model" do
      strategy = %LastResort{models: ["emergency-a", "emergency-b"]}

      assert Strategy.select(strategy, %{}) == {:ok, "emergency-a"}
    end

    test "returns error for empty models" do
      strategy = %LastResort{models: []}

      assert Strategy.select(strategy, %{}) == {:error, :no_last_resort_models}
    end

    test "respects excluded_models" do
      strategy = %LastResort{models: ["a", "b", "c"]}
      context = %{excluded_models: ["a"]}

      assert Strategy.select(strategy, context) == {:ok, "b"}
    end

    test "returns error when all last resort models excluded" do
      strategy = %LastResort{models: ["a", "b"]}
      context = %{excluded_models: ["a", "b"]}

      assert Strategy.select(strategy, context) == {:error, :all_last_resort_excluded}
    end
  end

  describe "RoundRobin protocol implementation" do
    test "returns error for empty models without global" do
      strategy = %RoundRobin{models: [], use_global: false}

      assert Strategy.select(strategy, %{}) == {:error, :no_models_available}
    end

    test "returns error when models is nil without global" do
      strategy = %RoundRobin{models: nil, use_global: false}

      assert Strategy.select(strategy, %{}) == {:error, :no_models_configured}
    end

    test "selects first model when not using global" do
      strategy = %RoundRobin{models: ["a", "b", "c"], use_global: false}

      assert Strategy.select(strategy, %{}) == {:ok, "a"}
    end

    test "respects excluded_models with local mode" do
      strategy = %RoundRobin{models: ["a", "b", "c"], use_global: false}
      context = %{excluded_models: ["a"]}

      assert Strategy.select(strategy, context) == {:ok, "b"}
    end

    test "returns error when all models excluded in local mode" do
      strategy = %RoundRobin{models: ["a", "b"], use_global: false}
      context = %{excluded_models: ["a", "b"]}

      assert Strategy.select(strategy, context) == {:error, :all_models_excluded}
    end

    test "uses global mode by default" do
      # When use_global is not explicitly set (defaults to true),
      # it should delegate to RoundRobinModel
      strategy = %RoundRobin{}

      # With default use_global: true and nil models, should hit the global path
      # which returns :no_models_configured since no models are registered
      assert Strategy.select(strategy, %{}) == {:error, :no_models_configured}
    end
  end

  describe "strategy struct types" do
    test "FallbackChain has correct fields" do
      chain = %FallbackChain{models: ["a", "b"]}

      assert chain.models == ["a", "b"]
    end

    test "LastResort has correct fields" do
      strategy = %LastResort{models: ["a", "b"]}

      assert strategy.models == ["a", "b"]
    end

    test "RoundRobin has correct fields" do
      strategy = %RoundRobin{models: ["a", "b"], rotate_every: 5, use_global: false}

      assert strategy.models == ["a", "b"]
      assert strategy.rotate_every == 5
      assert strategy.use_global == false
    end
  end
end
