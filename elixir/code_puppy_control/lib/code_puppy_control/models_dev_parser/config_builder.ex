defmodule CodePuppyControl.ModelsDevParser.ConfigBuilder do
  @moduledoc """
  Builds Code Puppy configuration maps from ModelInfo and ProviderInfo structs.

  Converts parsed model data into the format expected by the Code Puppy
  configuration system.
  """

  alias CodePuppyControl.ModelsDevParser.{ModelInfo, ProviderInfo}

  @provider_type_map %{
    "anthropic" => "anthropic",
    "openai" => "openai",
    "google" => "gemini",
    "deepseek" => "deepseek",
    "ollama" => "ollama",
    "groq" => "groq",
    "cohere" => "cohere",
    "mistral" => "mistral"
  }

  @doc """
  Converts a ModelInfo and ProviderInfo into a Code Puppy configuration map.

  ## Example

      iex> model = %ModelInfo{provider_id: "anthropic", model_id: "claude-3", ...}
      iex> provider = %ProviderInfo{id: "anthropic", name: "Anthropic", ...}
      iex> ConfigBuilder.build(model, provider)
      %{"type" => "anthropic", "model" => "claude-3", ...}
  """
  @spec build(ModelInfo.t(), ProviderInfo.t() | nil) :: map()
  def build(%ModelInfo{} = model, %ProviderInfo{} = provider) do
    provider_type = Map.get(@provider_type_map, provider.id, provider.id)

    # Build base configuration
    config =
      %{}
      |> maybe_put("type", provider_type)
      |> maybe_put("model", model.model_id)
      |> maybe_put("enabled", true)
      |> maybe_put("provider_id", provider.id)
      |> maybe_put("env_vars", provider.env)
      |> maybe_put("api_url", provider.api)
      |> maybe_put("npm_package", provider.npm)
      |> maybe_put("input_cost_per_token", model.cost_input)
      |> maybe_put("output_cost_per_token", model.cost_output)
      |> maybe_put("cache_read_cost_per_token", model.cost_cache_read)
      |> maybe_put("max_tokens", model.context_length, &(&1 > 0))
      |> maybe_put("max_output_tokens", model.max_output, &(&1 > 0))
      |> maybe_put("input_modalities", model.input_modalities, &(length(&1) > 0))
      |> maybe_put("output_modalities", model.output_modalities, &(length(&1) > 0))

    # Add capabilities map
    capabilities = %{
      "attachment" => model.attachment,
      "reasoning" => model.reasoning,
      "tool_call" => model.tool_call,
      "temperature" => model.temperature,
      "structured_output" => model.structured_output
    }

    config = Map.put(config, "capabilities", capabilities)

    # Add metadata
    config = add_metadata(config, model)

    config
  end

  def build(%ModelInfo{} = model, nil) do
    # Handle case where provider is not found - use minimal config
    %{
      "type" => model.provider_id,
      "model" => model.model_id,
      "enabled" => true,
      "provider_id" => model.provider_id,
      "capabilities" => %{
        "attachment" => model.attachment,
        "reasoning" => model.reasoning,
        "tool_call" => model.tool_call,
        "temperature" => model.temperature,
        "structured_output" => model.structured_output
      }
    }
  end

  @doc """
  Conditionally puts a value into a map if it passes the condition.

  ## Examples

      iex> ConfigBuilder.maybe_put(%{}, "key", "value")
      %{"key" => "value"}

      iex> ConfigBuilder.maybe_put(%{}, "key", nil)
      %{}

      iex> ConfigBuilder.maybe_put(%{}, "key", 0, &(&1 > 0))
      %{}
  """
  @spec maybe_put(map(), String.t(), any()) :: map()
  def maybe_put(map, key, value, condition_fn \\ &is_not_nil/1)

  def maybe_put(map, key, value, condition_fn) do
    if condition_fn.(value) do
      Map.put(map, key, value)
    else
      map
    end
  end

  defp is_not_nil(nil), do: false
  defp is_not_nil(""), do: false
  defp is_not_nil([]), do: false
  defp is_not_nil(_), do: true

  # Add metadata section if any fields are present
  defp add_metadata(config, model) do
    metadata =
      %{}
      |> maybe_put("knowledge", model.knowledge)
      |> maybe_put("release_date", model.release_date)
      |> maybe_put("last_updated", model.last_updated)
      |> maybe_put("open_weights", model.open_weights)

    if map_size(metadata) > 0 do
      Map.put(config, "metadata", metadata)
    else
      config
    end
  end
end
