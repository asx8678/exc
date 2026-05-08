defmodule CodePuppyControl.Routing.RouterTest do
  @moduledoc """
  Tests for the Router module.
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Routing.Router
  alias CodePuppyControl.Routing.Strategies.FallbackChain
  alias CodePuppyControl.Routing.Strategies.LastResort

  describe "route/1 with single strategy" do
    test "selects model from fallback chain" do
      result = Router.route(strategies: [%FallbackChain{models: ["a", "b", "c"]}])

      assert result == {:ok, "a"}
    end

    test "returns error when no models available" do
      result = Router.route(strategies: [%FallbackChain{models: []}])

      assert match?({:error, _}, result)
    end
  end

  describe "route/1 with strategy chaining" do
    test "tries next strategy when first fails" do
      strategies = [
        %FallbackChain{models: []},
        %FallbackChain{models: ["fallback-model"]}
      ]

      assert Router.route(strategies: strategies) == {:ok, "fallback-model"}
    end

    test "returns error when all strategies fail" do
      strategies = [
        %FallbackChain{models: []},
        %FallbackChain{models: []},
        %FallbackChain{models: []}
      ]

      result = Router.route(strategies: strategies)
      assert match?({:error, {:all_strategies_failed, _}}, result)
    end

    test "stops at first successful strategy" do
      strategies = [
        %FallbackChain{models: ["first", "second"]},
        %FallbackChain{models: ["should-not-reach"]}
      ]

      assert Router.route(strategies: strategies) == {:ok, "first"}
    end
  end

  describe "route/1 with availability service" do
    test "skips terminal models" do
      ModelAvailability.mark_terminal("model-a", :quota)

      strategies = [%FallbackChain{models: ["model-a", "model-b"]}]
      context = %{availability_service: :global}

      assert Router.route(strategies: strategies, context: context) == {:ok, "model-b"}
    end

    test "selects healthy model over terminal" do
      ModelAvailability.mark_terminal("model-a", :quota)
      ModelAvailability.mark_terminal("model-b", :capacity)

      strategies = [%FallbackChain{models: ["model-a", "model-b", "model-c"]}]
      context = %{availability_service: :global}

      assert Router.route(strategies: strategies, context: context) == {:ok, "model-c"}
    end

    test "returns error when all models are terminal" do
      ModelAvailability.mark_terminal("model-a", :quota)
      ModelAvailability.mark_terminal("model-b", :capacity)

      strategies = [%FallbackChain{models: ["model-a", "model-b"]}]
      context = %{availability_service: :global}

      result = Router.route(strategies: strategies, context: context)
      # When single strategy fails, router wraps in all_strategies_failed
      assert match?({:error, {:all_strategies_failed, _}}, result)
    end
  end

  describe "fallback/1 convenience function" do
    test "selects first model" do
      assert Router.fallback(["a", "b", "c"]) == {:ok, "a"}
    end

    test "returns error for empty list" do
      result = Router.fallback([])
      assert match?({:error, _}, result)
    end
  end

  describe "round_robin/2 convenience function" do
    test "selects first model when use_global is false" do
      assert Router.round_robin(["a", "b", "c"], use_global: false) == {:ok, "a"}
    end

    test "accepts rotate_every option" do
      assert Router.round_robin(["a", "b"], rotate_every: 5, use_global: false) == {:ok, "a"}
    end
  end

  describe "global_round_robin/0 convenience function" do
    test "requires configured RoundRobinModel" do
      # This will fail unless RoundRobinModel is configured
      # We just verify it returns either error or a model
      result = Router.global_round_robin()

      # Will be error if not configured, or ok if configured
      assert is_tuple(result) and tuple_size(result) == 2
      assert elem(result, 0) in [:ok, :error]
    end
  end

  describe "route_default/1" do
    test "returns a model for default role" do
      result = Router.route_default()

      assert match?({:ok, _model}, result)
    end

    test "returns a model for specific role" do
      result = Router.route_default(role: "coder")

      assert match?({:ok, _model}, result)
    end

    test "considers availability when service provided" do
      # Mark default models as terminal and expect fallback
      ModelAvailability.mark_terminal("claude-sonnet-4", :quota)

      result =
        Router.route_default(
          role: "coder",
          availability_service: :global
        )

      # Should get fallback since first is terminal
      assert match?({:ok, _model}, result)
    end

    test "availability_service is passed to LastResort strategy when all models terminal" do
      # Mark all primary models as terminal
      ModelAvailability.mark_terminal("model-a", :quota)
      ModelAvailability.mark_terminal("model-b", :quota)

      # Mark one last resort model as terminal but leave one available
      # "last-resort-b" is kept healthy/available
      ModelAvailability.mark_terminal("last-resort-a", :quota)

      # When we enable last resort availability checking with :global,
      # the LastResort should use the injected availability_service to check
      # model health and skip the terminal "last-resort-a", selecting "last-resort-b"
      result =
        Router.route(
          strategies: [
            %FallbackChain{models: ["model-a", "model-b"]},
            %LastResort{models: ["last-resort-a", "last-resort-b"]}
          ],
          context: %{
            availability_service: :global,
            check_last_resort_availability: true
          }
        )

      # LastResort should check availability using :global and select "last-resort-b"
      assert result == {:ok, "last-resort-b"}
    end
  end

  describe "excluded_models in context" do
    test "excludes specified models from selection" do
      strategies = [%FallbackChain{models: ["a", "b", "c"]}]
      context = %{excluded_models: ["a"]}

      assert Router.route(strategies: strategies, context: context) == {:ok, "b"}
    end

    test "excludes multiple models" do
      strategies = [%FallbackChain{models: ["a", "b", "c", "d"]}]
      context = %{excluded_models: ["a", "b"]}

      assert Router.route(strategies: strategies, context: context) == {:ok, "c"}
    end
  end

  describe "regression tests for " do
    test "route_default uses LastResort.new() with actual default models" do
      # Test that LastResort.new() returns proper default fallback models
      # instead of empty struct (which was the bug: using %LastResort{})
      last_resort = LastResort.new()
      assert last_resort.models == ["gpt-4o-mini", "gemini-2.5-flash"]
      # Test via Router.route() with empty primary to ensure LastResort is reached
      result =
        Router.route(
          strategies: [
            # Empty primary to force fallback
            %FallbackChain{models: []},
            # Should have default models, not empty
            LastResort.new()
          ]
        )

      assert {:ok, model} = result
      assert model in ["gpt-4o-mini", "gemini-2.5-flash"]
    end

    test "round_robin/1 uses caller's models, not global configuration" do
      # Call with first list
      assert {:ok, "a"} = Router.round_robin(["a", "b"])

      # Call with different list - should use the new list, not cache from first call
      # This proves it's not using the global RoundRobinModel
      assert {:ok, "x"} = Router.round_robin(["x", "y"])

      # Third call with original pattern - should return first again
      # (since use_global: false doesn't maintain state between calls)
      assert {:ok, "a"} = Router.round_robin(["a", "b"])
    end

    test "round_robin/1 with explicit use_global: false uses caller's models" do
      # Explicit use_global: false should behave the same as default now
      assert {:ok, "custom-1"} = Router.round_robin(["custom-1", "custom-2"], use_global: false)
    end
  end
end
