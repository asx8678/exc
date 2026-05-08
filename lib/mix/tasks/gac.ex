defmodule Mix.Tasks.Gac do
  @moduledoc """
  Run the `gac` (Git Auto Commit) CLI.

      mix gac [OPTIONS]

  ## Options

    * `-m`, `--message TEXT`  - Commit message (auto-generated if not provided)
    * `--no-push`            - Commit only, don't push
    * `--dry-run`            - Preview only, don't execute
    * `--no-stage`           - Don't auto-stage changes
  """

  use Mix.Task

  @shortdoc "Git Auto Commit - stage, commit, and push in one command"

  @impl Mix.Task
  def run(args) do
    CodePuppyControl.CLI.Gac.main(args)
  end
end
