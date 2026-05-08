defmodule CodePuppyControl.ModelsDevParser do
  @moduledoc """
  Models development API parser for Code Puppy.

  This module provides functionality to parse and work with the models.dev API,
  including provider and model information, search capabilities, and conversion
  to Code Puppy configuration format.

  The parser fetches data from the live models.dev API first, falling back to a
  bundled JSON file if the API is unavailable.

  ## Features

  - Parse provider and model information from JSON
  - TTL-based caching of API responses
  - Search models by name and capabilities
  - Filter by cost constraints and context length
  - Convert to Code Puppy configuration format

  ## Usage

      # Create registry from bundled JSON (sync, no API fetch)
      {:ok, registry} = ModelsDevParser.Registry.new()

      # Create registry with async API fetch
      {:ok, registry} = ModelsDevParser.Registry.new_async()

      # Get all providers
      providers = ModelsDevParser.get_providers(registry)

      # Search models
      models = ModelsDevParser.search_models(registry, query: "gpt", capabilities: %{"vision" => true})
  """

  alias CodePuppyControl.ModelsDevParser.ProviderInfo
  alias CodePuppyControl.ModelsDevParser.ModelInfo
  alias CodePuppyControl.ModelsDevParser.Registry

  @doc "Get all providers, sorted by name."
  @spec get_providers(pid() | atom()) :: [ProviderInfo.t()]
  def get_providers(pid \\ Registry), do: Registry.get_providers(pid)

  @doc "Get a specific provider by ID."
  @spec get_provider(pid() | atom(), String.t()) :: ProviderInfo.t() | nil
  def get_provider(pid \\ Registry, provider_id), do: Registry.get_provider(pid, provider_id)

  @doc "Get models, optionally filtered by provider."
  @spec get_models(pid() | atom(), String.t() | nil) :: [ModelInfo.t()]
  def get_models(pid \\ Registry, provider_id \\ nil), do: Registry.get_models(pid, provider_id)

  @doc "Get a specific model by provider and model ID."
  @spec get_model(pid() | atom(), String.t(), String.t()) :: ModelInfo.t() | nil
  def get_model(pid \\ Registry, provider_id, model_id),
    do: Registry.get_model(pid, provider_id, model_id)

  @doc """
  Search models by name/query and filter by capabilities.

  ## Options
  - `:query` - Search string (case-insensitive, matches name or model_id)
  - `:capability_filters` - Map of capability names to required boolean values

  ## Examples

      # Search by name
      ModelsDevParser.search_models(registry, query: "gpt")

      # Filter by capabilities
      ModelsDevParser.search_models(registry, capability_filters: %{"vision" => true})
  """
  @spec search_models(pid() | atom(), Keyword.t()) :: [ModelInfo.t()]
  def search_models(pid \\ Registry, opts \\ []), do: Registry.search_models(pid, opts)

  @doc """
  Filter a list of models by cost constraints.

  ## Examples

      models = ModelsDevParser.get_models(registry)
      affordable = ModelsDevParser.filter_by_cost(registry, models, 0.001, nil)
  """
  @spec filter_by_cost(
          pid() | atom(),
          [ModelInfo.t()],
          number() | nil,
          number() | nil
        ) :: [ModelInfo.t()]
  def filter_by_cost(pid \\ Registry, models, max_input_cost \\ nil, max_output_cost \\ nil),
    do: Registry.filter_by_cost(pid, models, max_input_cost, max_output_cost)

  @doc "Filter models by minimum context length."
  @spec filter_by_context(pid() | atom(), [ModelInfo.t()], non_neg_integer()) ::
          [ModelInfo.t()]
  def filter_by_context(pid \\ Registry, models, min_context_length),
    do: Registry.filter_by_context(pid, models, min_context_length)

  @doc """
  Convert a model to Code Puppy configuration format.

  Returns a map with all the necessary configuration fields for Code Puppy.
  """
  @spec to_config(pid() | atom(), ModelInfo.t()) :: map()
  def to_config(pid \\ Registry, %ModelInfo{} = model), do: Registry.to_config(pid, model)

  @doc "Get the data source that was used to load the registry."
  @spec data_source(pid() | atom()) :: String.t()
  def data_source(pid \\ Registry), do: Registry.data_source(pid)

  @doc "Refresh data from the API (bypasses cache)."
  @spec refresh(pid() | atom()) :: :ok | {:error, term()}
  def refresh(pid \\ Registry), do: Registry.refresh(pid)
end
