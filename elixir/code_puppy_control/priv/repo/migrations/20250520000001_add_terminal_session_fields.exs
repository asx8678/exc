defmodule CodePuppyControl.Repo.Migrations.AddTerminalSessionFields do
  @moduledoc """
  Adds terminal session tracking fields to chat_sessions.

  (code_puppy-ctj.1) These fields support crash-survivability for
  terminal sessions:

    - `has_terminal` — boolean marking whether this session has an
      active PTY terminal attached.
    - `terminal_meta` — JSON map storing PTY metadata (cols, rows,
      shell, attached_at) for crash recovery via
      `CodePuppyControl.SessionStorage.TerminalRecovery`.

  When the OTP node crashes, the Store rebuilds its ETS cache from
  SQLite on restart. Sessions with `has_terminal = true` are then
  identified for terminal recovery, and the stored `terminal_meta`
  is used to recreate the PTY sessions.
  """

  use Ecto.Migration

  def up do
    alter table(:chat_sessions) do
      add(:has_terminal, :boolean, default: false, null: false)
      add(:terminal_meta, :map, default: nil)
    end

    # Index for fast crash-recovery queries: "find all sessions with
    # active terminals" is the hot path during Store initialization.
    # Use execute(up, down) for proper rollback support.
    execute(
      "CREATE INDEX IF NOT EXISTS chat_sessions_has_terminal_index ON chat_sessions(has_terminal)",
      "DROP INDEX IF EXISTS chat_sessions_has_terminal_index"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS chat_sessions_has_terminal_index")

    alter table(:chat_sessions) do
      remove(:terminal_meta)
      remove(:has_terminal)
    end
  end
end
