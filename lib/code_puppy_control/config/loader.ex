defmodule CodePuppyControl.Config.Loader do
  @moduledoc """
  INI parser for `puppy.cfg` with environment-variable overrides.

  Reads the config file at startup (or on explicit reload) and caches the
  parsed result in `:persistent_term` for lock-free, O(1) reads from any
  process. Writes go through `CodePuppyControl.Config.Writer` and call
  `reload/0` afterwards to refresh the cache.

  ## INI format

  Supports `section` headers (`[name]`), `key = value` pairs, comment lines
  starting with `;` or `#`, and continuation lines (indented). Values are
  stored as strings; type coercion happens in the domain modules.

  ## Environment overrides

  After parsing the file, `merge_env_overrides/1` applies any `PUP_*`
  environment variables that map to known config keys. Legacy `PUPPY_*`
  vars are supported with deprecation warnings.

  ## Cache

  The parsed config map is stored under `{:code_puppy_control, :puppy_cfg}` in
  `:persistent_term`. Reads use `:persistent_term.get/1` which is a single
  ETS read — no locks, no copies for the atom key.
  """

  require Logger

  @persistent_term_key {:code_puppy_control, :puppy_cfg}
  @config_path_key {:code_puppy_control, :puppy_cfg_path}
  @default_section "puppy"

  @type config :: %{String.t() => %{String.t() => String.t()}}

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Load config from `path`, merge env overrides, and cache in persistent_term.
  Returns the parsed config map.

  If the file doesn't exist, returns an empty config with just the default
  section.
  """
  @spec load(String.t()) :: config()
  def load(path) do
    config =
      path
      |> parse_file()
      |> merge_env_overrides()

    :persistent_term.put(@persistent_term_key, config)
    :persistent_term.put(@config_path_key, path)
    config
  end

  @doc """
  Return the cached config map. If nothing has been loaded yet, loads from
  the default config path.
  """
  @spec get_cached() :: config()
  def get_cached do
    case :persistent_term.get(@persistent_term_key, :not_loaded) do
      :not_loaded ->
        # Reload from the last explicitly loaded path if known,
        # so that a cache-miss after Writer.invalidate/0 doesn't
        # silently switch back to the default config file.
        load(loaded_path())

      config ->
        config
    end
  end

  @doc """
  Return the value for `key` in the default section, or `nil`.
  """
  @spec get_value(String.t()) :: String.t() | nil
  def get_value(key) do
    get_value(@default_section, key)
  end

  @doc """
  Return the value for `key` in the given `section`, or `nil`.
  """
  @spec get_value(String.t(), String.t()) :: String.t() | nil
  def get_value(section, key) do
    get_cached()
    |> Map.get(section, %{})
    |> Map.get(key)
  end

  @doc """
  Return all keys in the default section as a sorted list.
  """
  @spec keys() :: [String.t()]
  def keys do
    get_cached()
    |> Map.get(@default_section, %{})
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Return the default section name (`"puppy"`).
  """
  @spec default_section() :: String.t()
  def default_section, do: @default_section

  @doc """
  Parse an INI file from disk. Returns a config map.

  If the file does not exist, returns `%{@default_section => %{}}`.
  """
  @spec parse_file(String.t()) :: config()
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_string(content)

      {:error, _reason} ->
        %{@default_section => %{}}
    end
  end

  @doc """
  Parse an INI-format string into a config map.
  """
  @spec parse_string(String.t()) :: config()
  def parse_string(content) do
    content
    |> String.split("\n")
    |> do_parse(@default_section, %{@default_section => %{}})
  end

  # ── INI Parser (recursive, no regex) ────────────────────────────────────

  defp do_parse([], _section, acc), do: acc

  defp do_parse([line | rest], section, acc) do
    trimmed = String.trim(line)

    cond do
      comment_line?(trimmed) ->
        do_parse(rest, section, acc)

      section_header?(trimmed) ->
        new_section = extract_section_name(trimmed)
        acc = Map.put_new(acc, new_section, %{})
        do_parse(rest, new_section, acc)

      kv_pair?(trimmed) ->
        {key, value} = extract_kv(trimmed)
        section_map = Map.get(acc, section, %{})
        acc = Map.put(acc, section, Map.put(section_map, key, value))
        do_parse(rest, section, acc)

      continuation_line?(trimmed, acc, section) ->
        # Append to last key's value
        acc = append_continuation(acc, section, trimmed)
        do_parse(rest, section, acc)

      true ->
        # Blank or unrecognized line
        do_parse(rest, section, acc)
    end
  end

  defp comment_line?(line) do
    first = String.first(line)
    first == ";" or first == "#"
  end

  defp section_header?(line) do
    String.starts_with?(line, "[") and String.ends_with?(line, "]")
  end

  defp extract_section_name(line) do
    line
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.trim()
  end

  defp kv_pair?(line) do
    String.contains?(line, "=")
  end

  defp extract_kv(line) do
    [key | value_parts] = String.split(line, "=", parts: 2)
    key = String.trim(key)
    value = value_parts |> Enum.join("=") |> String.trim()
    {key, value}
  end

  defp continuation_line?(trimmed, _acc, _section) do
    String.starts_with?(trimmed, " ") or String.starts_with?(trimmed, "\t")
  end

  defp append_continuation(acc, section, trimmed) do
    section_map = Map.get(acc, section, %{})

    case Map.to_list(section_map) do
      [] ->
        acc

      list ->
        {last_key, last_value} = List.last(list)
        updated_value = last_value <> "\n" <> trimmed
        Map.put(acc, section, Map.put(section_map, last_key, updated_value))
    end
  end

  # ── Environment Overrides ───────────────────────────────────────────────

  @doc """
  Apply environment variable overrides to the config.

  Recognized env vars:
  - `PUP_HOME` / `PUPPY_HOME` (legacy) — overrides home directory
  - `PUP_MODEL` — overrides `model` key
  - `PUP_AGENT` / `PUPPY_DEFAULT_AGENT` (legacy) — overrides `default_agent`
  - `PUP_DEBUG` — overrides `debug` key

  All new env vars use the `PUP_` prefix per project conventions.
  """
  @spec merge_env_overrides(config()) :: config()
  def merge_env_overrides(config) do
    config
    |> apply_env_override("PUP_MODEL", "puppy", "model")
    |> apply_env_override("PUPPY_DEFAULT_MODEL", "puppy", "model")
    |> apply_env_override("PUP_AGENT", "puppy", "default_agent")
    |> apply_env_override("PUPPY_DEFAULT_AGENT", "puppy", "default_agent")
    |> apply_env_override("PUP_DEBUG", "puppy", "debug")
    |> apply_env_override("PUPPY_TEMPERATURE", "puppy", "temperature")
    |> apply_env_override("PUPPY_MESSAGE_LIMIT", "puppy", "message_limit")
    |> apply_env_override("PUPPY_PROTECTED_TOKEN_COUNT", "puppy", "protected_token_count")
  end

  defp apply_env_override(config, env_var, section, key) do
    case System.get_env(env_var) do
      nil ->
        config

      "" ->
        config

      value ->
        maybe_warn_legacy(env_var)
        section_map = Map.get(config, section, %{})
        Map.put(config, section, Map.put(section_map, key, value))
    end
  end

  defp maybe_warn_legacy("PUPPY_" <> _rest = var) do
    Logger.warning(
      "Environment variable #{var} uses legacy PUPPY_ prefix. " <>
        "Please migrate to PUP_ prefix."
    )
  end

  defp maybe_warn_legacy(_var), do: :ok

  @doc """
  Return the path of the last-loaded config file.
  Falls back to `Paths.config_file()` if no explicit load has occurred.
  """
  @spec loaded_path() :: String.t()
  def loaded_path do
    case :persistent_term.get(@config_path_key, :not_set) do
      :not_set -> CodePuppyControl.Config.Paths.config_file()
      path -> path
    end
  end

  @doc """
  Invalidate the cached config, forcing next read to reload from disk.
  """
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@persistent_term_key)
    # Keep config_path_key so Writer knows where to write
    :ok
  end
end
