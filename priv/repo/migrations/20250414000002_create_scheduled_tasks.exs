defmodule CodePuppyControl.Repo.Migrations.CreateScheduledTasks do
  @moduledoc """
  Creates the scheduled_tasks table for the Oban scheduler.

  This table stores user-defined scheduled tasks that the scheduler
  daemon manages and executes via Oban jobs.
  """

  use Ecto.Migration

  def change do
    execute("""
    CREATE TABLE IF NOT EXISTS scheduled_tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      description TEXT,
      agent_name TEXT NOT NULL,
      model TEXT,
      prompt TEXT NOT NULL,
      config TEXT DEFAULT '{}',
      schedule TEXT,
      schedule_type TEXT DEFAULT 'interval',
      schedule_value TEXT DEFAULT '1h',
      enabled INTEGER DEFAULT 1,
      last_run_at TEXT,
      last_status TEXT,
      last_exit_code INTEGER,
      last_error TEXT,
      run_count INTEGER DEFAULT 0,
      working_directory TEXT DEFAULT '.',
      log_file TEXT,
      inserted_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    )
    """)

    execute("CREATE UNIQUE INDEX IF NOT EXISTS scheduled_tasks_name_index ON scheduled_tasks(name)")
    execute("CREATE INDEX IF NOT EXISTS scheduled_tasks_enabled_index ON scheduled_tasks(enabled)")
    execute("CREATE INDEX IF NOT EXISTS scheduled_tasks_schedule_index ON scheduled_tasks(schedule)")
    execute("CREATE INDEX IF NOT EXISTS scheduled_tasks_agent_name_index ON scheduled_tasks(agent_name)")
  end
end
