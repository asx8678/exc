defmodule CodePuppyControl.LLM do
  @moduledoc """
  Top-level facade for LLM chat operations.

  Routes requests to the appropriate provider based on model name using
  `CodePuppyControl.ModelRegistry` for configuration lookup.

  ## Usage

      # Non-streaming
      {:ok, response} = LLM.chat(messages, tools, model: "gpt-4o")

      # Streaming
      :ok = LLM.stream_chat(messages, tools, [model: "gpt-4o"], fn event ->
        case event do
          {:part_delta, %{type: :text, text: text}} -> IO.write(text)
          {:done, response} -> IO.puts("\nDone!")
          _ -> :ok
        end
      end)

      # Via pre-resolved handle
      {:ok, handle} = ModelFactory.resolve("gpt-4o")
      {:ok, response} = LLM.chat(handle, messages, tools)

  ## Provider Routing

  Models are resolved through `ModelRegistry.get_config/1`. The `"type"` field
  maps to providers:

  | Type | Provider Module |
  |--------------------|----------------------------------------|
  | `"openai"` | `CodePuppyControl.LLM.Providers.OpenAI`|
  | `"anthropic"` | `CodePuppyControl.LLM.Providers.Anthropic`|
  | `"custom_openai"` | `CodePuppyControl.LLM.Providers.OpenAI`|
  | `"custom_anthropic"` | `CodePuppyControl.LLM.Providers.Anthropic`|

  Options are forwarded to the provider. The `:model` option defaults to the
  model name from the registry config.
  """

  alias CodePuppyControl.Auth.RuntimeConnection
  alias CodePuppyControl.LLM.Provider
  alias CodePuppyControl.ModelFactory.Handle
  alias CodePuppyControl.ModelRegistry
  alias CodePuppyControl.RateLimiter

  require Logger

  @type provider_mod :: module()

  # Map from model type to provider module
  @provider_map %{
    "openai" => CodePuppyControl.LLM.Providers.OpenAI,
    "anthropic" => CodePuppyControl.LLM.Providers.Anthropic,
    "custom_openai" => CodePuppyControl.LLM.Providers.OpenAI,
    "custom_anthropic" => CodePuppyControl.LLM.Providers.Anthropic,
    "azure_openai" => CodePuppyControl.LLM.Providers.Azure,
    "cerebras" => CodePuppyControl.LLM.Providers.OpenAI,
    "zai_coding" => CodePuppyControl.LLM.Providers.OpenAI,
    "zai_api" => CodePuppyControl.LLM.Providers.OpenAI,
    "openrouter" => CodePuppyControl.LLM.Providers.OpenAI,
    "gemini" => CodePuppyControl.LLM.Providers.Google,
    "gemini_oauth" => CodePuppyControl.LLM.Providers.Google,
    "custom_gemini" => CodePuppyControl.LLM.Providers.Google,
    "claude_code" => CodePuppyControl.LLM.Providers.Anthropic,
    "chatgpt_oauth" => CodePuppyControl.LLM.Providers.OpenAI,
    "groq" => CodePuppyControl.LLM.Providers.Groq,
    "together" => CodePuppyControl.LLM.Providers.Together
  }

  # ── chat/2,3 ──────────────────────────────────────────────────────────────

  def chat(messages, tools \\ [], opts \\ [])

  @doc """
  Non-streaming chat completion via a pre-resolved model handle.

  Use `ModelFactory.resolve/1` to get a handle, then pass it here.
  """
  @spec chat(Handle.t(), [Provider.message()], [Provider.tool()]) ::
          {:ok, Provider.response()} | {:error, term()}
  def chat(%Handle{} = handle, messages, tools) do
    provider_opts = Handle.to_provider_opts(handle)
    model_name = handle.model_name || ""
    rate_limiter_acquire(model_name)
    result = handle.provider_module.chat(messages, tools, provider_opts)
    rate_limiter_record(model_name, result_status(result))
    result
  end

  @spec chat([Provider.message()], [Provider.tool()], keyword()) ::
          {:ok, Provider.response()} | {:error, term()}
  def chat(messages, tools, opts)
      when is_list(messages) and is_list(tools) and is_list(opts) do
    with {:ok, provider_mod, resolved_opts} <- resolve_provider(opts) do
      model_name = Keyword.get(resolved_opts, :model, "")
      rate_limiter_acquire(model_name)
      result = provider_mod.chat(messages, tools, resolved_opts)
      rate_limiter_record(model_name, result_status(result))
      result
    end
  end

  # ── stream_chat/3,4 ───────────────────────────────────────────────────────

  def stream_chat(messages, tools \\ [], opts \\ [], callback_fn)

  @doc """
  Streaming chat completion via a pre-resolved model handle.
  """
  @spec stream_chat(
          Handle.t(),
          [Provider.message()],
          [Provider.tool()],
          (Provider.stream_event() -> any())
        ) ::
          :ok | {:error, term()}
  def stream_chat(%Handle{} = handle, messages, tools, callback_fn) do
    provider_opts = Handle.to_provider_opts(handle)
    model_name = handle.model_name || ""
    rate_limiter_acquire(model_name)
    result = handle.provider_module.stream_chat(messages, tools, provider_opts, callback_fn)
    rate_limiter_record(model_name, stream_result_status(result))
    result
  end

  @spec stream_chat(
          [Provider.message()],
          [Provider.tool()],
          keyword(),
          (Provider.stream_event() -> any())
        ) ::
          :ok | {:error, term()}
  def stream_chat(messages, tools, opts, callback_fn)
      when is_list(messages) and is_list(tools) and is_list(opts) and is_function(callback_fn, 1) do
    with {:ok, provider_mod, resolved_opts} <- resolve_provider(opts) do
      model_name = Keyword.get(resolved_opts, :model, "")
      rate_limiter_acquire(model_name)
      result = provider_mod.stream_chat(messages, tools, resolved_opts, callback_fn)
      rate_limiter_record(model_name, stream_result_status(result))
      result
    end
  end

  # ── Provider Introspection ────────────────────────────────────────────────

  @doc """
  Returns the provider module for a given model name.

  ## Examples

      iex> LLM.provider_for("gpt-4o")
      {:ok, CodePuppyControl.LLM.Providers.OpenAI}
  """
  @spec provider_for(String.t()) :: {:ok, provider_mod()} | {:error, term()}
  def provider_for(model_name) when is_binary(model_name) do
    case ModelRegistry.get_config(model_name) do
      nil ->
        {:error, {:unknown_model, model_name}}

      config ->
        type = ModelRegistry.get_model_type(config)

        case Map.get(@provider_map, type) do
          nil -> {:error, {:unsupported_model_type, type, model_name}}
          mod -> {:ok, mod}
        end
    end
  end

  @doc """
  Lists all models and their provider modules.
  """
  @spec list_providers() :: %{String.t() => provider_mod()}
  def list_providers do
    ModelRegistry.get_all_configs()
    |> Enum.reduce(%{}, fn {name, config}, acc ->
      type = ModelRegistry.get_model_type(config)

      case Map.get(@provider_map, type) do
        nil -> acc
        mod -> Map.put(acc, name, mod)
      end
    end)
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp resolve_provider(opts) do
    cond do
      provider_mod = Keyword.get(opts, :provider) ->
        {:ok, provider_mod, opts}

      model_name = Keyword.get(opts, :model) ->
        config = ModelRegistry.get_config(model_name) || %{}

        case provider_for(model_name) do
          {:ok, provider_mod} ->
            with {:ok, runtime} <- RuntimeConnection.resolve(config, model_name) do
              resolved_opts =
                opts
                |> maybe_put_opt(:api_key, runtime.api_key)
                |> maybe_put_opt(:base_url, runtime.base_url)
                |> merge_extra_headers(runtime.extra_headers)
                |> resolve_api_key(provider_mod, model_name)
                |> Keyword.put(:model, resolve_model_api_name(model_name))

              {:ok, provider_mod, resolved_opts}
            end

          error ->
            error
        end

      true ->
        {:error, :no_model_or_provider_specified}
    end
  end

  defp resolve_api_key(opts, provider_mod, model_name) do
    if Keyword.has_key?(opts, :api_key) do
      opts
    else
      config = ModelRegistry.get_config(model_name) || %{}

      case ModelRegistry.get_model_type(config) do
        provider_type when provider_type in ["claude_code", "chatgpt_oauth"] ->
          opts

        _ ->
          api_key_env = config["api_key_env"] || default_api_key_env(provider_mod)
          api_key = CodePuppyControl.ModelFactory.Credentials.env_or_store(api_key_env)
          Keyword.put(opts, :api_key, api_key)
      end
    end
  end

  defp resolve_model_api_name(model_name) do
    config = ModelRegistry.get_config(model_name) || %{}
    config["name"] || model_name
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, []), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp merge_extra_headers(opts, []), do: opts

  defp merge_extra_headers(opts, extra_headers) when is_list(extra_headers) do
    existing = Keyword.get(opts, :extra_headers, [])
    Keyword.put(opts, :extra_headers, existing ++ extra_headers)
  end

  defp default_api_key_env(CodePuppyControl.LLM.Providers.OpenAI), do: "OPENAI_API_KEY"
  defp default_api_key_env(CodePuppyControl.LLM.Providers.Anthropic), do: "ANTHROPIC_API_KEY"
  defp default_api_key_env(CodePuppyControl.LLM.Providers.Google), do: "GOOGLE_API_KEY"
  defp default_api_key_env(CodePuppyControl.LLM.Providers.Azure), do: "AZURE_OPENAI_API_KEY"
  defp default_api_key_env(CodePuppyControl.LLM.Providers.Groq), do: "GROQ_API_KEY"
  defp default_api_key_env(CodePuppyControl.LLM.Providers.Together), do: "TOGETHER_API_KEY"
  defp default_api_key_env(_), do: "API_KEY"

  # ── Rate Limiter Integration ──────────────────────────────────────
  defp result_status({:ok, _}), do: 200
  defp result_status({:error, %{status: status}}), do: status
  defp result_status({:error, _}), do: 500

  defp stream_result_status(:ok), do: 200
  defp stream_result_status({:error, %{status: status}}), do: status
  defp stream_result_status({:error, _}), do: 500

  defp rate_limiter_acquire(model_name, estimated_tokens \\ 1000) do
    if Process.whereis(RateLimiter) do
      RateLimiter.acquire(model_name, estimated_tokens: estimated_tokens)
    else
      :ok
    end
  catch
    _, _ -> :ok
  end

  defp rate_limiter_record(model_name, status, headers \\ []) do
    if Process.whereis(RateLimiter) do
      RateLimiter.record_response(model_name, status, headers)
    end
  catch
    _, _ -> :ok
  end
end
