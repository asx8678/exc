defmodule CodePuppyControl.Repo.Migrations.CreateObanJobs do
  @moduledoc """
  Creates Oban jobs table for SQLite.

  Oban v2.17+ supports SQLite via the Lite engine.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS oban_jobs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      state TEXT DEFAULT 'available' NOT NULL,
      queue TEXT DEFAULT 'default' NOT NULL,
      worker TEXT NOT NULL,
      args TEXT DEFAULT '{}' NOT NULL,
      meta TEXT DEFAULT '{}' NOT NULL,
      tags TEXT DEFAULT '[]' NOT NULL,
      errors TEXT DEFAULT '[]' NOT NULL,
      attempt INTEGER DEFAULT 0 NOT NULL,
      max_attempts INTEGER DEFAULT 20 NOT NULL,
      priority INTEGER DEFAULT 0 NOT NULL,
      attempted_at TEXT,
      attempted_by TEXT,
      cancelled_at TEXT,
      completed_at TEXT,
      discarded_at TEXT,
      inserted_at TEXT DEFAULT (datetime('now')) NOT NULL,
      scheduled_at TEXT DEFAULT (datetime('now')) NOT NULL,
      updated_at TEXT
    )
    """)

    execute("CREATE INDEX IF NOT EXISTS oban_jobs_state_queue_scheduled_at_index ON oban_jobs(state, queue, scheduled_at)")
    execute("CREATE INDEX IF NOT EXISTS oban_jobs_state_queue_priority_scheduled_at_index ON oban_jobs(state, queue, priority, scheduled_at)")
  end

  def down do
    execute("DROP INDEX IF EXISTS oban_jobs_state_queue_scheduled_at_index")
    execute("DROP INDEX IF EXISTS oban_jobs_state_queue_priority_scheduled_at_index")
    execute("DROP TABLE IF EXISTS oban_jobs")
  end
end
