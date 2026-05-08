defmodule CodePuppyControl.Routing do
  @moduledoc """
  Routing system for model selection in CodePuppy.

  Provides a flexible, strategy-based approach to selecting models for
  different tasks. Supports fallback chains, round-robin distribution,
  and availability-based selection with circuit breaker integration.

  ## Architecture

  The routing system consists of:

  1. **Router** - Main coordinator that chains strategies
  2. **Strategies** - Pluggable selection algorithms
     - `FallbackChain` - Try models in order
     - `RoundRobin` - Rotate through models
     - `LastResort` - Emergency fallback
  3. **ModelAvailability** - Circuit breaker for model health

  ## Quick Start

  ### Simple fallback routing

      CodePuppyControl.Routing.fallback(["claude-sonnet-4", "gpt-4o", "gemini-2.5-flash"])

  ### With availability checking

      CodePuppyControl.Routing.route_default(
        role: "coder",
        availability_service: CodePuppyControl.ModelAvailability
      )

  ### Custom strategy chain

      CodePuppyControl.Routing.Router.route(
        strategies: [
          %FallbackChain{models: primary_models},
          %FallbackChain{models: secondary_models},
          LastResort.new()
        ],
        context: %{
          availability_service: CodePuppyControl.ModelAvailability
        }
      )

  ## Modules

  - `CodePuppyControl.Routing.Router` - Main routing coordinator
  - `CodePuppyControl.Routing.Strategy` - Strategy protocol
  - `CodePuppyControl.Routing.Strategies.FallbackChain` - Ordered fallback strategy
  - `CodePuppyControl.Routing.Strategies.LastResort` - Emergency fallback strategy
  - `CodePuppyControl.Routing.Strategies.RoundRobin` - Round-robin rotation strategy
  - `CodePuppyControl.ModelAvailability` - Circuit breaker for model health

  ## Configuration

  Configure last-resort models in your config:

      config :code_puppy_control, :last_resort_models,
        models: ["gpt-4o-mini", "gemini-2.5-flash"]

  ## Examples

  # Route for specific role with availability check
  iex> CodePuppyControl.Routing.route_default(
  ...>   role: "reviewer",
  ...>   availability_service: CodePuppyControl.ModelAvailability
  ...> )
  {:ok, "claude-sonnet-4"}

  # Fallback when primary fails
  iex> CodePuppyControl.Routing.fallback(["gpt-4o", "gemini-2.5-flash"])
  {:ok, "gpt-4o"}
  """

  # Re-export main modules for convenience
  defdelegate route(opts), to: CodePuppyControl.Routing.Router
  defdelegate route_default(opts \\ []), to: CodePuppyControl.Routing.Router
  defdelegate fallback(models), to: CodePuppyControl.Routing.Router
  defdelegate round_robin(models, opts \\ []), to: CodePuppyControl.Routing.Router
  defdelegate global_round_robin(), to: CodePuppyControl.Routing.Router
end
