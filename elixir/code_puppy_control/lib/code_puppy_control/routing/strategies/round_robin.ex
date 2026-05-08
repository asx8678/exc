defmodule CodePuppyControl.Routing.Strategies.RoundRobin do
  @moduledoc """
  Round-robin routing strategy.

  Cycles through models in a rotating fashion, distributing requests
  evenly across multiple candidate models. This helps with load
  distribution and rate limit management.

  This strategy wraps the `CodePuppyControl.RoundRobinModel` GenServer
  for stateful rotation tracking.

  ## Usage

      strategy = %RoundRobin{
        models: ["claude-sonnet-4", "gpt-4o", "gemini-2.5-flash"],
        rotate_every: 5  # Rotate after 5 requests per model
      }

      {:ok, model} = Strategy.select(strategy, %{})

  ## With Pre-Configured RoundRobinModel

  If you've already configured the RoundRobinModel GenServer, you can
  use it directly:

      # The strategy will call RoundRobinModel.advance_and_get()
      strategy = %RoundRobin{use_global: true}

  ## Examples

      iex> strategy = %RoundRobin{models: ["a", "b", "c"]}
      iex> Strategy.select(strategy, %{})
      {:ok, "a"}

  """

  alias CodePuppyControl.Routing.Strategy
  alias CodePuppyControl.RoundRobinModel

  @type t :: %__MODULE__{
          models: [String.t()] | nil,
          rotate_every: pos_integer(),
          use_global: boolean()
        }

  defstruct models: nil,
            rotate_every: 1,
            use_global: true

  defimpl Strategy do
    alias CodePuppyControl.Routing.Strategies.RoundRobin

    @doc """
    Selects the next model in the round-robin rotation.

    When `use_global: true`, delegates to the global `RoundRobinModel`.
    Otherwise, maintains local state for just this selection.
    """
    def select(%RoundRobin{use_global: true}, _context) do
      case RoundRobinModel.advance_and_get() do
        nil -> {:error, :no_models_configured}
        model -> {:ok, model}
      end
    end

    def select(%RoundRobin{models: nil, use_global: false}, _context) do
      {:error, :no_models_configured}
    end

    def select(%RoundRobin{models: []}, _context) do
      {:error, :no_models_available}
    end

    def select(%RoundRobin{models: models, rotate_every: _rotate_every}, context) do
      excluded = Map.get(context, :excluded_models, [])
      available_models = Enum.reject(models, &(&1 in excluded))

      case available_models do
        [] ->
          {:error, :all_models_excluded}

        [first | _rest] ->
          # NOTE: Non-global mode doesn't maintain state between calls.
          # For true round-robin rotation, use use_global: true (the default)
          # which delegates to RoundRobinModel for stateful tracking.
          {:ok, first}
      end
    end
  end
end
