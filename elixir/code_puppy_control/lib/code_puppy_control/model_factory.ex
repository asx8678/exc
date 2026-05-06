defmodule CodePuppyControl.ModelFactory do
  @moduledoc """
  Resolves model names into LLM-ready handles.

  Bridges the gap between `ModelRegistry` (which holds config) and a caller
  that wants to execute against a model. Takes a model name, looks up its
  config, resolves credentials, and builds a `Handle` struct that bundles
  everything needed for an API call.

  ## Usage

      # Resolve a model to a handle
      {:ok, handle} = ModelFactory.resolve("gpt-4o")

      # Use the handle with the LLM facade
      {:ok, response} = LLM.chat(handle, messages, tools)

      # List all available models (with credentials present)
      models = ModelFactory.list_available()

      # Validate credentials for a model
      :ok = ModelFactory.validate_credentials("gpt-4o")

  ## Provider Types Supported

  | Type               | Status   | Notes                           |
  |--------------------|----------|---------------------------------|
  | `openai`           | ✅ Full  | OpenAI Chat Completions API     |
  | `anthropic`        | ✅ Full  | Anthropic Messages API          |
  | `custom_openai`    | ✅ Full  | Custom OpenAI-compatible endpoint|
  | `custom_anthropic` | ✅ Full  | Custom Anthropic-compatible     |
  | `azure_openai`     | ✅ Full  | Azure OpenAI Service            |
  | `cerebras`         | ✅ Full  | Cerebras (OpenAI-compatible)    |
  | `zai_coding`       | ✅ Full  | ZAI Coding (OpenAI-compatible)  |
  | `zai_api`          | ✅ Full  | ZAI API (OpenAI-compatible)     |
  | `openrouter`       | ✅ Full  | OpenRouter gateway              |
  | `gemini`           | ✅ Full  | Google Gemini                   |
  | `gemini_oauth`     | ✅ Full  | Gemini OAuth (OpenAI-compat)    |
  | `custom_gemini`    | ✅ Full  | Custom Gemini-compatible        |
  | `claude_code`      | ✅ Full  | Claude Code OAuth bearer auth   |
  | `chatgpt_oauth`    | ✅ Full  | ChatGPT Codex Responses API     |
  | `round_robin`      | ➡️ Defer | Handled by routing/             |
  """

  alias CodePuppyControl.Auth.RuntimeConnection
  alias CodePuppyControl.ModelFactory.{Credentials, Handle, ProviderRegistry}
  alias CodePuppyControl.ModelRegistry

  require Logger

  # Default API base URLs per provider type
  @default_base_urls %{
    "openai" => "https://api.openai.com",
    "anthropic" => "https://api.anthropic.com",
    "cerebras" => "https://api.cerebras.ai",
    "openrouter" => "https://openrouter.ai/api",
    "gemini" => "https://generativelanguage.googleapis.com",
    "groq" => "https://api.groq.com",
    "together" => "https://api.together.xyz",
    "azure_openai" => "https://YOUR_RESOURCE.openai.azure.com"
  }

  # OAuth-backed model types requiring runtime credential resolution
  @oauth_types ["claude_code", "chatgpt_oauth"]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Resolve a model name into an opaque handle ready for LLM execution.

  Looks up the model in `ModelRegistry`, resolves the provider type,
  fetches credentials, extracts custom endpoint config, and builds
  a `Handle` struct.

  Returns `{:ok, handle}` or `{:error, reason}`.

  ## Examples

      iex> ModelFactory.resolve("gpt-4o")
      {:ok, %Handle{provider_module: OpenAI, ...}}

      iex> ModelFactory.resolve("nonexistent-model")
      {:error, {:unknown_model, "nonexistent-model"}}
  """
  @spec resolve(String.t()) :: {:ok, Handle.t()} | {:error, term()}
  def resolve(model_name) when is_binary(model_name) do
    case ModelRegistry.get_config(model_name) do
      nil ->
        {:error, {:unknown_model, model_name}}

      config ->
        provider_type = ModelRegistry.get_model_type(config) || "unknown"
        do_resolve(model_name, config, provider_type)
    end
  end

  @doc """
  Resolve a model name, raising on error.

  Same as `resolve/1` but returns the handle directly or raises.

  ## Examples

      iex> ModelFactory.resolve!("gpt-4o")
      %Handle{...}
  """
  @spec resolve!(String.t()) :: Handle.t()
  def resolve!(model_name) when is_binary(model_name) do
    case resolve(model_name) do
      {:ok, handle} -> handle
      {:error, reason} -> raise "Failed to resolve model '#{model_name}': #{inspect(reason)}"
    end
  end

  @doc """
  List all available models with their resolved provider info.

  Filters to models where:
  1. The model is in ModelRegistry
  2. The provider type is supported (not unknown)
  3. Credentials are present (API key or OAuth)

  Returns a list of `{model_name, provider_type, provider_module}` tuples.

  ## Examples

      iex> ModelFactory.list_available()
      [{"gpt-4o", "openai", OpenAI}, {"claude-sonnet-4", "anthropic", Anthropic}]
  """
  @spec list_available() :: [{String.t(), String.t(), module()}]
  def list_available do
    ModelRegistry.get_all_configs()
    |> Enum.flat_map(fn {name, config} ->
      provider_type = ModelRegistry.get_model_type(config)

      cond do
        is_nil(provider_type) ->
          []

        provider_type in @oauth_types ->
          # OAuth models are available only when credentials validate
          # (access_token + account_id for chatgpt_oauth, access_token for claude_code)
          with {:ok, mod} <- lookup_provider(provider_type),
               :ok <- Credentials.validate(provider_type, config) do
            [{name, provider_type, mod}]
          else
            _ -> []
          end

        true ->
          case lookup_provider(provider_type) do
            :error ->
              []

            {:ok, mod} ->
              case Credentials.validate(provider_type, config) do
                :ok -> [{name, provider_type, mod}]
                {:missing, _} -> []
              end
          end
      end
    end)
    |> Enum.sort_by(fn {name, _, _} -> name end)
  end

  @doc """
  List all configured models regardless of credential status.

  Unlike `list_available/0` which filters to models with valid
  credentials, this returns every model in the registry with
  its credential validation result. Useful for diagnostics
  and the model selector when no models are "available".

  Returns a list of `{model_name, provider_type, credential_status}` tuples
  where `credential_status` is:
  - `:ok` — credentials present and valid
  - `{:missing, [env_var_names]}` — list of env var names that need setting
  - `{:unsupported, provider_type}` — provider type has no registered module

  ## Examples

      iex> ModelFactory.list_configured()
      [{"gpt-4o", "openai", :ok}, {"claude-sonnet-4", "anthropic", {:missing, ["ANTHROPIC_API_KEY"]}}]
  """
  @spec list_configured() :: [
          {String.t(), term(), :ok | {:missing, [String.t()]} | {:unsupported, term()}}
        ]
  def list_configured do
    ModelRegistry.get_all_configs()
    |> Enum.map(fn {name, config} ->
      provider_type = ModelRegistry.get_model_type(config)

      cred_status =
        case provider_type do
          nil ->
            {:missing, []}

          type ->
            if ProviderRegistry.supported?(type) do
              Credentials.validate(type, config)
            else
              {:unsupported, type}
            end
        end

      {name, provider_type, cred_status}
    end)
    |> Enum.sort_by(fn {name, _, _} -> name end)
  end

  @doc """
  Produce a diagnostic summary of model availability.

  Returns a map with:
  - `:total` — total models in the registry
  - `:available` — count of models with valid credentials
  - `:unavailable` — list of `{model_name, provider_type, missing_vars}` for
    models missing credentials (missing_vars is a list of env var names)
  - `:unsupported` — list of `{model_name, provider_type}` for models whose
    provider type is not registered (no provider module available)
  - `:available_models` — list of `{name, type}` for available models

  Useful for `/model` selector UX and troubleshooting.

  ## Examples

      iex> ModelFactory.diagnostic_summary()
      %{total: 5, available: 1, unavailable: [...], unsupported: [], available_models: [{"gpt-4o", "openai"}]}
  """
  @spec diagnostic_summary() :: %{
          total: non_neg_integer(),
          available: non_neg_integer(),
          unavailable: [{String.t(), term(), [String.t()]}],
          unsupported: [{String.t(), term()}],
          available_models: [{String.t(), term()}]
        }
  def diagnostic_summary do
    configured = list_configured()

    {available, unavailable, unsupported} =
      Enum.reduce(configured, {[], [], []}, fn
        {name, type, :ok}, {avail, unavail, unsup} ->
          {[{name, type} | avail], unavail, unsup}

        {name, type, {:missing, vars}}, {avail, unavail, unsup} ->
          {avail, [{name, type, vars} | unavail], unsup}

        {name, type, {:unsupported, _}}, {avail, unavail, unsup} ->
          {avail, unavail, [{name, type} | unsup]}
      end)

    %{
      total: length(configured),
      available: length(available),
      unavailable: Enum.reverse(unavailable),
      unsupported: Enum.reverse(unsupported),
      available_models: Enum.reverse(available)
    }
  end

  @doc """
  Validate that required credentials exist for a model.

  Returns `:ok` if all required environment variables are set,
  or `{:missing, [env_var_names]}` listing what's missing.

  ## Examples

      iex> ModelFactory.validate_credentials("gpt-4o")
      :ok

      iex> ModelFactory.validate_credentials("some-model-without-key")
      {:missing, ["OPENAI_API_KEY"]}
  """
  @spec validate_credentials(String.t()) :: :ok | {:missing, [String.t()]} | {:error, term()}
  def validate_credentials(model_name) when is_binary(model_name) do
    case ModelRegistry.get_config(model_name) do
      nil ->
        {:error, {:unknown_model, model_name}}

      config ->
        provider_type = ModelRegistry.get_model_type(config) || "unknown"
        Credentials.validate(provider_type, config)
    end
  end

  @doc """
  Returns the provider module for a model type string.

  Useful for introspection without resolving a full handle.

  ## Examples

      iex> ModelFactory.provider_module_for_type("openai")
      {:ok, OpenAI}

      iex> ModelFactory.provider_module_for_type("unknown")
      :error
  """
  @spec provider_module_for_type(String.t()) :: {:ok, module()} | :error
  def provider_module_for_type(provider_type) when is_binary(provider_type) do
    ProviderRegistry.lookup(provider_type)
  end

  # ============================================================================
  # Private: Provider Resolution
  # ============================================================================

  # Safe wrapper around ProviderRegistry.lookup/1.
  # Previously Map.get(@provider_map, provider_type) silently returned nil
  # for non-binary keys (e.g. 123). ProviderRegistry.lookup/1 guards on
  # is_binary, so passing a non-binary crashes with FunctionClauseError.
  # This wrapper preserves the old "return :error for bad types" contract.
  defp lookup_provider(provider_type) when is_binary(provider_type) do
    ProviderRegistry.lookup(provider_type)
  end

  defp lookup_provider(_provider_type), do: :error

  # Round-robin → not handled here, delegates to routing
  defp do_resolve(_model_name, _config, "round_robin") do
    {:error, :round_robin_use_routing}
  end

  # Unknown/unsupported type (including non-binary provider types)
  defp do_resolve(model_name, _config, provider_type) do
    case lookup_provider(provider_type) do
      :error ->
        {:error, {:unsupported_model_type, provider_type, model_name}}

      {:ok, provider_mod} ->
        build_handle(model_name, provider_type, provider_mod)
    end
  end

  defp build_handle(model_name, provider_type, provider_mod) do
    config = ModelRegistry.get_config(model_name) || %{}

    with {:ok, runtime} <- RuntimeConnection.resolve(config, model_name) do
      api_key = resolve_handle_api_key(provider_type, config, runtime.api_key)
      base_url = runtime.base_url || Map.get(@default_base_urls, provider_type)
      extra_headers = runtime.extra_headers

      # Build model opts: the API-facing model name + any config overrides
      api_model_name = Map.get(config, "name", model_name)

      model_opts =
        []
        |> maybe_put_kw(:model, api_model_name)
        |> maybe_put_kw(:temperature, Map.get(config, "temperature"))
        |> maybe_put_kw(:max_tokens, Map.get(config, "max_output_tokens"))
        |> merge_config_opts(config)

      handle = %Handle{
        model_name: model_name,
        provider_module: provider_mod,
        provider_config: config,
        api_key: api_key,
        base_url: base_url,
        extra_headers: extra_headers,
        model_opts: model_opts
      }

      {:ok, handle}
    end
  end

  # ── Model Opts Helpers ────────────────────────────────────────────────────

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_handle_api_key(provider_type, _config, runtime_api_key)
       when provider_type in @oauth_types do
    runtime_api_key
  end

  defp resolve_handle_api_key(provider_type, config, nil) do
    Credentials.resolve_api_key(provider_type, config)
  end

  defp resolve_handle_api_key(_provider_type, _config, runtime_api_key), do: runtime_api_key

  # Merge any extra opts from model config (e.g., "extra_body", "http2", etc.)
  defp merge_config_opts(opts, config) do
    config
    |> Map.get("model_opts", %{})
    |> Enum.reduce(opts, fn {key, val}, acc ->
      key_atom = if is_binary(key), do: String.to_existing_atom(key), else: key
      Keyword.put(acc, key_atom, val)
    end)
  rescue
    ArgumentError ->
      # Unknown atom in model_opts — skip safely
      opts
  end
end
