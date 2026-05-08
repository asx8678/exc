defmodule CodePuppyControl.Config.Migrator do
  @moduledoc """
  Version-aware schema migrations for `puppy.cfg`.

  Tracks the current schema version in a `schema_version` key within the
  `[puppy]` section. On startup (or explicit call), applies any pending
  migrations sequentially.

  ## Adding a migration

  1. Add a new clause to `apply_migration/2` for the *next* version number.
  2. The migration receives the config map and returns an updated map.
  3. Increment `@latest_schema_version`.

  ## Example

      # Migration from v1 → v2: rename a key
      defp apply_migration(1, config) do
        config
        |> rename_key("puppy", "old_key", "new_key")
        |> bump_version(2)
      end
  """

  require Logger

  alias CodePuppyControl.Config.{Loader, Writer}

  @latest_schema_version 1

  @doc """
  Return the latest known schema version.
  """
  @spec latest_version() :: non_neg_integer()
  def latest_version, do: @latest_schema_version

  @doc """
  Return the schema version currently stored in the config file.
  """
  @spec current_version() :: non_neg_integer()
  def current_version do
    case Loader.get_value("schema_version") do
      nil ->
        0

      val ->
        case Integer.parse(val) do
          {n, _} when n >= 0 -> n
          _ -> 0
        end
    end
  end

  @doc """
  Apply all pending migrations. Returns `{:ok, final_version}` or
  `{:error, reason}`.

  Migrations are applied sequentially: `current_version + 1` through
  `@latest_schema_version`. If already up-to-date, returns immediately.
  """
  @spec migrate() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def migrate do
    current = current_version()
    target = @latest_schema_version

    if current >= target do
      {:ok, current}
    else
      do_migrate(current, target)
    end
  end

  # ── Migration Engine ────────────────────────────────────────────────────

  defp do_migrate(from, to) when from >= to, do: {:ok, to}

  defp do_migrate(from, to) do
    next = from + 1
    Logger.info("Migrating puppy.cfg schema: v#{from} → v#{next}")

    config = Loader.get_cached()

    case apply_migration(next, config) do
      {:ok, updated_config} ->
        Writer.write_config(updated_config)
        Loader.invalidate()
        do_migrate(next, to)

      {:error, reason} ->
        Logger.error("Migration v#{next} failed: #{reason}")
        {:error, "Migration v#{next} failed: #{reason}"}
    end
  end

  # ── Migration Definitions ───────────────────────────────────────────────

  # v0 → v1: Ensure schema_version key exists
  # This is a no-op migration that stamps the initial version.
  defp apply_migration(1, config) do
    section = Loader.default_section()
    section_map = Map.get(config, section, %{})
    updated = Map.put(config, section, Map.put(section_map, "schema_version", "1"))
    {:ok, updated}
  end

  # Catch-all for unknown migrations
  defp apply_migration(version, _config) do
    {:error, "Unknown migration version #{version}"}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  @doc """
  Rename a key within a section. If the old key doesn't exist, does nothing.
  If the new key already exists, preserves the new key's value.
  """
  @spec rename_key(Loader.config(), String.t(), String.t(), String.t()) :: Loader.config()
  def rename_key(config, section, old_key, new_key) do
    section_map = Map.get(config, section, %{})

    case Map.pop(section_map, old_key) do
      {nil, _} ->
        config

      {value, remaining} ->
        remaining =
          if Map.has_key?(remaining, new_key) do
            remaining
          else
            Map.put(remaining, new_key, value)
          end

        Map.put(config, section, remaining)
    end
  end

  @doc """
  Set a default value for a key if it doesn't already exist.
  """
  @spec ensure_key(Loader.config(), String.t(), String.t(), String.t()) :: Loader.config()
  def ensure_key(config, section, key, default_value) do
    section_map = Map.get(config, section, %{})

    if Map.has_key?(section_map, key) do
      config
    else
      Map.put(config, section, Map.put(section_map, key, default_value))
    end
  end
end
