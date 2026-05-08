defmodule CodePuppyControl.Plugins.GitAutoCommit do
  @moduledoc """
  Git Auto Commit (GAC) plugin providing the `/commit` slash command.

  Orchestrates the full commit flow through three phases:
  1. Preflight - Check git status, detect staged/unstaged changes
  2. Preview - Generate commit message preview, show what will be committed
  3. Execute - Run git commit through security boundary

  ## Hooks Registered

    * `:custom_command` - handles `/commit` slash command
    * `:custom_command_help` - provides help entries for commit commands
  """

  use CodePuppyControl.Plugins.PluginBehaviour
  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Tools.SubagentContext
  require Logger

  @impl true
  def name, do: "git_auto_commit"

  @impl true
  def description, do: "Git auto-commit with preflight, preview, and execute phases"

  @impl true
  def register do
    Callbacks.register(:custom_command, &__MODULE__.handle_command/2)
    Callbacks.register(:custom_command_help, &__MODULE__.command_help/0)
    :ok
  end

  @impl true
  def startup, do: :ok

  @impl true
  def shutdown, do: :ok

  @spec handle_command(String.t(), String.t()) :: String.t() | true | nil
  def handle_command(command, "commit"), do: handle_commit(command)
  def handle_command(_command, _name), do: nil

  defp handle_commit(command) do
    args = parse_commit_args(command)
    {is_safe, reason} = is_gac_safe()

    if not is_safe do
      "GAC refused: #{reason}"
    else
      execute_commit_flow(args)
    end
  end

  defp execute_commit_flow(args) do
    subcommand = args.subcommand

    case preflight_check() do
      {:ok, %{clean: true}} ->
        "Working tree clean - nothing to commit"

      {:ok, %{has_staged: false} = result} ->
        unstaged = length(result.unstaged_files)
        untracked = length(result.untracked_files)
        "No staged changes. #{unstaged} modified, #{untracked} untracked."

      {:ok, %{has_staged: true} = result} ->
        staged_count = length(result.staged_files)

        if subcommand == "status" do
          "Found #{staged_count} staged file(s)"
        else
          case generate_preview() do
            {:ok, preview} ->
              if subcommand == "preview" do
                preview.summary
              else
                case args.message do
                  nil -> "Use /commit -m message to execute"
                  message -> execute_commit(message)
                end
              end

            {:error, reason} ->
              "Preview failed: #{reason}"
          end
        end

      {:error, reason} ->
        "Preflight failed: #{reason}"
    end
  end

  defp parse_commit_args(command) do
    parts = String.split(command, ~r/\s+/)

    parts =
      case parts do
        ["/commit" | rest] -> rest
        ["commit" | rest] -> rest
        _ -> parts
      end

    cond do
      parts == [] ->
        %{subcommand: "default", message: nil, dry_run: false}

      hd(parts) |> String.downcase() == "status" ->
        %{subcommand: "status", message: nil, dry_run: true}

      hd(parts) |> String.downcase() == "preview" ->
        %{subcommand: "preview", message: nil, dry_run: true}

      true ->
        case find_message_flag(parts) do
          nil -> %{subcommand: "default", message: nil, dry_run: false}
          msg -> %{subcommand: "execute", message: msg, dry_run: false}
        end
    end
  end

  defp find_message_flag(parts) do
    case Enum.find_index(parts, &(&1 == "-m")) do
      nil ->
        nil

      idx ->
        message_parts = Enum.slice(parts, (idx + 1)..-1//1)
        Enum.join(message_parts, " ") |> String.trim()
    end
  end

  defp is_gac_safe do
    if SubagentContext.is_subagent?() do
      {false, "running in sub-agent context"}
    else
      {true, nil}
    end
  end

  defp preflight_check do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        lines = output |> String.trim() |> String.split("\n", trim: true)
        {staged, unstaged, untracked} = parse_git_status(lines)

        {:ok,
         %{
           staged_files: staged,
           unstaged_files: unstaged,
           untracked_files: untracked,
           has_staged: length(staged) > 0,
           clean: length(lines) == 0
         }}

      {error, _code} ->
        {:error, String.trim(error)}
    end
  end

  defp parse_git_status(lines) do
    Enum.reduce(lines, {[], [], []}, fn line, {staged, unstaged, untracked} ->
      if String.length(line) < 3 do
        {staged, unstaged, untracked}
      else
        status_code = String.slice(line, 0, 2)
        filename = String.slice(line, 3..-1//1)

        cond do
          status_code == "??" ->
            {staged, unstaged, [filename | untracked]}

          status_code == "!!" ->
            {staged, unstaged, untracked}

          true ->
            x = String.slice(status_code, 0, 1)
            y = String.slice(status_code, 1, 1)

            new_staged =
              if x in ["M", "A", "D", "R", "C", "U"], do: [filename | staged], else: staged

            new_unstaged = if y in ["M", "D", "U"], do: [filename | unstaged], else: unstaged
            {new_staged, new_unstaged, untracked}
        end
      end
    end)
    |> then(fn {s, u, t} -> {Enum.reverse(s), Enum.reverse(u), Enum.reverse(t)} end)
  end

  defp generate_preview do
    case System.cmd("git", ["diff", "--cached", "--stat"], stderr_to_stdout: true) do
      {output, 0} ->
        summary = extract_summary(output)
        {:ok, %{diff: String.trim(output), summary: summary}}

      {error, _code} ->
        {:error, String.trim(error)}
    end
  end

  defp extract_summary(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find("", fn line ->
      String.contains?(String.downcase(line), "file") and
        String.contains?(String.downcase(line), "changed")
    end)
    |> String.trim()
    |> case do
      "" -> "Staged changes ready to commit"
      s -> s
    end
  end

  defp execute_commit(message) do
    case System.cmd("git", ["commit", "-m", message], stderr_to_stdout: true) do
      {output, 0} ->
        hash = extract_commit_hash(output)
        branch = get_current_branch()
        "Successfully committed [#{hash}] on #{branch}"

      {error, _code} ->
        "Commit failed: #{String.trim(error)}"
    end
  end

  defp extract_commit_hash(output) do
    case Regex.run(~r/\[[\w-]+ ([a-f0-9]{7,})\]/, output) do
      [_, hash] -> hash
      _ -> "?"
    end
  end

  defp get_current_branch do
    case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> "unknown"
    end
  end

  @spec command_help() :: [{String.t(), String.t()}]
  def command_help do
    [
      {"/commit", "Git auto-commit - preflight, preview, execute"},
      {"/commit status", "Run preflight check only"},
      {"/commit preview", "Show what would be committed"},
      {"/commit -m msg", "Execute commit with message"}
    ]
  end
end
