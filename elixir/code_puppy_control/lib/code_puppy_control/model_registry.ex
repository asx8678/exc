defmodule CodePuppyControl.ModelRegistry do
  @moduledoc """
  Model configuration registry with ETS-backed caching.

  Ports Python's ModelFactory.load_config() and model_config.py registry.
  Loads models from bundled JSON + overlay files, caches in ETS for fast lookup.

  ## Architecture

  - **ETS table** (`:model_configs`): `:set` type with read concurrency enabled
    for fast concurrent lookups. Keys are model names (strings), values are
    model config maps.
  - **GenServer**: Coordinates writes (initial load, reload) to prevent
    race conditions.
  - **Config sources**:
    - Bundled: `priv/models.json` (shipped with the application)
    - Overlays (optional, in user's home directory):
      - `~/.code_puppy/extra_models.json`
      - `~/.code_puppy/chatgpt_models.json`
      - `~/.code_puppy/claude_models.json`

  ## Model Type Registry

  Known model types:
  - `"openai"` - OpenAI GPT models
  - `"anthropic"` - Anthropic Claude models
  - `"custom_anthropic"` - Custom Anthropic-compatible endpoint
  - `"azure_openai"` - Azure OpenAI Service
  - `"custom_openai"` - Custom OpenAI-compatible endpoint
  - `"zai_coding"` - ZAI Coding models
  - `"zai_api"` - ZAI API models
  - `"cerebras"` - Cerebras models
  - `"claude_code"` - Claude Code OAuth models
  - `"chatgpt_oauth"` - ChatGPT OAuth Codex models
  - `"openrouter"` - OpenRouter multi-provider gateway
  - `"round_robin"` - Round-robin model rotation
  - `"gemini"` - Google Gemini models
  - `"gemini_oauth"` - Gemini with OAuth authentication
  - `"custom_gemini"` - Custom Gemini-compatible endpoint

  ## API

  - `start_link/1` - Start the GenServer
  - `get_config/1` - Get config for a specific model name
  - `get_all_configs/0` - Get all model configs as a map
  - `reload/0` - Force reload from JSON files
  - `get_model_type/1` - Resolve model type from config
  - `list_model_names/0` - List all available model names
  - `list_model_types/0` - List all unique model types from current configs
  - `type_supported?/1` - Check if a model type is known

  ## Examples

      iex> ModelRegistry.get_config("wafer-glm-5.1")
      %{
        "type" => "custom_openai",
        "provider" => "wafer",
        "name" => "GLM-5.1",
        "context_length" => 200000
      }

      iex> ModelRegistry.list_model_names()
      ["firepass-kimi-k2p5-turbo", "wafer-glm-5.1", ...]

      iex> ModelRegistry.type_supported?("openai")
      true

      iex> ModelRegistry.type_supported?("unknown_type")
      false
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Config.Paths

  @table :model_configs

  # Known model types from Python model_config.py
  @known_model_types [
    "openai",
    "anthropic",
    "custom_anthropic",
    "azure_openai",
    "custom_openai",
    "zai_coding",
    "zai_api",
    "cerebras",
    "claude_code",
    "chatgpt_oauth",
    "openrouter",
    "round_robin",
    "gemini",
    "gemini_oauth",
    "custom_gemini"
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the ModelRegistry GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the configuration for a specific model.

  Returns the model config map if found, or `nil` if the model doesn't exist.

  ## Examples

      iex> ModelRegistry.get_config("wafer-glm-5.1")
      %{"type" => "custom_openai", "provider" => "wafer", ...}

      iex> ModelRegistry.get_config("nonexistent-model")
      nil
  """
  @spec get_config(String.t()) :: map() | nil
  def get_config(model_name) when is_binary(model_name) do
    case :ets.lookup(@table, model_name) do
      [{^model_name, config}] -> config
      [] -> nil
    end
  end

  def get_config(_), do: nil

  @doc """
  Gets all model configurations as a map.

  Returns a map where keys are model names and values are config maps.

  ## Examples

      iex> ModelRegistry.get_all_configs()
      %{
        "wafer-glm-5.1" => %{"type" => "custom_openai", ...},
        "firepass-kimi-k2p5-turbo" => %{...}
      }
  """
  @spec get_all_configs() :: %{String.t() => map()}
  def get_all_configs do
    @table
    |> :ets.tab2list()
    |> Map.new(fn {name, config} -> {name, config} end)
  end

  @doc """
  Forces a reload of model configurations from JSON files.

  This re-reads the bundled models.json and all overlay files, then
  repopulates the ETS cache. Returns `:ok` on success.

  ## Examples

      iex> ModelRegistry.reload()
      :ok
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Resolves the model type from a configuration.

  Returns the type string from the config, or `nil` if not specified
  or if config is invalid.

  ## Examples

      iex> ModelRegistry.get_model_type(%{"type" => "openai"})
      "openai"

      iex> ModelRegistry.get_model_type(%{})
      nil
  """
  @spec get_model_type(map()) :: String.t() | nil
  def get_model_type(model_config) when is_map(model_config) do
    Map.get(model_config, "type")
  end

  def get_model_type(_), do: nil

  @doc """
  Lists all available model names.

  Returns a list of all model names currently loaded in the registry.

  ## Examples

      iex> ModelRegistry.list_model_names()
      ["firepass-kimi-k2p5-turbo", "wafer-glm-5.1", ...]
  """
  @spec list_model_names() :: [String.t()]
  def list_model_names do
    @table
    |> :ets.select([{{:"$1", :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  @doc """
  Lists all unique model types from currently loaded configurations.

  This scans the actual loaded configs, not the known types list.

  ## Examples

      iex> ModelRegistry.list_model_types()
      ["custom_openai"]
  """
  @spec list_model_types() :: [String.t()]
  def list_model_types do
    @table
    |> :ets.select([{{:_, %{"type" => :"$1"}}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Checks if a model type is known/supported.

  Returns `true` if the type is in the known types list, `false` otherwise.
  Note: This checks against the static known types list, not the
  currently loaded configs. For loaded types, use `list_model_types/0`.

  ## Examples

      iex> ModelRegistry.type_supported?("openai")
      true

      iex> ModelRegistry.type_supported?("anthropic")
      true

      iex> ModelRegistry.type_supported?("unknown")
      false
  """
  @spec type_supported?(String.t()) :: boolean()
  def type_supported?(model_type) when is_binary(model_type) do
    model_type in @known_model_types
  end

  def type_supported?(_), do: false

  @doc """
  Gets all known model types (static list).

  Returns the list of all model types that the registry knows about,
  regardless of whether any models of those types are currently loaded.

  ## Examples

      iex> ModelRegistry.known_model_types()
      ["anthropic", "azure_openai", "cerebras", "custom_anthropic", ...]
  """
  @spec known_model_types() :: [String.t()]
  def known_model_types do
    @known_model_types
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create public set table for concurrent reads
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    # Load initial model configurations
    case load_all_configs() do
      {:ok, configs} ->
        populate_ets(table, configs)
        Logger.info("ModelRegistry initialized with #{map_size(configs)} models")
        {:ok, %{table: table}}

      {:error, reason} ->
        # (code-puppy-be7) In escript mode, :code.priv_dir resolves to a
        # path inside the zip archive (not a real file). Downgrade to
        # warning so it doesn't pollute startup as an [error].
        log_level =
          case reason do
            {:file_read_error, _path, :enotdir} -> :warning
            _ -> :error
          end

        Logger.log(log_level, "ModelRegistry failed to load configs: #{inspect(reason)}")
        # Still start the GenServer, but with empty config
        {:ok, %{table: table}}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case load_all_configs() do
      {:ok, configs} ->
        # Clear existing entries and repopulate
        :ets.delete_all_objects(state.table)
        populate_ets(state.table, configs)
        Logger.info("ModelRegistry reloaded with #{map_size(configs)} models")
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("ModelRegistry reload failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("ModelRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp populate_ets(table, configs) do
    for {name, config} <- configs do
      :ets.insert(table, {name, config})
    end
  end

  defp load_all_configs do
    with {:ok, base_config} <- load_bundled_models(),
         overlay_configs <- load_overlay_files(),
         merged <- merge_configs(base_config, overlay_configs) do
      {:ok, merged}
    else
      error -> error
    end
  end

  defp load_bundled_models do
    models_path = bundled_models_path()

    case File.read(models_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} -> {:ok, config}
          {:error, reason} -> {:error, {:json_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, models_path, reason}}
    end
  end

  defp bundled_models_path do
    # Allow env-var override for testing / ops overrides.
    # Follows PUP_ prefix convention for core runtime settings.
    env_path = System.get_env("PUP_BUNDLED_MODELS_PATH")

    if env_path != nil and env_path != "" do
      env_path
    else
      case :code.priv_dir(:code_puppy_control) do
        {:error, _} ->
          # Escript mode: priv_dir is not available. Use the path anyway
          # so the error message is clear; load_bundled_models/0 will
          # handle the :enoent gracefully.
          "<escript-no-priv-dir>/priv/models.json"

        priv_dir ->
          Application.get_env(
            :code_puppy_control,
            :bundled_models_path,
            Path.join(priv_dir, "models.json")
          )
      end
    end
  end

  defp load_overlay_files do
    overlay_specs = [
      {Paths.extra_models_file(), "extra models"},
      {Paths.chatgpt_models_file(), "ChatGPT OAuth models"},
      {Paths.claude_models_file(), "Claude Code OAuth models"}
    ]

    overlay_specs
    |> Enum.reduce([], fn {path, label}, acc ->
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, config} when is_map(config) ->
              Logger.debug("ModelRegistry: loaded #{label} from #{path}")
              [config | acc]

            {:ok, _} ->
              Logger.warning("ModelRegistry: #{label} at #{path} is not a valid object")
              acc

            {:error, reason} ->
              Logger.warning(
                "ModelRegistry: failed to parse #{label} at #{path}: #{inspect(reason)}"
              )

              acc
          end

        {:error, :enoent} ->
          # File doesn't exist - this is fine, overlays are optional
          acc

        {:error, reason} ->
          Logger.warning("ModelRegistry: failed to read #{label} at #{path}: #{inspect(reason)}")
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp merge_configs(base_config, overlay_configs) do
    # Overlays merge INTO base, with later overlays winning on conflicts
    Enum.reduce(overlay_configs, base_config, fn overlay, acc ->
      Map.merge(acc, overlay)
    end)
  end
end
