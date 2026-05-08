defmodule CodePuppyControl.Repo.Migrations.CreateWorkflowSteps do
  @moduledoc """
  Creates the workflow_steps table for step-level idempotency tracking.

  This replaces DBOS's step durability. Each step is keyed by
  {workflow_id, step_name} with a unique constraint ensuring
  exactly-once execution semantics.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS workflow_steps (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      workflow_id TEXT NOT NULL,
      step_name TEXT NOT NULL,
      state TEXT DEFAULT 'pending' NOT NULL,
      attempt INTEGER DEFAULT 0 NOT NULL,
      max_attempts INTEGER DEFAULT 3 NOT NULL,
      result TEXT,
      error TEXT,
      started_at TEXT,
      completed_at TEXT,
      inserted_at TEXT DEFAULT (datetime('now')) NOT NULL,
      updated_at TEXT DEFAULT (datetime('now')) NOT NULL
    )
    """)

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS workflow_steps_workflow_id_step_name_index ON workflow_steps(workflow_id, step_name)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS workflow_steps_workflow_id_index ON workflow_steps(workflow_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS workflow_steps_state_index ON workflow_steps(state)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS workflow_steps_state_index")
    execute("DROP INDEX IF EXISTS workflow_steps_workflow_id_index")
    execute("DROP INDEX IF EXISTS workflow_steps_workflow_id_step_name_index")
    execute("DROP TABLE IF EXISTS workflow_steps")
  end
end
