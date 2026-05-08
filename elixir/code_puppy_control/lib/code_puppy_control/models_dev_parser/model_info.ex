defmodule CodePuppyControl.ModelsDevParser.ModelInfo do
  @moduledoc "Information about a specific model."

  @enforce_keys [:provider_id, :model_id, :name]
  defstruct [
    :provider_id,
    :model_id,
    :name,
    :knowledge,
    :release_date,
    :last_updated,
    :cost_input,
    :cost_output,
    :cost_cache_read,
    attachment: false,
    reasoning: false,
    tool_call: false,
    temperature: true,
    structured_output: false,
    context_length: 0,
    max_output: 0,
    input_modalities: [],
    output_modalities: [],
    open_weights: false
  ]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          model_id: String.t(),
          name: String.t(),
          knowledge: String.t() | nil,
          release_date: String.t() | nil,
          last_updated: String.t() | nil,
          cost_input: number() | nil,
          cost_output: number() | nil,
          cost_cache_read: number() | nil,
          attachment: boolean(),
          reasoning: boolean(),
          tool_call: boolean(),
          temperature: boolean(),
          structured_output: boolean(),
          context_length: non_neg_integer(),
          max_output: non_neg_integer(),
          input_modalities: [String.t()],
          output_modalities: [String.t()],
          open_weights: boolean()
        }

  @doc "Get the full identifier: provider_id::model_id"
  @spec full_id(t()) :: String.t()
  def full_id(%__MODULE__{provider_id: provider_id, model_id: model_id}) do
    "#{provider_id}::#{model_id}"
  end

  @doc "Check if the model supports vision capabilities."
  @spec has_vision?(t()) :: boolean()
  def has_vision?(%__MODULE__{input_modalities: modalities}) do
    "image" in modalities
  end

  @doc "Check if the model supports multiple modalities."
  @spec multimodal?(t()) :: boolean()
  def multimodal?(%__MODULE__{input_modalities: input, output_modalities: output}) do
    length(input) > 1 or length(output) > 1
  end

  @doc "Check if model supports a specific capability."
  @spec supports_capability?(t(), atom() | String.t()) :: boolean()
  def supports_capability?(%__MODULE__{} = model, capability) do
    key = to_capability_key(capability)
    if key, do: Map.get(model, key, false) == true, else: false
  end

  defp to_capability_key(capability) when is_binary(capability) do
    String.to_existing_atom(capability)
  rescue
    ArgumentError -> nil
  end

  defp to_capability_key(capability) when is_atom(capability), do: capability
  defp to_capability_key(_), do: nil
end
