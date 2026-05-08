defmodule CodePuppyControl.Routing.Router do
  @moduledoc """
  Main routing coordinator for model selection.

  The Router provides a unified interface for selecting models using
  various routing strategies. It supports strategy chaining, where
  multiple strategies are tried in order until one succeeds.

  ## Usage

      # Simple routing with fallback chain
      Router.route(
        strategies: [%FallbackChain{models: ["a", "b", "c"]}]
      )

      # Multi-strategy routing with last-resort fallback
      Router.route(
        strategies: [
          %FallbackChain{models: primary_models},
          %FallbackChain{models: secondary_models},
          LastResort.new()
        ]
      )

      # With context (availability service, role, etc.)
      Router.route(
        strategies: [...],
        context: %{
          availability_service: ModelAvailability,
          role: "coder",
          excluded_models: ["failing-model"]
        }
      )

  ## Strategy Chaining

  When multiple strategies are provided, the router tries them in order:
  1. First strategy is attempted
  2. If it returns `{:error, _}`, the next strategy is tried
  3. If all fail, `{:error, :all_strategies_failed}` is returned
  4. First successful `{:ok, model}` result is returned

  ## Integration with ModelAvailability

  When the availability service is in context, strategies check model
  health before selection. Models can be marked as:
  - `healthy` - available for selection
  - `sticky_retry` - available for one more attempt
  - `terminal` - unavailable until reset

  ## Examples

      # Basic routing
      iex> Router.route(strategies: [%FallbackChain{models: ["gpt-4"]}])
      {:ok, "gpt-4"}

      # With availability check
      iex> Router.route(
      ...>   strategies: [%FallbackChain{models: ["a", "b"]}],
      ...>   context: %{availability_service: MyAvailability}
      ...> )
      {:ok, "b"}  # If "a" is marked terminal

      # All strategies fail
      iex> Router.route(strategies: [%FallbackChain{models: []}])
      {:error, :all_strategies_failed}
  """

  require Logger

  alias CodePuppyControl.Routing.Strategy
  alias CodePuppyControl.Routing.Strategies.FallbackChain
  alias CodePuppyControl.Routing.Strategies.LastResort
  alias CodePuppyControl.Routing.Strategies.RoundRobin

  @typedoc "Routing options"
  @type opts :: [
          strategies: [Strategy.t()],
          context: Strategy.context()
        ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Routes to select a model using the provided strategies.

  ## Options

    * `:strategies` - List of strategy implementations to try in order
    * `:context` - Context map passed to each strategy (optional)

  ## Returns

    * `{:ok, model_name}` - Successfully selected model
    * `{:error, reason}` - All strategies failed to select a model

  ## Examples

      # Single strategy
      Router.route(strategies: [%FallbackChain{models: ["gpt-4"]}])

      # Multiple strategies with fallback
      Router.route(
        strategies: [
          %FallbackChain{models: primary},
          %FallbackChain{models: secondary},
          LastResort.new()
        ],
        context: %{availability_service: MyAvailability}
      )
  """
  @spec route(opts()) :: {:ok, String.t()} | {:error, term()}
  def route(opts) do
    strategies = Keyword.fetch!(opts, :strategies)
    context = Keyword.get(opts, :context, %{})

    route_with_strategies(strategies, context, [])
  end

  @doc """
  Routes using the default strategy chain.

  Uses the configured default pack and role to build a fallback chain,
  then adds a last-resort fallback.

  ## Options

    * `:role` - Role to route for (default: from context or "coder")
    * `:context` - Additional context for routing
    * `:availability_service` - Optional availability service to check health

  ## Examples

      # Route for default role
      Router.route_default()

      # Route for specific role with availability check
      Router.route_default(
        role: "reviewer",
        availability_service: ModelAvailability
      )
  """
  @spec route_default(keyword()) :: {:ok, String.t()} | {:error, term()}
  def route_default(opts \\ []) do
    role = Keyword.get(opts, :role, "coder")
    context = Keyword.get(opts, :context, %{})
    availability_service = Keyword.get(opts, :availability_service)

    # Get models from current pack
    models = get_models_for_role(role)

    # Build default strategy chain
    strategies = [
      %FallbackChain{models: models},
      LastResort.new()
    ]

    # Build full context with role and optional availability service
    full_context =
      context
      |> Map.put(:role, role)
      |> maybe_put(:availability_service, availability_service)

    route(strategies: strategies, context: full_context)
  end

  @doc """
  Creates a simple fallback chain strategy.

  Convenience function for creating a single-strategy route.

  ## Examples

      Router.fallback(["a", "b", "c"])
      # Equivalent to:
      Router.route(strategies: [%FallbackChain{models: ["a", "b", "c"]}])
  """
  @spec fallback([String.t()]) :: {:ok, String.t()} | {:error, term()}
  def fallback(models) when is_list(models) do
    route(strategies: [%FallbackChain{models: models}])
  end

  @doc """
  Creates a round-robin routing strategy.

  ## Examples

      Router.round_robin(["a", "b", "c"], rotate_every: 5)
  """
  @spec round_robin([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def round_robin(models, opts \\ []) when is_list(models) do
    rotate_every = Keyword.get(opts, :rotate_every, 1)
    use_global = Keyword.get(opts, :use_global, false)

    strategy = %RoundRobin{
      models: models,
      rotate_every: rotate_every,
      use_global: use_global
    }

    route(strategies: [strategy])
  end

  @doc """
  Routes using the global round-robin model rotation.

  This delegates to `RoundRobinModel.advance_and_get/0`.

  ## Examples

      iex> Router.global_round_robin()
      {:ok, "claude-sonnet-4"}
  """
  @spec global_round_robin() :: {:ok, String.t()} | {:error, term()}
  def global_round_robin do
    strategy = %RoundRobin{use_global: true}
    route(strategies: [strategy])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp route_with_strategies([], _context, failures) do
    {:error, {:all_strategies_failed, Enum.reverse(failures)}}
  end

  defp route_with_strategies([strategy | rest], context, failures) do
    case Strategy.select(strategy, context) do
      {:ok, model} ->
        Logger.debug("Router: selected model '#{model}' via #{strategy_type(strategy)}")
        {:ok, model}

      {:error, reason} ->
        Logger.debug("Router: strategy #{strategy_type(strategy)} failed: #{inspect(reason)}")
        route_with_strategies(rest, context, [{strategy_type(strategy), reason} | failures])
    end
  end

  defp strategy_type(%struct{}), do: struct |> to_string() |> String.split(".") |> List.last()

  # Global ModelAvailability is the default availability service
  # Context can override with :availability_service key

  defp get_models_for_role(role) do
    # Try to get models from ModelPacks if available
    try do
      case CodePuppyControl.ModelPacks.get_fallback_chain(role) do
        [_ | _] = chain -> chain
        _ -> default_models_for_role(role)
      end
    rescue
      _ -> default_models_for_role(role)
    catch
      _ -> default_models_for_role(role)
    end
  end

  defp default_models_for_role("planner"), do: ["claude-sonnet-4", "gpt-4o", "gemini-2.5-flash"]
  defp default_models_for_role("coder"), do: ["claude-sonnet-4", "gpt-4o", "gemini-2.5-flash"]
  defp default_models_for_role("reviewer"), do: ["claude-sonnet-4", "gpt-4o-mini"]
  defp default_models_for_role("summarizer"), do: ["gemini-2.5-flash", "gpt-4o-mini"]
  defp default_models_for_role("title"), do: ["gpt-4o-mini", "gemini-2.5-flash"]
  defp default_models_for_role(_), do: ["claude-sonnet-4", "gpt-4o", "gemini-2.5-flash"]

  # Helper to optionally put a key-value pair in a map if value is not nil
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
