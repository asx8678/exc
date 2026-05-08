defmodule CodePuppyControl.Routing.LastResortTest do
  @moduledoc """
  Tests for the LastResort strategy and functions.
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Routing.Strategies.LastResort

  describe "LastResort.new/0" do
    test "creates strategy with default models" do
      strategy = LastResort.new()

      assert %LastResort{models: models} = strategy
      assert is_list(models)
      assert length(models) > 0
    end
  end

  describe "LastResort.new/1" do
    test "creates strategy with custom models" do
      strategy = LastResort.new(["model-a", "model-b"])

      assert strategy.models == ["model-a", "model-b"]
    end

    test "accepts empty list" do
      strategy = LastResort.new([])

      assert strategy.models == []
    end
  end

  describe "default_models/0" do
    test "returns configured default models" do
      models = LastResort.default_models()

      assert is_list(models)
    end
  end

  describe "integration with ModelAvailability" do
    test "by default does not check availability" do
      # Mark as terminal
      ModelAvailability.mark_terminal("emergency-model", :quota)

      # But LastResort doesn't check by default
      strategy = %LastResort{models: ["emergency-model"]}

      alias CodePuppyControl.Routing.Strategy
      assert Strategy.select(strategy, %{}) == {:ok, "emergency-model"}
    end

    test "can optionally check availability" do
      # Mark first as terminal
      ModelAvailability.mark_terminal("emergency-a", :quota)

      strategy = %LastResort{models: ["emergency-a", "emergency-b"]}

      # With availability checking enabled
      context = %{
        check_last_resort_availability: true,
        availability_service: :global
      }

      alias CodePuppyControl.Routing.Strategy
      assert Strategy.select(strategy, context) == {:ok, "emergency-b"}
    end
  end
end
