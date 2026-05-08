defmodule Mix.Tasks.PupEx.Doctor do
  @shortdoc "Health check for Elixir pup-ex isolation and configuration"
  @moduledoc """
  Run isolation health checks for the Elixir pup-ex home directory.

  Checks that the Elixir home exists, has correct permissions, the
  isolation guard blocks writes to the legacy home, and all Paths.*
  functions resolve under the Elixir home.

  ## Usage

      mix pup_ex.doctor

  ## Exit codes

  - 0 — all checks pass (or are informational/warnings)
  - 1 — one or more checks failed
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    checks = CodePuppyControl.Config.Doctor.run_checks()
    report = CodePuppyControl.Config.Doctor.format_report(checks)
    Mix.shell().info(report)
    exit_code = CodePuppyControl.Config.Doctor.exit_code(checks)
    Mix.shell().info("")
    System.halt(exit_code)
  end
end
