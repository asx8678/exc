defmodule CodePuppyControl.ModelFactory.ProviderRegistry do
  @moduledoc """
  Concurrency-safe registry mapping provider type strings to provider modules.

  Analogous to Python's centralized model type registry in
  `code_puppy/model_config.py`, but for the Elixir provider modules
  currently hard-coded in `CodePuppyControl.ModelFactory`.

  ## Architecture

  Backed by an `Agent` holding a `%{type => module}` map. The agent is
  started as part of the application supervision tree. All reads and
  writes go through the agent, guaranteeing serialised access without
  locks.

  ## Public API

  | Function          | Purpose                                    |
  |-------------------|--------------------------------------------|
  | `built_in_types/0`| Sorted list of built-in provider type keys  |
  | `all/0`           | Current full type → module map             |
  | `lookup/1`        | `{:ok, module} \| :error` for a type       |
  | `supported?/1`    | Boolean check for a type                   |
  | `register/2`      | Add or override a type → module mapping     |
  | `reset_for_test/0`| Restore built-ins only (**test support**)  |

  ## Built-in Provider Mappings

  Mirrors `ModelFactory.@provider_map` exactly:

  | Type               | Module                                             |
  |--------------------|----------------------------------------------------|
  | `openai`           | `CodePuppyControl.LLM.Providers.OpenAI`            |
  | `anthropic`        | `CodePuppyControl.LLM.Providers.Anthropic`         |
  | `custom_openai`    | `CodePuppyControl.LLM.Providers.OpenAI`            |
  | `custom_anthropic` | `CodePuppyControl.LLM.Providers.Anthropic`         |
  | `azure_openai`     | `CodePuppyControl.LLM.Providers.Azure`             |
  | `cerebras`         | `CodePuppyControl.LLM.Providers.OpenAI`            |
  | `zai_coding`       | `CodePuppyControl.LLM.Providers.OpenAI`            |
  | `zai_api`          | `CodePuppyControl.LLM.Providers.OpenAI`            |
  | `openrouter`       | `CodePuppyControl.LLM.Providers.OpenAI`            |
  | `gemini`           | `CodePuppyControl.LLM.Providers.Google`            |
  | `gemini_oauth`     | `CodePuppyControl.LLM.Providers.Google`            |
  | `custom_gemini`    | `CodePuppyControl.LLM.Providers.Google`            |
  | `claude_code`      | `CodePuppyControl.LLM.Providers.Anthropic`         |
  | `chatgpt_oauth`    | `CodePuppyControl.LLM.Providers.ChatGPTCodex`      |
  | `groq`             | `CodePuppyControl.LLM.Providers.Groq`              |
  | `together`         | `CodePuppyControl.LLM.Providers.Together`          |
  """

  alias CodePuppyControl.LLM.Providers.{
    OpenAI,
    Anthropic,
    Google,
    Azure,
    Groq,
    Together,
    ChatGPTCodex
  }

  @registry_name __MODULE__

  @built_ins %{
    "openai" => OpenAI,
    "anthropic" => Anthropic,
    "custom_openai" => OpenAI,
    "custom_anthropic" => Anthropic,
    "azure_openai" => Azure,
    "cerebras" => OpenAI,
    "zai_coding" => OpenAI,
    "zai_api" => OpenAI,
    "openrouter" => OpenAI,
    "gemini" => Google,
    "gemini_oauth" => Google,
    "custom_gemini" => Google,
    "claude_code" => Anthropic,
    "chatgpt_oauth" => ChatGPTCodex,
    "groq" => Groq,
    "together" => Together
  }

  # ============================================================================
  # Supervision
  # ============================================================================

  @doc """
  Starts the registry agent. Called by the supervision tree or test helper.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)
    Agent.start_link(fn -> @built_ins end, name: name)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Returns the sorted list of built-in provider type strings.

  Deterministic and stable across calls. Includes only the types that
  ship with CodePuppy; runtime-registered types are not included.

  ## Examples

      iex> "openai" in ProviderRegistry.built_in_types()
      true

      iex> "anthropic" in ProviderRegistry.built_in_types()
      true
  """
  @spec built_in_types() :: [String.t()]
  def built_in_types do
    @built_ins |> Map.keys() |> Enum.sort()
  end

  @doc """
  Returns the full current provider type → module map.

  Includes both built-in and any runtime-registered mappings.

  ## Examples

      iex> map = ProviderRegistry.all()
      iex> map["openai"]
      CodePuppyControl.LLM.Providers.OpenAI
  """
  @spec all() :: %{String.t() => module()}
  def all do
    Agent.get(@registry_name, & &1)
  end

  @doc """
  Looks up a provider type string, returning `{:ok, module}` or `:error`.

  ## Examples

      iex> ProviderRegistry.lookup("openai")
      {:ok, CodePuppyControl.LLM.Providers.OpenAI}

      iex> ProviderRegistry.lookup("nope")
      :error
  """
  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(provider_type) when is_binary(provider_type) do
    Agent.get(@registry_name, fn state ->
      case Map.fetch(state, provider_type) do
        {:ok, module} -> {:ok, module}
        :error -> :error
      end
    end)
  end

  @doc """
  Returns `true` if the provider type is registered, `false` otherwise.

  ## Examples

      iex> ProviderRegistry.supported?("anthropic")
      true

      iex> ProviderRegistry.supported?("fantasy_provider")
      false
  """
  @spec supported?(String.t() | term()) :: boolean()
  def supported?(provider_type) when is_binary(provider_type) do
    match?({:ok, _}, lookup(provider_type))
  end

  @doc false
  def supported?(_), do: false

  @doc """
  Registers a provider type → module mapping at runtime.

  Validates that `provider_type` is a non-empty binary and
  `provider_module` is an atom (module). Returns `:ok` on success
  or `{:error, reason}` on invalid input.

  Can also override an existing built-in mapping.

  ## Examples

      iex> ProviderRegistry.register("my_provider", MyApp.MyProvider)
      :ok

      iex> ProviderRegistry.register("", SomeModule)
      {:error, :empty_type}

      iex> ProviderRegistry.register("valid", "not_a_module")
      {:error, :invalid_module}
  """
  @spec register(String.t(), module()) :: :ok | {:error, atom()}
  def register(provider_type, provider_module)
      when is_binary(provider_type) and is_atom(provider_module) do
    cond do
      provider_type == "" ->
        {:error, :empty_type}

      provider_module == nil ->
        {:error, :invalid_module}

      true ->
        Agent.update(@registry_name, &Map.put(&1, provider_type, provider_module))
        :ok
    end
  end

  def register(provider_type, _provider_module) when is_binary(provider_type) do
    {:error, :invalid_module}
  end

  def register(_provider_type, _provider_module) do
    {:error, :invalid_type}
  end

  @doc """
  Resets the registry to built-in providers only.

  **Test support only.** Removes all runtime-registered providers
  and restores the original built-in mapping. Idempotent.

  ## Examples

      iex> ProviderRegistry.reset_for_test()
      :ok
  """
  @spec reset_for_test() :: :ok
  def reset_for_test do
    Agent.update(@registry_name, fn _ -> @built_ins end)
    :ok
  end
end
