defmodule CodePuppyControl.Routing.Strategies.LastResort do
  @moduledoc """
  Last-resort fallback routing strategy.

  Provides emergency fallback when all other routing strategies fail.
  This strategy maintains a set of "last resort" models that are always
  tried when primary routing returns no available models.

  Inspired by Gemini CLI's lastResortPolicy handler.

  ## Usage

      # Define last resort models
      last_resort = %LastResort{
        models: ["gpt-4o-mini", "gemini-2.5-flash"]
      }

      # Use as final fallback
      case primary_strategy_select() do
        {:error, _} -> Strategy.select(last_resort, context)
      end

  ## Configuration

  Last resort models can be configured via application environment:

      config :code_puppy_control, :last_resort_models,
        models: ["gpt-4o-mini", "gemini-2.5-flash"]

  ## Examples

      iex> strategy = %LastResort{models: ["emergency-model"]}
      iex> Strategy.select(strategy, %{})
      {:ok, "emergency-model"}

      iex> strategy = %LastResort{models: []}
      iex> Strategy.select(strategy, %{})
      {:error, :no_last_resort_models}
  """

  alias CodePuppyControl.Routing.Strategy

  @type t :: %__MODULE__{
          models: [String.t()]
        }

  defstruct models: []

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Returns the default last resort models from application configuration.
  """
  @spec default_models() :: [String.t()]
  def default_models do
    Application.get_env(:code_puppy_control, :last_resort_models, [])
    |> Keyword.get(:models, ["gpt-4o-mini", "gemini-2.5-flash"])
  end

  @doc """
  Creates a new LastResort strategy with default models.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{models: default_models()}
  end

  @doc """
  Creates a new LastResort strategy with custom models.
  """
  @spec new([String.t()]) :: t()
  def new(models) when is_list(models) do
    %__MODULE__{models: models}
  end

  defimpl Strategy do
    alias CodePuppyControl.ModelAvailability
    alias CodePuppyControl.Routing.Strategies.LastResort

    @doc """
    Selects a last-resort model.

    Unlike the FallbackChain, this strategy ignores the availability service
    unless `check_availability: true` is set in context. Last resort models
    are meant to be emergency fallbacks that are always tried.
    """
    def select(%LastResort{models: nil}, _context) do
      {:error, :no_last_resort_models}
    end

    def select(%LastResort{models: []}, _context) do
      {:error, :no_last_resort_models}
    end

    def select(%LastResort{models: models}, context) when is_list(models) do
      excluded = Map.get(context, :excluded_models, [])
      check_availability = Map.get(context, :check_last_resort_availability, false)
      available_models = Enum.reject(models, &(&1 in excluded))

      case available_models do
        [] ->
          {:error, :all_last_resort_excluded}

        _ when not check_availability ->
          # Don't check availability for last resort models by default
          {:ok, hd(available_models)}

        _ ->
          # Optionally check availability using injected service
          availability_service =
            case Map.get(context, :availability_service) do
              nil -> ModelAvailability
              :global -> ModelAvailability
              service -> service
            end

          result = availability_service.select_first_available(available_models)

          case result.selected_model do
            nil -> {:error, :no_last_resort_available}
            model -> {:ok, model}
          end
      end
    end
  end
end
