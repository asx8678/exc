defmodule CodePuppyControl.Routing.IntegrationTest do
  @moduledoc """
  Integration tests for the routing system.

  These tests exercise the full routing stack including:
  - Router coordination
  - Strategy selection
  - ModelAvailability circuit breaker
  - Strategy chaining and fallbacks
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Routing
  alias CodePuppyControl.Routing.Router
  alias CodePuppyControl.Routing.Strategies.FallbackChain
  alias CodePuppyControl.Routing.Strategies.LastResort

  describe "complete routing workflow" do
    test "primary strategy succeeds, no fallback needed" do
      result =
        Router.route(
          strategies: [
            %FallbackChain{models: ["claude-sonnet-4", "gpt-4o"]}
          ],
          context: %{availability_service: :global}
        )

      assert {:ok, "claude-sonnet-4"} = result
    end

    test "falls back when primary models unavailable" do
      # Mark primary models as terminal
      ModelAvailability.mark_terminal("claude-sonnet-4", :quota)
      ModelAvailability.mark_terminal("gpt-4o", :capacity)

      result =
        Router.route(
          strategies: [
            %FallbackChain{models: ["claude-sonnet-4", "gpt-4o"]},
            %FallbackChain{models: ["gemini-2.5-flash", "gpt-4o-mini"]}
          ],
          context: %{availability_service: :global}
        )

      assert {:ok, "gemini-2.5-flash"} = result
    end

    test "uses last resort when all else fails" do
      # Mark all primary and secondary as terminal
      ModelAvailability.mark_terminal("primary", :quota)
      ModelAvailability.mark_terminal("secondary", :quota)

      result =
        Router.route(
          strategies: [
            %FallbackChain{models: ["primary"]},
            %FallbackChain{models: ["secondary"]},
            %LastResort{models: ["emergency-model"]}
          ],
          context: %{availability_service: :global}
        )

      assert {:ok, "emergency-model"} = result
    end

    test "handles sticky retry correctly" do
      # Mark as sticky retry (one attempt allowed)
      ModelAvailability.mark_sticky_retry("claude-3")

      # First selection should succeed
      result1 =
        Router.route(
          strategies: [%FallbackChain{models: ["claude-3", "gpt-4"]}],
          context: %{availability_service: :global}
        )

      assert {:ok, "claude-3"} = result1

      # Mark as consumed
      ModelAvailability.consume_sticky_attempt("claude-3")

      # Second selection should skip to fallback
      result2 =
        Router.route(
          strategies: [%FallbackChain{models: ["claude-3", "gpt-4"]}],
          context: %{availability_service: :global}
        )

      assert {:ok, "gpt-4"} = result2
    end

    test "reset_turn allows sticky retry again" do
      # Mark as sticky and consume
      ModelAvailability.mark_sticky_retry("claude-3")
      ModelAvailability.consume_sticky_attempt("claude-3")

      # After consuming, should fallback
      result1 =
        Router.route(
          strategies: [%FallbackChain{models: ["claude-3"]}],
          context: %{availability_service: :global}
        )

      assert match?({:error, _}, result1)

      # Reset turn
      ModelAvailability.reset_turn()

      # Should be available again
      result2 =
        Router.route(
          strategies: [%FallbackChain{models: ["claude-3"]}],
          context: %{availability_service: :global}
        )

      assert {:ok, "claude-3"} = result2
    end
  end

  describe "convenience functions" do
    test "Routing.fallback/1" do
      assert {:ok, "gpt-4o"} = Routing.fallback(["gpt-4o", "claude-sonnet-4"])
    end

    test "Routing.route_default/1" do
      assert {:ok, _model} = Routing.route_default(role: "coder")
    end

    test "Routing.round_robin/2" do
      assert {:ok, _model} =
               Routing.round_robin(["a", "b", "c"], rotate_every: 2, use_global: false)
    end
  end

  describe "exclusion and filtering" do
    test "excludes failed models from selection" do
      context = %{
        availability_service: :global,
        excluded_models: ["gpt-4o", "claude-sonnet-4"]
      }

      result =
        Router.route(
          strategies: [%FallbackChain{models: ["gpt-4o", "claude-sonnet-4", "gemini-2.5-flash"]}],
          context: context
        )

      assert {:ok, "gemini-2.5-flash"} = result
    end
  end

  describe "error cases" do
    test "returns error when no strategies provided" do
      assert_raise KeyError, fn ->
        Router.route(context: %{})
      end
    end

    test "returns error with full failure details" do
      result =
        Router.route(
          strategies: [
            %FallbackChain{models: []},
            %FallbackChain{models: []}
          ]
        )

      assert match?({:error, {:all_strategies_failed, _}}, result)

      {:error, {:all_strategies_failed, failures}} = result
      assert length(failures) == 2
    end
  end
end
