defmodule CodePuppyControl.CLI.Gac do
  @moduledoc """
  Elixir CLI entry point for `gac` (Git Auto Commit).

  Preserves command-line compatibility with the Python implementation
  in `code_puppy.plugins.git_auto_commit.cli`.

  ## Usage

      gac [OPTIONS]

  ## Options

    * `-m`, `--message TEXT` - Commit message (auto-generated if not provided)
    * `--no-push` - Commit only, don't push
    * `--dry-run` - Preview only, don't execute
    * `--no-stage` - Don't auto-stage changes
  """

  alias CodePuppyControl.CLI.GacParser

  @doc """
  Main entry point invoked by the escript wrapper.
  """
  @spec main([String.t()]) :: no_return()
  def main(args) do
    case GacParser.parse(args) do
      {:help, _opts} ->
        IO.puts(help_text())
        System.halt(0)

      {:ok, opts} ->
        exit_code = run(opts)
        System.halt(exit_code)

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}")
        IO.puts(:stderr, "Try 'gac --help' for usage information.")
        System.halt(1)
    end
  end

  @doc """
  Run the git auto-commit flow.

  Returns 0 on success, 1 on failure.
  """
  @spec run(map()) :: 0 | 1
  def run(opts) do
    # TODO(gac-elixir-git-ops): Wire to CodePuppyControl git operations
    # Currently a placeholder that delegates to System.cmd("git", ...)

    IO.puts("🔍 Checking git status...")

    case check_git_status() do
      {:ok, :clean} ->
        IO.puts("📭 Working tree clean - nothing to commit")
        0

      {:ok, :dirty} ->
        execute_gac_flow(opts)

      {:error, reason} ->
        IO.puts("❌ Preflight failed: #{reason}")
        1
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_git_status do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) == "" do
          {:ok, :clean}
        else
          {:ok, :dirty}
        end

      {_output, _code} ->
        {:error, "git status failed — are you in a git repository?"}
    end
  end

  defp execute_gac_flow(opts) do
    # Dry-run guard BEFORE any git operations
    if opts[:dry_run] do
      IO.puts("🏃 Dry run mode: would stage all files and commit")
      IO.puts(" (no changes made)")
      0
    else
      # Stage if needed
      unless opts[:no_stage] do
        IO.puts("📦 Staging all changes...")

        case System.cmd("git", ["add", "-A"], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {err, _} -> IO.puts("⚠️ git add: #{String.trim(err)}")
        end
      end

      commit_and_push(opts)
    end
  end

  defp commit_and_push(opts) do
    message = opts[:message] || generate_message()

    IO.puts("\n💾 Committing...")

    case System.cmd("git", ["commit", "-m", message], stderr_to_stdout: true) do
      {output, 0} ->
        # Extract short hash from output
        hash = extract_commit_hash(output)
        IO.puts("✓ Committed: #{hash}")

        if opts[:no_push] do
          IO.puts("\n🎉 Done!")
          0
        else
          push_to_remote()
        end

      {err, _} ->
        IO.puts("❌ Commit failed: #{String.trim(err)}")
        1
    end
  end

  defp push_to_remote do
    branch = get_current_branch()
    branch_str = if branch, do: " (#{branch})", else: ""
    IO.puts("\n🚀 Pushing#{branch_str}...")

    case System.cmd("git", ["push"], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("✓ Pushed to remote")
        IO.puts("\n🎉 Done!")
        0

      {err, _} ->
        IO.puts("❌ Push failed: #{String.trim(err)}")
        1
    end
  end

  defp get_current_branch do
    case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  end

  defp generate_message do
    # Get staged files for heuristics
    {diff_output, _} =
      System.cmd("git", ["diff", "--cached", "--name-only"], stderr_to_stdout: true)

    files = diff_output |> String.trim() |> String.split("\n", trim: true)

    prefix =
      cond do
        Enum.any?(files, &String.contains?(&1, "fix")) -> "fix"
        Enum.any?(files, &String.contains?(&1, "test")) -> "test"
        Enum.any?(files, &String.ends_with?(&1, ".md")) -> "docs"
        length(files) == 1 -> "feat"
        true -> "chore"
      end

    message =
      if length(files) == 1 do
        "#{prefix}: update #{hd(files)}"
      else
        "#{prefix}: update #{length(files)} files"
      end

    IO.puts("\n📝 Auto-generated message: '#{message}'")
    message
  end

  defp extract_commit_hash(output) do
    case Regex.run(~r/\[[\w-]+ ([a-f0-9]{7,})\]/, output) do
      [_, hash] -> hash
      _ -> "?"
    end
  end

  @doc """
  Generate help text matching the Python GAC CLI format.
  """
  @spec help_text() :: String.t()
  def help_text do
    """
    usage: gac [-h] [-m MESSAGE] [--no-push] [--dry-run] [--no-stage]

    Git Auto Commit - stage, commit, and push in one command

    optional arguments:
      -h, --help show this help message and exit
      -m, --message TEXT Commit message (auto-generated if not provided)
      --no-push Commit only, don't push
      --dry-run Preview only, don't execute
      --no-stage Don't auto-stage changes
    """
  end
end
