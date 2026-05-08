defmodule CodePuppyControl.Repo.Migrations.CreateObanMeta do
  @moduledoc """
  Creates the Oban meta table for job tracking in SQLite.

  Used by Oban.Engines.Lite for coordination and state management.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS oban_meta (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT DEFAULT '{}' NOT NULL,
      inserted_at TEXT DEFAULT (datetime('now')) NOT NULL,
      updated_at TEXT DEFAULT (datetime('now')) NOT NULL
    )
    """)

    # Insert initial values for Oban
    execute("INSERT OR IGNORE INTO oban_meta (key, value) VALUES ('singleton', '{\"lock_version\": 0}')")
  end

  def down do
    execute("DROP TABLE IF EXISTS oban_meta")
  end
end
