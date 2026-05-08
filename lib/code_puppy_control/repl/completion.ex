defmodule CodePuppyControl.REPL.Completion do
  @moduledoc """
  Tab completion for the REPL.

  Supports:
  - Slash commands (derived from `SlashCommands.Registry` when running, fallback otherwise)
  - File path completion for `@mentions`

  ## Usage

      Completion.complete("/he", :command)  #=> ["/help"]
      Completion.complete("@src/mai", :file) #=> ["@src/main.ex", ...]
      Completion.complete("/m", :auto)      #=> ["/model"]  (auto-detects type)
  """

  # ── Slash Commands ────────────────────────────────────────────────────────

  # Fallback used when the Registry ETS table is not running (tests, early
  # startup).  Must be kept in sync with
  # `CodePuppyControl.CLI.SlashCommands.Registry.register_builtin_commands/0`.
  @fallback_slash_commands [
    "/help",
    "/model",
    "/mode",
    "/model_settings",
    "/ms",
    "/agent",
    "/agents",
    "/quit",
    "/exit",
    "/clear",
    "/history",
    "/pack",
    "/flags",
    "/diff",
    "/sessions",
    "/tui",
    "/cd",
    "/compact",
    "/truncate",
    "/add_model"
  ]

  # Returns the list of slash commands for completion.  When the ETS-backed
  # Registry is running, derives the list dynamically so new commands are
  # automatically picked up.  Falls back to the hardcoded list otherwise.
  @spec slash_commands() :: [String.t()]
  defp slash_commands do
    alias CodePuppyControl.CLI.SlashCommands.Registry

    case Registry.all_names() do
      [] ->
        # Registry not started or empty — use the maintained fallback
        @fallback_slash_commands

      names ->
        names
        |> Enum.map(&("/" <> &1))
        |> Enum.sort()
    end
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Completes input based on context type.

  `type` can be:
  - `:command` — complete slash commands
  - `:file` — complete file paths for @mentions
  - `:auto` — auto-detect from input prefix

  Returns a list of candidate strings.
  """
  @spec complete(String.t(), :command | :file | :auto) :: [String.t()]
  def complete(input, type \\ :auto)

  def complete(input, :auto) do
    cond do
      String.starts_with?(input, "/") -> complete(input, :command)
      String.starts_with?(input, "@") -> complete(input, :file)
      true -> []
    end
  end

  def complete(input, :command) do
    complete_command(input)
  end

  def complete(input, :file) do
    complete_file_path(input)
  end

  @doc """
  Completes a slash command prefix.

  Matches all registered commands that start with the given prefix.

  ## Examples

      iex> Completion.complete_command("/h")
      ["/help", "/history"]

      iex> Completion.complete_command("/model")
      ["/model"]
  """
  @spec complete_command(String.t()) :: [String.t()]
  def complete_command(prefix) do
    # If prefix includes a space, it's a command with args — no command completion
    if String.contains?(prefix, " ") do
      []
    else
      Enum.filter(slash_commands(), fn cmd ->
        String.starts_with?(cmd, prefix)
      end)
    end
  end

  @doc """
  Completes a file path for @mention syntax.

  Input should start with `@`. The path after `@` is resolved relative
  to the current working directory.

  Returns full `@path` candidates.

  ## Examples

      iex> Completion.complete_file_path("@lib/code_puppy_control/repl/h")
      ["@lib/code_puppy_control/repl/history.ex", ...]
  """
  @spec complete_file_path(String.t()) :: [String.t()]
  def complete_file_path("@" <> relative_path) do
    cwd = File.cwd!()

    complete_path(cwd, relative_path)
    |> Enum.map(fn path -> "@" <> path end)
  end

  def complete_file_path(_input), do: []

  # ── Private ───────────────────────────────────────────────────────────────

  defp complete_path(base_dir, relative_path) do
    # Split into dir and prefix parts
    # e.g., "src/mai" → dir="src", prefix="mai"
    # e.g., "src/" → dir="src", prefix=""
    # e.g., "src" → dir=".", prefix="src"
    {dir_part, prefix_part} = split_path(relative_path)

    full_dir = Path.join(base_dir, dir_part)

    if File.dir?(full_dir) do
      try do
        full_dir
        |> File.ls!()
        |> Enum.filter(fn entry ->
          String.starts_with?(entry, prefix_part)
        end)
        |> Enum.sort()
        |> Enum.map(fn entry ->
          rel = Path.join(dir_part, entry)
          # Normalize: remove leading "./" for cleaner display
          rel = String.replace_prefix(rel, "./", "")
          # Add trailing slash for directories
          full = Path.join(base_dir, rel)

          if File.dir?(full) do
            rel <> "/"
          else
            rel
          end
        end)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp split_path(path) do
    dir = Path.dirname(path)

    if dir == "." and not String.ends_with?(path, "/") do
      # "mix." → search in current dir, prefix = "mix."
      {".", Path.basename(path)}
    else
      # "src/" → dir="src", prefix=""  or  "src/mai" → dir="src", prefix="mai"
      prefix = Path.basename(path)
      {dir, prefix}
    end
  end
end
