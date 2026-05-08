defmodule CodePuppyControl.ModelsDevParser.ProviderInfo do
  @moduledoc "Information about a model provider."

  @enforce_keys [:id, :name, :env]
  defstruct [
    :id,
    :name,
    :env,
    :api,
    :npm,
    :doc,
    models: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          env: [String.t()],
          api: String.t() | nil,
          npm: String.t() | nil,
          doc: String.t() | nil,
          models: %{String.t() => map()}
        }

  @doc "Get the number of models for this provider."
  @spec model_count(t()) :: non_neg_integer()
  def model_count(%__MODULE__{models: models}), do: map_size(models)
end
