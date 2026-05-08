defprotocol CodePuppyControl.Routing.Strategy do
  @moduledoc """
  Protocol for routing strategies in CodePuppy.

  Routing strategies determine how to select a model from a set of candidates.
  Different strategies can implement various selection algorithms:
  - Fallback chains (try first available)
  - Round-robin rotation
  - Load balancing
  - Availability-based selection

  ## Implementing a Strategy

  To create a custom strategy, implement the `Strategy` protocol:

      defmodule MyApp.MyStrategy do
        defstruct [:models, :config_option]

        defimpl CodePuppyControl.Routing.Strategy do
          def select(strategy, context) do
            # Return {:ok, model_name} or {:error, reason}
          end
        end
      end

  ## Context

  The `context` argument passed to `select/2` is a map that may contain:
  - `:availability_service` - the ModelAvailability service pid or name
  - `:role` - the role requesting the model
  - `:task_type` - type of task being performed
  - `:excluded_models` - models to exclude from selection
  """

  @typedoc "A routing strategy implementation"
  @type t :: %{
          :__struct__ => atom(),
          optional(atom()) => term()
        }

  @typedoc "Context for model selection"
  @type context :: %{
          optional(:availability_service) => pid() | atom(),
          optional(:role) => String.t(),
          optional(:task_type) => String.t(),
          optional(:excluded_models) => [String.t()],
          optional(atom()) => term()
        }

  @doc """
  Selects a model using this strategy.

  Returns `{:ok, model_name}` if a model is selected, or `{:error, reason}`
  if no suitable model could be found.
  """
  @spec select(t(), context()) :: {:ok, String.t()} | {:error, term()}
  def select(strategy, context)
end
