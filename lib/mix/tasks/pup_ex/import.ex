defmodule Mix.Tasks.PupEx.Import do
  @shortdoc "Import non-sensitive settings from ~/.code_puppy/ (Python pup's home)"
  @moduledoc """
  Import non-sensitive settings from the Python pup's legacy home directory.

  This task copies allowlisted files from `~/.code_puppy/` to
  `~/.code_puppy_ex/`. It will NEVER touch OAuth tokens, sessions,
  autosaves, databases, or command history.

  ## Usage

      # Dry-run: see what WOULD be copied
      mix pup_ex.import

      # Actually copy files
      mix pup_ex.import --confirm

      # Overwrite existing files
      mix pup_ex.import --confirm --force

  ## Imported files

  - `extra_models.json` — user-added model definitions
  - `models.json` — model registry entries (deep-merged)
  - `puppy.cfg` — only `[ui]` section keys (cosmetic preferences)
  - `agents/*.json` — agent definition files
  - `skills/*/` — skill directories (with SKILL.md)

  ## Forbidden (never copied)

  - OAuth tokens, API keys, session data
  - `autosaves/`, `sessions/`, `*.sqlite`, `command_history.txt`
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [confirm: :boolean, force: :boolean])

    result = CodePuppyControl.Config.Importer.run(opts)
    format_report_and_exit(result)
  end

  defp format_report_and_exit(%{mode: :no_op} = _result) do
    Mix.shell().info("No legacy home to import from.")
  end

  defp format_report_and_exit(%{
         mode: mode,
         copied: copied,
         skipped: skipped,
         refused: refused,
         errors: errors
       }) do
    mode_label = if mode == :dry_run, do: "DRY RUN", else: "COPY"

    Mix.shell().info("\n📦 pup-ex import (#{mode_label} mode)")
    Mix.shell().info(String.duplicate("─", 50))

    if copied != [] do
      Mix.shell().info("\n  ✅ #{if mode == :dry_run, do: "Would copy", else: "Copied"}:")

      Enum.each(copied, fn path ->
        Mix.shell().info("     • #{path}")
      end)
    end

    if skipped != [] do
      Mix.shell().info("\n  ⏭️  Skipped:")

      Enum.each(skipped, fn {path, reason} ->
        Mix.shell().info("     • #{path} — #{reason}")
      end)
    end

    if refused != [] do
      Mix.shell().info("\n  🚫 Refused (forbidden by ADR-003):")

      Enum.each(refused, fn {path, reason} ->
        Mix.shell().info("     • #{path} — #{reason}")
      end)
    end

    if errors != [] do
      Mix.shell().info("\n  ❌ Errors:")

      Enum.each(errors, fn {path, reason} ->
        Mix.shell().info("     • #{path} — #{inspect(reason)}")
      end)
    end

    total = length(copied) + length(skipped) + length(refused) + length(errors)

    Mix.shell().info(
      "\n  #{total} items: #{length(copied)} copied, #{length(skipped)} skipped, #{length(refused)} refused, #{length(errors)} errors"
    )

    if mode == :dry_run and total > 0 do
      Mix.shell().info("\n  Run with --confirm to actually copy files.")
    end

    Mix.shell().info("")
  end
end
