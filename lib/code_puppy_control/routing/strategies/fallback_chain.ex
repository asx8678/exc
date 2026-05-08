defmodule CodePuppyControl.Routing.Strategies.FallbackChain do
  @moduledoc """
  Fallback chain routing strategy.

  Tries models in order until one is available. This is the most basic
  and commonly used routing strategy - it works through a priority-ordered
  list of models, selecting the first one that is available.

  ## Usage

      chain = %FallbackChain{
        models: ["claude-sonnet-4", "gpt-4o", "gemini-2.5-flash"]
      }

      {:ok, model} = Strategy.select(chain, %{})

  ## With Availability Service

  When an availability service is provided in the context, the strategy
  checks model health before selecting:

      context = %{availability_service: ModelAvailability}
      {:ok, model} = Strategy.select(chain, context)

  ## Examples

      iex> chain = %FallbackChain{models: ["a", "b", "c"]}
      iex> Strategy.select(chain, %{})
      {:ok, "a"}

      iex> chain = %FallbackChain{models: []}
      iex> Strategy.select(chain, %{})  
      {:error, :no_models_available}
  """

  alias CodePuppyControl.Routing.Strategy

  @type t :: %__MODULE__{
          models: [String.t()]
        }

  defstruct [:models]

  defimpl Strategy do
    alias CodePuppyControl.ModelAvailability
    alias CodePuppyControl.Routing.Strategies.FallbackChain

    @doc """
    Selects the first available model from the fallback chain.

    If an availability service is provided in the context, it checks
    each model's health status before selecting.
    """
    def select(%FallbackChain{models: []}, _context) do
      {:error, :no_models_available}
    end

    def select(%FallbackChain{models: models}, context) do
      excluded = Map.get(context, :excluded_models, [])
      available_models = Enum.reject(models, &(&1 in excluded))

      case available_models do
        [] ->
          {:error, :no_models_available}

        _ ->
          # Get availability service from context, handling special :global atom
          # :global means "use the global ModelAvailability GenServer"
          availability_service =
            case Map.get(context, :availability_service) do
              nil -> ModelAvailability
              :global -> ModelAvailability
              service -> service
            end

          # Use the injected availability service to select first available model
          result = availability_service.select_first_available(available_models)

          case result.selected_model do
            nil -> {:error, {:all_models_unavailable, result.skipped}}
            model -> {:ok, model}
          end
      end
    end
  end
end
