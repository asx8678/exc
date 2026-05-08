defmodule CodePuppyControl.Config.Models do
  @moduledoc """
  Model configuration accessors.

  Manages the globally selected model, per-model settings (temperature,
  top_p, seed), agent-to-model pinning, and OpenAI-specific reasoning
  parameters.

  ## Config keys in `puppy.cfg`

  - `model` — global model name
  - `temperature` — global temperature override (0.0–2.0)
  - `model_settings_<sanitized>_<setting>` — per-model setting
  - `agent_model_<agent_name>` — agent-to-model pinning
  - `openai_reasoning_effort` — minimal/low/medium/high/xhigh
  - `openai_reasoning_summary` — auto/concise/detailed
  - `openai_verbosity` — low/medium/high
  """

  alias CodePuppyControl.Config.Loader
  alias CodePuppyControl.Config.Paths

  # ── Global model ────────────────────────────────────────────────────────

  @doc """
  Return the currently configured global model name.

  Resolution: `puppy.cfg [puppy] model` → first model in `ModelRegistry`
  → `"gpt-5"` fallback.
  """
  @spec global_model_name() :: String.t()
  def global_model_name do
    Loader.get_value("model") || default_model()
  end

  @doc """
  Return the default model (first available from ModelRegistry, or fallback `"gpt-5"`).

  Resolution: first model in `ModelRegistry.list_model_names()` → `"gpt-5"`.
  Safe when ModelRegistry/ETS is not yet started (bootstrap, tests).
  """
  @spec default_model() :: String.t()
  def default_model do
    case first_registry_model() do
      nil -> "gpt-5"
      name -> name
    end
  end

  @doc """
  Try to fetch the first model name from ModelRegistry.

  Returns `nil` when the registry or ETS table is unavailable
  (e.g. during early bootstrap, in isolated test contexts, or when
  the GenServer hasn't been started yet).
  """
  @spec first_registry_model() :: String.t() | nil
  def first_registry_model do
    CodePuppyControl.ModelRegistry.list_model_names()
    |> List.first()
  rescue
    ArgumentError -> nil
  catch
    :exit, {:noproc, _} -> nil
    :exit, {:shutdown, _} -> nil
    :exit, {:timeout, _} -> nil
  end

  @doc """
  Set the global model name. Persists to `puppy.cfg`.
  """
  @spec set_global_model(String.t()) :: :ok
  def set_global_model(model) when is_binary(model) do
    CodePuppyControl.Config.Writer.set_value("model", model)
  end

  # ── Temperature ─────────────────────────────────────────────────────────

  @doc """
  Return the global temperature (0.0–2.0) or `nil` if not configured.
  """
  @spec temperature() :: float() | nil
  def temperature do
    case Loader.get_value("temperature") do
      nil ->
        nil

      "" ->
        nil

      val ->
        case Float.parse(val) do
          {f, _} -> max(0.0, min(2.0, f))
          :error -> nil
        end
    end
  end

  @doc """
  Set the global temperature. Pass `nil` to clear.
  """
  @spec set_temperature(float() | nil) :: :ok
  def set_temperature(nil), do: CodePuppyControl.Config.Writer.delete_value("temperature")

  def set_temperature(value) when is_float(value) or is_integer(value) do
    clamped = max(0.0, min(2.0, value * 1.0))
    CodePuppyControl.Config.Writer.set_value("temperature", Float.to_string(clamped))
  end

  # ── Per-model settings ──────────────────────────────────────────────────

  @doc """
  Get a specific setting for a model. Returns `nil` if not set.
  """
  @spec get_model_setting(String.t(), String.t()) :: number() | String.t() | nil
  def get_model_setting(model_name, setting) do
    key = model_setting_key(model_name, setting)

    case Loader.get_value(key) do
      nil -> nil
      "" -> nil
      val -> parse_setting_value(val)
    end
  end

  @doc """
  Set a specific setting for a model. Pass `nil` to clear.
  """
  @spec set_model_setting(String.t(), String.t(), number() | nil) :: :ok
  def set_model_setting(model_name, setting, nil) do
    key = model_setting_key(model_name, setting)
    CodePuppyControl.Config.Writer.set_value(key, "")
  end

  def set_model_setting(model_name, setting, value) do
    key = model_setting_key(model_name, setting)
    str = if is_float(value), do: Float.to_string(round2(value)), else: to_string(value)
    CodePuppyControl.Config.Writer.set_value(key, str)
  end

  @doc """
  Get all settings for a model as a map.
  """
  @spec get_all_model_settings(String.t()) :: map()
  def get_all_model_settings(model_name) do
    prefix = "model_settings_#{sanitize_name(model_name)}_"

    Loader.get_cached()
    |> Map.get(Loader.default_section(), %{})
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, prefix) end)
    |> Map.new(fn {k, v} ->
      setting = String.slice(k, String.length(prefix)..-1//1)
      {setting, parse_setting_value(v)}
    end)
  end

  # ── Agent-model pinning ─────────────────────────────────────────────────

  @doc """
  Get the pinned model for an agent, or `nil`.
  """
  @spec agent_pinned_model(String.t()) :: String.t() | nil
  def agent_pinned_model(agent_name) do
    Loader.get_value("agent_model_#{agent_name}")
  end

  @doc """
  Pin a model to an agent.
  """
  @spec set_agent_pinned_model(String.t(), String.t()) :: :ok
  def set_agent_pinned_model(agent_name, model_name) do
    CodePuppyControl.Config.Writer.set_value("agent_model_#{agent_name}", model_name)
  end

  @doc """
  Clear the pinned model for an agent.
  """
  @spec clear_agent_pinned_model(String.t()) :: :ok
  def clear_agent_pinned_model(agent_name) do
    CodePuppyControl.Config.Writer.delete_value("agent_model_#{agent_name}")
  end

  @doc """
  Return all agent-to-model pinnings as a map.
  """
  @spec all_agent_pinned_models() :: %{String.t() => String.t()}
  def all_agent_pinned_models do
    prefix = "agent_model_"

    Loader.get_cached()
    |> Map.get(Loader.default_section(), %{})
    |> Enum.filter(fn {k, v} -> String.starts_with?(k, prefix) and v != "" end)
    |> Map.new(fn {k, v} -> {String.slice(k, String.length(prefix)..-1//1), v} end)
  end

  # ── OpenAI settings ─────────────────────────────────────────────────────

  @allowed_reasoning_effort ~w(minimal low medium high xhigh)
  @allowed_reasoning_summary ~w(auto concise detailed)
  @allowed_verbosity ~w(low medium high)

  @doc "Return OpenAI reasoning effort (default `\"medium\"`)."
  @spec openai_reasoning_effort() :: String.t()
  def openai_reasoning_effort do
    val = (Loader.get_value("openai_reasoning_effort") || "medium") |> String.downcase()
    if val in @allowed_reasoning_effort, do: val, else: "medium"
  end

  @doc "Set OpenAI reasoning effort."
  @spec set_openai_reasoning_effort(String.t()) :: :ok | {:error, String.t()}
  def set_openai_reasoning_effort(value) do
    normalized = String.downcase(value || "")

    if normalized in @allowed_reasoning_effort do
      CodePuppyControl.Config.Writer.set_value("openai_reasoning_effort", normalized)
    else
      {:error,
       "Invalid reasoning effort '#{value}'. Allowed: #{Enum.join(@allowed_reasoning_effort, ", ")}"}
    end
  end

  @doc "Return OpenAI reasoning summary mode (default `\"auto\"`)."
  @spec openai_reasoning_summary() :: String.t()
  def openai_reasoning_summary do
    val = (Loader.get_value("openai_reasoning_summary") || "auto") |> String.downcase()
    if val in @allowed_reasoning_summary, do: val, else: "auto"
  end

  @doc "Set OpenAI reasoning summary mode."
  @spec set_openai_reasoning_summary(String.t()) :: :ok | {:error, String.t()}
  def set_openai_reasoning_summary(value) do
    normalized = String.downcase(value || "")

    if normalized in @allowed_reasoning_summary do
      CodePuppyControl.Config.Writer.set_value("openai_reasoning_summary", normalized)
    else
      {:error,
       "Invalid reasoning summary '#{value}'. Allowed: #{Enum.join(@allowed_reasoning_summary, ", ")}"}
    end
  end

  @doc "Return OpenAI verbosity (default `\"medium\"`)."
  @spec openai_verbosity() :: String.t()
  def openai_verbosity do
    val = (Loader.get_value("openai_verbosity") || "medium") |> String.downcase()
    if val in @allowed_verbosity, do: val, else: "medium"
  end

  @doc "Set OpenAI verbosity."
  @spec set_openai_verbosity(String.t()) :: :ok | {:error, String.t()}
  def set_openai_verbosity(value) do
    normalized = String.downcase(value || "")

    if normalized in @allowed_verbosity do
      CodePuppyControl.Config.Writer.set_value("openai_verbosity", normalized)
    else
      {:error, "Invalid verbosity '#{value}'. Allowed: #{Enum.join(@allowed_verbosity, ", ")}"}
    end
  end

  # ── Context Length ──────────────────────────────────────────────────

  @default_context_length 128_000

  @known_context_lengths %{
    "claude-3" => 200_000,
    "claude-3-5" => 200_000,
    "claude-4" => 200_000,
    "gpt-4-turbo" => 128_000,
    "gpt-4o" => 128_000,
    "gpt-5" => 128_000,
    "gemini-1.5" => 1_000_000,
    "gemini-2" => 1_000_000
  }

  @doc """
  Get context length for a specific model.

  Priority:
  1. models.json override in config dir
  2. Known model prefix defaults
  3. @default_context_length (128_000)
  """
  @spec context_length(String.t()) :: pos_integer()
  def context_length(model_name) when is_binary(model_name) do
    case get_from_models_json(model_name) do
      {:ok, length} -> length
      :not_found -> lookup_known_default(model_name)
    end
  end

  def context_length(_), do: @default_context_length

  defp get_from_models_json(model_name) do
    models = load_models_json()

    case models[model_name] do
      %{"context_length" => len} when is_integer(len) -> {:ok, len}
      _ -> :not_found
    end
  end

  defp load_models_json do
    key = {__MODULE__, :models_json}

    case :persistent_term.get(key, :not_loaded) do
      :not_loaded ->
        result = do_load_models_json()
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp do_load_models_json do
    path = Paths.models_file()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp lookup_known_default(model_name) do
    Enum.find_value(@known_context_lengths, @default_context_length, fn {prefix, length} ->
      if String.starts_with?(model_name, prefix), do: length
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp model_setting_key(model_name, setting) do
    "model_settings_#{sanitize_name(model_name)}_#{setting}"
  end

  defp sanitize_name(name) do
    name
    |> String.replace(~r{[.\-/]}, "_")
    |> String.downcase()
  end

  defp parse_setting_value(val) do
    cond do
      String.downcase(val) in ["true", "false"] ->
        String.downcase(val) == "true"

      true ->
        case Integer.parse(val) do
          {int, ""} ->
            int

          _ ->
            case Float.parse(val) do
              {f, ""} -> f
              _ -> val
            end
        end
    end
  end

  defp round2(float), do: round(float * 100) / 100
end
