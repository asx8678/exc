defmodule CodePuppyControl.ModelPacks.RoleConfig do
  @moduledoc """
  Configuration for a specific role within a model pack.

  Fields:
  - `primary` - The primary model for this role (required, enforced)
  - `fallbacks` - Ordered list of fallback models
  - `trigger` - What triggers fallback ("context_overflow", "provider_failure", "always")
  """

  @enforce_keys [:primary]
  defstruct [:primary, fallbacks: [], trigger: "provider_failure"]

  @type t :: %__MODULE__{
          primary: String.t(),
          fallbacks: [String.t()],
          trigger: String.t()
        }

  @doc """
  Returns the full model chain: primary + fallbacks.

  ## Examples

      iex> role = %RoleConfig{primary: "model-a", fallbacks: ["model-b", "model-c"]}
      iex> RoleConfig.get_model_chain(role)
      ["model-a", "model-b", "model-c"]
  """
  @spec get_model_chain(t()) :: [String.t()]
  def get_model_chain(%__MODULE__{primary: primary, fallbacks: fallbacks}) do
    [primary | fallbacks]
  end
end
