defmodule CodePuppyControl.Auth.ClaudeOAuth.Models do
  @moduledoc """
  Model registry, filtering, and entry construction for Claude Code OAuth models.

  Extracted from `CodePuppyControl.Auth.ClaudeOAuth` to keep the parent module
  under the 600-line hard cap. The public API is preserved via delegation —
  callers still use `ClaudeOAuth.filter_latest_models/2`,
  `ClaudeOAuth.load_models/0`, `ClaudeOAuth.load_latest_models/0`, etc.

  ## Responsibilities

  - Model name parsing and version sorting
  - Latest-per-family filtering
  - Model registry CRUD (load, save, add, remove)
  - Blocked model filtering
  - Model entry construction and token updates
  """

  require Logger

  alias CodePuppyControl.Auth.ClaudeOAuth
  alias CodePuppyControl.Config.{Isolation, Paths}

  # ── Blocked Models ──────────────────────────────────────────────────

  @blocked_models MapSet.new([])

  # ── Model name regex patterns ───────────────────────────────────────

  @model_modern_re ~r/^claude-(haiku|sonnet|opus)-(\d+)(?:-(\d+))?(?:-(\d+))?$/
  @model_dot_re ~r/^claude-(haiku|sonnet|opus)-(\d+)\.(\d+)(?:-(\d+))?$/
  @model_legacy_re ~r/^claude-(\d+)-(haiku|sonnet|opus)(?:-(\d+))?$/

  # ── Types ───────────────────────────────────────────────────────────

  @type max_per_family :: pos_integer() | %{String.t() => pos_integer()}

  # ── Public API: Model Filtering ────────────────────────────────────

  @doc """
  Filter model names to keep only the latest per family (haiku, sonnet, opus).

  `max_per_family` can be an integer (applies to all) or a map with
  family keys (missing keys fall back to `"default"`, then `2`).
  """
  @spec filter_latest_models([String.t()], max_per_family()) :: [String.t()]
  def filter_latest_models(models, max_per_family \\ 2)
  def filter_latest_models([], _), do: []

  def filter_latest_models(models, max_per_family) when is_list(models) do
    models
    |> Enum.reduce(%{}, fn name, acc ->
      case parse_model_name(name) do
        nil ->
          acc

        {family, major, minor, date} ->
          Map.update(acc, family, [{name, major, minor, date}], fn existing ->
            [{name, major, minor, date} | existing]
          end)
      end
    end)
    |> Enum.flat_map(fn {family, entries} ->
      limit = resolve_limit(family, max_per_family)

      entries
      |> Enum.sort_by(fn {_, major, minor, date} -> {major, minor, date} end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {name, _, _, _} -> name end)
    end)
  end

  # ── Public API: Model Registry ─────────────────────────────────────

  @doc "Load Claude models from the overlay JSON file, filtering blocked ones."
  @spec load_models() :: {:ok, map()}
  def load_models do
    path = Paths.claude_models_file()

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, models} when is_map(models) ->
            {:ok, filter_blocked_models(models)}

          {:error, reason} ->
            Logger.error("Failed to parse Claude models: #{inspect(reason)}")
            {:ok, %{}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.error("Failed to load Claude models: #{inspect(reason)}")
        {:ok, %{}}
    end
  end

  @doc "Save Claude models to the overlay JSON file (0o600 permissions)."
  @spec save_models(map()) :: :ok
  def save_models(models) when is_map(models) do
    path = Paths.claude_models_file()
    json = Jason.encode!(models, pretty: true)
    Isolation.safe_write!(path, json)
    File.chmod(path, 0o600)
    :ok
  end

  @doc """
  Add model names to the registry, overwriting existing entries.

  Creates `-long` variants for models in `long_context_models/0`.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  @spec add_models([String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def add_models(model_names) when is_list(model_names) do
    prefix = ClaudeOAuth.config(:prefix)
    default_ctx = ClaudeOAuth.config(:default_context_length)
    long_ctx = ClaudeOAuth.config(:long_context_length)
    long_ctx_models = ClaudeOAuth.config(:long_context_models)

    filtered = Enum.reject(model_names, &blocked_model?/1)
    access_token = current_access_token()

    {models, added} =
      Enum.reduce(filtered, {%{}, 0}, fn name, {acc, count} ->
        prefixed = "#{prefix}#{name}"
        entry = build_model_entry(name, default_ctx, access_token)
        new_acc = Map.put(acc, prefixed, entry)

        if name in long_ctx_models do
          long_prefixed = "#{prefix}#{name}-long"
          long_entry = build_model_entry(name, long_ctx, access_token)
          {Map.put(new_acc, long_prefixed, long_entry), count + 2}
        else
          {new_acc, count + 1}
        end
      end)

    try do
      save_models(models)
      Logger.info("Added #{added} Claude Code models")
      {:ok, added}
    rescue
      e ->
        Logger.error("Error adding models: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Load Claude models, filtered to only the latest per family.

  Returns only the most recent haiku, sonnet, and opus models
  (default: 1 per family, opus up to 6). Useful for status display
  where showing every dated snapshot is noise.

  Renamed from `load_models_filtered` to clarify that filtering
  is specifically by latest-per-family, not a generic filter.
  """
  @spec load_latest_models() :: {:ok, map()}
  def load_latest_models do
    {:ok, all_models} = load_models()

    if map_size(all_models) == 0 do
      {:ok, %{}}
    else
      # Extract model names from OAuth-sourced entries
      model_names =
        all_models
        |> Enum.filter(fn {_, cfg} -> cfg["oauth_source"] == "claude-code-plugin" end)
        |> Enum.map(fn {_, cfg} -> cfg["name"] || "" end)
        |> Enum.filter(&(&1 != ""))

      latest_names =
        filter_latest_models(model_names, %{"default" => 1, "opus" => 6})
        |> MapSet.new()

      filtered =
        all_models
        |> Enum.filter(fn {_, cfg} ->
          name = cfg["name"] || ""
          MapSet.member?(latest_names, name)
        end)
        |> Map.new()

      Logger.info(
        "Loaded #{map_size(all_models)} models, filtered to #{map_size(filtered)} latest models"
      )

      {:ok, filtered}
    end
  end

  @doc "Remove all Claude Code OAuth models. Returns `{:ok, count}` or `{:error, reason}`."
  @spec remove_models() :: {:ok, non_neg_integer()} | {:error, term()}
  def remove_models do
    case load_models() do
      {:ok, all_models} ->
        to_remove =
          all_models
          |> Enum.filter(fn {_, cfg} -> cfg["oauth_source"] == "claude-code-plugin" end)
          |> Enum.map(fn {name, _} -> name end)

        if to_remove == [] do
          {:ok, 0}
        else
          try do
            save_models(Map.drop(all_models, to_remove))
            Logger.info("Removed #{length(to_remove)} Claude Code models")
            {:ok, length(to_remove)}
          rescue
            e ->
              Logger.error("Error removing models: #{inspect(e)}")
              {:error, e}
          end
        end
    end
  end

  @doc """
  Update the access token in all saved Claude Code model entries.

  This preserves the Python plugin semantic where the live OAuth access token
  is stored in `custom_endpoint.api_key` for `oauth_source == "claude-code-plugin"`.
  """
  @spec update_model_tokens(String.t()) :: :ok | {:error, term()}
  def update_model_tokens(access_token) when is_binary(access_token) do
    {:ok, models} = load_models()

    updated =
      models
      |> Enum.map(fn {name, config} ->
        if config["oauth_source"] == "claude-code-plugin" do
          custom_endpoint = Map.get(config, "custom_endpoint", %{})
          updated_endpoint = Map.put(custom_endpoint, "api_key", access_token)
          {name, Map.put(config, "custom_endpoint", updated_endpoint)}
        else
          {name, config}
        end
      end)
      |> Map.new()

    try do
      save_models(updated)
      :ok
    rescue
      e -> {:error, e}
    end
  end

  # ── Private: Model Parsing ─────────────────────────────────────────

  @spec parse_model_name(String.t()) :: {String.t(), integer(), integer(), integer()} | nil
  defp parse_model_name(name) do
    cond do
      match = Regex.run(@model_modern_re, name) ->
        [_, family, major_s, g3, g4] = pad_match(match, 5)
        {major, minor, date} = parse_modern_groups(major_s, g3, g4)
        {family, major, minor, date}

      match = Regex.run(@model_dot_re, name) ->
        [_, family, major_s, minor_s, date_s] = pad_match(match, 5)
        major = String.to_integer(major_s)
        minor = String.to_integer(minor_s)
        date = if date_s == "", do: 99_999_999, else: String.to_integer(date_s)
        {family, major, minor, date}

      match = Regex.run(@model_legacy_re, name) ->
        [_, major_s, family, date_s] = pad_match(match, 4)
        major = String.to_integer(major_s)
        date = if date_s == "", do: 99_999_999, else: String.to_integer(date_s)
        {family, major, 0, date}

      true ->
        nil
    end
  end

  defp pad_match(match, desired_len) do
    match ++ List.duplicate("", desired_len - length(match))
  end

  defp parse_modern_groups(major_s, g3, g4) do
    major = String.to_integer(major_s)

    cond do
      g3 == "" -> {major, 0, 99_999_999}
      g4 != "" -> {major, String.to_integer(g3), String.to_integer(g4)}
      String.length(g3) >= 6 -> {major, 0, String.to_integer(g3)}
      true -> {major, String.to_integer(g3), 99_999_999}
    end
  end

  # ── Private: Blocked Models ────────────────────────────────────────

  defp blocked_model?(name) when is_binary(name) do
    prefix = ClaudeOAuth.config(:prefix)
    stripped = name |> String.trim_leading(prefix) |> String.trim_trailing("-long")
    MapSet.member?(@blocked_models, name) or MapSet.member?(@blocked_models, stripped)
  end

  defp blocked_model?(_), do: false

  defp filter_blocked_models(models) do
    {kept, dropped} =
      Enum.reduce(models, {%{}, []}, fn {key, val}, {kept_acc, drop_acc} ->
        if blocked_model?(key),
          do: {kept_acc, [key | drop_acc]},
          else: {Map.put(kept_acc, key, val), drop_acc}
      end)

    if dropped != [] do
      Logger.info("Filtered blocked Claude Code models: #{inspect(Enum.reverse(dropped))}")
    end

    kept
  end

  # ── Private: Model Entry Builder ──────────────────────────────────

  defp current_access_token do
    case ClaudeOAuth.load_tokens() do
      {:ok, %{"access_token" => access_token}} when is_binary(access_token) -> access_token
      _ -> ""
    end
  end

  defp build_model_entry(model_name, context_length, access_token) do
    settings =
      base_supported_settings() ++
        if String.contains?(String.downcase(model_name), "opus"), do: ["effort"], else: []

    %{
      "type" => "claude_code",
      "name" => model_name,
      "custom_endpoint" => %{
        "url" => ClaudeOAuth.api_base_url(),
        "api_key" => access_token,
        "headers" => %{
          "anthropic-beta" => "oauth-2025-04-20,interleaved-thinking-2025-05-14",
          "x-app" => "cli",
          "User-Agent" => "claude-cli/2.0.61 (external, cli)"
        }
      },
      "context_length" => context_length,
      "oauth_source" => "claude-code-plugin",
      "supported_settings" => settings
    }
  end

  defp base_supported_settings do
    ["temperature", "extended_thinking", "budget_tokens", "interleaved_thinking"]
  end

  # ── Private: Max Per Family ────────────────────────────────────────

  defp resolve_limit(_, max) when is_integer(max), do: max

  defp resolve_limit(family, max) when is_map(max) do
    Map.get(max, family, Map.get(max, "default", 2))
  end
end
