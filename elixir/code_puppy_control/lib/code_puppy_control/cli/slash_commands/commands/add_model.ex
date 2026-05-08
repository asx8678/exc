defmodule CodePuppyControl.CLI.SlashCommands.Commands.AddModel do
  @moduledoc """
  Add Model slash command: /add_model.

  Interactive flow for browsing providers and models from the models.dev
  catalog, then persisting the selected model into extra_models.json.

  Pragmatic first version: text-based selection (no full TUI split-panel).
  The flow is:

    1. Load providers from ModelsDevParser.Registry
    2. Display numbered provider list; user picks one
    3. Display numbered model list for that provider; user picks one
    4. Build Code Puppy config and persist to extra_models.json
    5. Reload ModelRegistry so the new model is immediately available

  Ported from Python `code_puppy/command_line/add_model_menu.py`.

  The interactive IO flow lives in `AddModel.Interactive` to keep this
  module under the 600-line cap.
  """

  alias CodePuppyControl.ModelsDevParser
  alias CodePuppyControl.ModelsDevParser.ModelInfo
  alias CodePuppyControl.ModelsDevParser.ProviderInfo
  alias CodePuppyControl.CLI.SlashCommands.Commands.AddModelPersistence

  # Providers that use non-OpenAI-compatible APIs or require special auth.
  # These cannot be added via /add_model — the flow returns {:error, reason}.
  @unsupported_providers %{
    "amazon-bedrock" => "Requires AWS SigV4 authentication",
    "azure" => "Requires Azure AD / managed identity authentication",
    "azure-cognitive-services" => "Requires Azure AD / managed identity authentication",
    "google-vertex" => "Requires GCP service account authentication",
    "google-vertex-anthropic" => "Requires GCP service account authentication",
    "cloudflare-workers-ai" => "Requires account ID in URL Path",
    "cloudflare-ai-gateway" => "Requires Cloudflare account ID in URL path",
    "vercel" => "Vercel AI Gateway - not yet supported",
    "v0" => "Vercel v0 - not yet supported",
    "ollama-cloud" => "Requires user-specific Ollama instance URL",
    "github-copilot" => "Requires GitHub Copilot OAuth flow",
    "lmstudio" => "Requires local LM Studio instance URL",
    "llama" => "Requires local Llama.cpp server URL"
  }

  # Hardcoded OpenAI-compatible endpoints for providers that have dedicated
  # SDKs but work fine with custom_openai.
  @provider_endpoints %{
    "xai" => "https://api.x.ai/v1",
    "cohere" => "https://api.cohere.com/compatibility/v1",
    "groq" => "https://api.groq.com/openai/v1",
    "mistral" => "https://api.mistral.ai/v1",
    "togetherai" => "https://api.together.xyz/v1",
    "perplexity" => "https://api.perplexity.ai",
    "deepinfra" => "https://api.deepinfra.com/v1/openai",
    "aihubmix" => "https://aihubmix.com/v1",
    "fireworks-ai" => "https://api.fireworks.ai/inference/v1",
    "deepseek" => "https://api.deepseek.com/v1",
    "openrouter" => "https://openrouter.ai/api/v1"
  }

  # Map provider IDs to Code Puppy model types.
  # Keys MUST match the IDs in the bundled models.dev catalog.
  @provider_type_map %{
    "openai" => "openai",
    "anthropic" => "anthropic",
    "google" => "gemini",
    "mistral" => "custom_openai",
    "groq" => "custom_openai",
    "togetherai" => "custom_openai",
    "fireworks-ai" => "custom_openai",
    "deepseek" => "custom_openai",
    "openrouter" => "custom_openai",
    "cerebras" => "cerebras",
    "cohere" => "custom_openai",
    "perplexity" => "custom_openai",
    "minimax" => "custom_anthropic",
    "xai" => "custom_openai",
    "deepinfra" => "custom_openai",
    "aihubmix" => "custom_openai"
  }

  # Map provider IDs to persisted provider identity strings.
  # Keys MUST match the IDs in the bundled models.dev catalog.
  @provider_identity_map %{
    "openai" => "openai",
    "anthropic" => "anthropic",
    "google" => "google",
    "mistral" => "mistral",
    "groq" => "groq",
    "togetherai" => "togetherai",
    "fireworks-ai" => "fireworks_ai",
    "deepseek" => "deepseek",
    "openrouter" => "openrouter",
    "cerebras" => "cerebras",
    "cohere" => "cohere",
    "perplexity" => "perplexity",
    "minimax" => "minimax",
    "xai" => "xai",
    "deepinfra" => "deepinfra",
    "aihubmix" => "aihubmix"
  }

  @doc """
  Handles `/add_model` — interactive model browser.

  Delegates the interactive IO flow to `AddModel.Interactive.run_interactive/0`.

  Returns `{:continue, state}` always (does not halt the REPL).
  """
  @spec handle_add_model(String.t(), any()) :: {:continue, any()}
  def handle_add_model(_line, state) do
    CodePuppyControl.CLI.SlashCommands.Commands.AddModel.Interactive.run_interactive()
    {:continue, state}
  end

  # ── Public helpers (for testability) ─────────────────────────────────────

  @doc """
  Derive the persisted provider identity for a provider.
  Falls back to replacing hyphens with underscores.
  """
  @spec derive_provider_identity(ProviderInfo.t()) :: String.t()
  def derive_provider_identity(%ProviderInfo{id: id}) do
    Map.get(@provider_identity_map, id, String.replace(id, "-", "_"))
  end

  @doc """
  Check whether a provider is in the unsupported list.
  """
  @spec unsupported_provider?(String.t()) :: boolean()
  def unsupported_provider?(provider_id) do
    Map.has_key?(@unsupported_providers, provider_id)
  end

  @doc """
  Get the reason a provider is unsupported, or nil.
  """
  @spec unsupported_reason(String.t()) :: String.t() | nil
  def unsupported_reason(provider_id) do
    Map.get(@unsupported_providers, provider_id)
  end

  @doc """
  Build a Code Puppy model config map from a ModelInfo and ProviderInfo.

  This mirrors Python's `_build_model_config()` with the same type mapping,
  endpoint derivation, and supported_settings logic.
  """
  @spec build_model_config(ModelInfo.t(), ProviderInfo.t()) :: {:ok, map()} | {:error, String.t()}
  def build_model_config(%ModelInfo{} = model, %ProviderInfo{} = provider) do
    if unsupported_provider?(provider.id) do
      {:error, "Cannot add model from #{provider.name}: #{unsupported_reason(provider.id)}"}
    else
      {:ok, do_build_model_config(model, provider)}
    end
  end

  # Internal builder — callers must check unsupported_provider? first.
  @spec do_build_model_config(ModelInfo.t(), ProviderInfo.t()) :: map()
  defp do_build_model_config(%ModelInfo{} = model, %ProviderInfo{} = provider) do
    model_type = Map.get(@provider_type_map, provider.id, "custom_openai")

    model_name =
      if provider.id == "kimi-for-coding" do
        "kimi-for-coding"
      else
        model.model_id
      end

    config = %{
      "type" => model_type,
      "provider" => derive_provider_identity(provider),
      "name" => model_name
    }

    # Add custom endpoint for non-standard providers
    config =
      if model_type == "custom_openai" do
        add_custom_endpoint(config, provider)
      else
        config
      end

    # Special handling for minimax: uses custom_anthropic but needs endpoint
    config =
      if provider.id == "minimax" and provider.api not in [nil, ""] do
        api_url = String.trim_trailing(provider.api, "/v1")
        api_key_env = if provider.env != [], do: "$#{hd(provider.env)}", else: "$API_KEY"
        Map.put(config, "custom_endpoint", %{"url" => api_url, "api_key" => api_key_env})
      else
        config
      end

    # Add context length
    config =
      if model.context_length > 0 do
        Map.put(config, "context_length", model.context_length)
      else
        config
      end

    # Add supported settings
    Map.put(config, "supported_settings", supported_settings_for(model_type, model))
  end

  @doc """
  Run the interactive flow programmatically (for testing without IO).
  Returns `{:ok, model_key}` on success, or `{:error, reason}` / `:cancelled`.
  """
  @spec run_with_inputs([String.t()]) :: {:ok, String.t()} | {:error, String.t()} | :cancelled
  def run_with_inputs(inputs) do
    case get_providers_list() do
      {:error, reason} ->
        {:error, reason}

      {:ok, providers} ->
        # First input: provider selection
        case inputs do
          [] ->
            :cancelled

          [provider_input | rest] ->
            case parse_selection(provider_input, length(providers)) do
              {:ok, provider_idx} ->
                provider = Enum.at(providers, provider_idx)

                if unsupported_provider?(provider.id) do
                  {:error,
                   "Cannot add model from #{provider.name}: #{unsupported_reason(provider.id)}"}
                else
                  case get_models_list(provider.id) do
                    {:error, reason} ->
                      {:error, reason}

                    {:ok, models} ->
                      case rest do
                        [] ->
                          :cancelled

                        [model_input | _rest] ->
                          case parse_selection(model_input, length(models)) do
                            {:ok, model_idx} ->
                              model = Enum.at(models, model_idx)
                              add_model_to_config(model, provider)

                            {:error, _} = err ->
                              err
                          end
                      end
                  end
                end

              {:error, _} = err ->
                err
            end
        end
    end
  end

  @doc """
  Filter a list of providers by a query string (case-insensitive).
  Matches against provider name and id.
  """
  @spec filter_providers([ProviderInfo.t()], String.t()) :: [ProviderInfo.t()]
  def filter_providers(providers, query) do
    q = String.downcase(query)

    Enum.filter(providers, fn p ->
      String.contains?(String.downcase(p.name), q) or
        String.contains?(String.downcase(p.id), q)
    end)
  end

  @doc """
  Filter a list of models by a query string (case-insensitive).
  Matches against model name and model_id.
  """
  @spec filter_models([ModelInfo.t()], String.t()) :: [ModelInfo.t()]
  def filter_models(models, query) do
    q = String.downcase(query)

    Enum.filter(models, fn m ->
      String.contains?(String.downcase(m.name), q) or
        String.contains?(String.downcase(m.model_id), q)
    end)
  end

  @doc """
  Persist a model config to extra_models.json via AddModelPersistence.

  Public so that `AddModel.Interactive` can call it without
  reaching into private internals.
  """
  @spec add_model_to_config(ModelInfo.t(), ProviderInfo.t()) ::
          {:ok, String.t()} | {:error, term()}
  def add_model_to_config(model, provider) do
    case build_model_config(model, provider) do
      {:ok, config} ->
        model_key = build_model_key(provider, model)
        AddModelPersistence.persist(model_key, config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private: data access ─────────────────────────────────────────────────

  defp get_providers_list do
    case Process.whereis(CodePuppyControl.ModelsDevParser.Registry) do
      nil -> {:error, "ModelsDev registry not started"}
      _pid -> {:ok, ModelsDevParser.get_providers()}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp get_models_list(provider_id) do
    case Process.whereis(CodePuppyControl.ModelsDevParser.Registry) do
      nil -> {:error, "ModelsDev registry not started"}
      _pid -> {:ok, ModelsDevParser.get_models(ModelsDevParser.Registry, provider_id)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Private: config building ─────────────────────────────────────────────

  defp add_custom_endpoint(config, provider) do
    api_url =
      cond do
        provider.api not in [nil, ""] -> provider.api
        true -> Map.get(@provider_endpoints, provider.id)
      end

    if api_url do
      api_key_env = if provider.env != [], do: "$#{hd(provider.env)}", else: "$API_KEY"
      Map.put(config, "custom_endpoint", %{"url" => api_url, "api_key" => api_key_env})
    else
      config
    end
  end

  defp supported_settings_for("anthropic", _model) do
    ["temperature", "extended_thinking", "budget_tokens"]
  end

  defp supported_settings_for("openai", %ModelInfo{model_id: model_id}) do
    if String.contains?(model_id, "gpt-5") do
      if String.contains?(model_id, "codex") do
        ["temperature", "top_p", "reasoning_effort"]
      else
        ["temperature", "top_p", "reasoning_effort", "verbosity"]
      end
    else
      ["temperature", "seed", "top_p"]
    end
  end

  defp supported_settings_for(_type, _model) do
    ["temperature", "seed", "top_p"]
  end

  # ── Private: selection parsing ───────────────────────────────────────────

  defp parse_selection(input, max_index) do
    case Integer.parse(String.trim(input)) do
      {n, ""} when n >= 1 and n <= max_index ->
        {:ok, n - 1}

      _ ->
        {:error, "enter a number between 1 and #{max_index}"}
    end
  end

  # ── Private: key building ────────────────────────────────────────────────

  defp build_model_key(provider, model) do
    "#{provider.id}-#{model.model_id}"
    |> String.replace("/", "-")
    |> String.replace(":", "-")
  end
end
