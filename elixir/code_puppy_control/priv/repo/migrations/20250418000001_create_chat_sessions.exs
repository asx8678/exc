defmodule CodePuppyControl.Repo.Migrations.CreateChatSessions do
  @moduledoc """
  Creates the chat_sessions table for persisting agent session history.

  This migration implements : Migrate session_storage.py to Elixir/Ecto.
  Replaces JSON file-based session storage with SQLite via Ecto.
  """

  use Ecto.Migration

  def change do
    execute("""
    CREATE TABLE IF NOT EXISTS chat_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      history TEXT NOT NULL DEFAULT '[]',
      compacted_hashes TEXT DEFAULT '[]',
      total_tokens INTEGER DEFAULT 0,
      message_count INTEGER DEFAULT 0,
      auto_saved INTEGER DEFAULT 0,
      timestamp TEXT,
      inserted_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    )
    """)

    execute("CREATE UNIQUE INDEX IF NOT EXISTS chat_sessions_name_index ON chat_sessions(name)")
    execute("CREATE INDEX IF NOT EXISTS chat_sessions_timestamp_index ON chat_sessions(timestamp)")
    execute("CREATE INDEX IF NOT EXISTS chat_sessions_auto_saved_index ON chat_sessions(auto_saved)")
  end
end
