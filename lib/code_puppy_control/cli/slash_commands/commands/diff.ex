defmodule CodePuppyControl.CLI.SlashCommands.Commands.Diff do
  @moduledoc """
  Diff slash command: /diff [additions|deletions] [color].

  Shows or configures diff highlighting colors for additions and deletions.

  ## Usage

      /diff              — show current addition/deletion colors and usage
      /diff additions <color>  — set addition color
      /diff deletions <color>  — set deletion color

  Aliases: `additions|addition|add` and `deletions|deletion|del`.
  """

  alias CodePuppyControl.Config.TUI

  @addition_aliases ~w(additions addition add)
  @deletion_aliases ~w(deletions deletion del)

  @doc """
  Handles `/diff` — shows or sets diff highlighting colors.
  """
  @spec handle_diff(String.t(), any()) :: {:continue, any()}
  def handle_diff(line, state) do
    case extract_args(line) |> String.trim() do
      "" ->
        show_current()

      args ->
        parts = String.split(args, ~r/\s+/, trim: true)

        case parts do
          [subcmd, color] ->
            set_color(subcmd, color)

          [subcmd] ->
            # Bare subcommand with no color — treat as show for that channel
            if normalize_subcmd(subcmd) != nil do
              show_channel(normalize_subcmd(subcmd))
            else
              print_usage()
            end

          _more ->
            print_usage()
        end
    end

    {:continue, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp show_current do
    add_color = TUI.diff_addition_color()
    del_color = TUI.diff_deletion_color()
    ctx_lines = TUI.diff_context_lines()

    IO.puts("")

    IO.puts("    #{IO.ANSI.bright()}Diff Highlight Colors#{IO.ANSI.reset()}")

    IO.puts("")

    IO.puts("    Additions:  #{IO.ANSI.green()}#{add_color}#{IO.ANSI.reset()}")

    IO.puts("    Deletions:  #{IO.ANSI.red()}#{del_color}#{IO.ANSI.reset()}")

    IO.puts("    Context:    #{IO.ANSI.faint()}#{ctx_lines} lines#{IO.ANSI.reset()}")

    IO.puts("")
    print_usage_hint()
    IO.puts("")
  end

  defp show_channel(:additions) do
    add_color = TUI.diff_addition_color()

    IO.puts("")

    IO.puts("    Additions color: #{IO.ANSI.green()}#{add_color}#{IO.ANSI.reset()}")

    IO.puts("")
    print_usage_hint()
    IO.puts("")
  end

  defp show_channel(:deletions) do
    del_color = TUI.diff_deletion_color()

    IO.puts("")

    IO.puts("    Deletions color: #{IO.ANSI.red()}#{del_color}#{IO.ANSI.reset()}")

    IO.puts("")
    print_usage_hint()
    IO.puts("")
  end

  defp set_color(subcmd, color) do
    case normalize_subcmd(subcmd) do
      :additions ->
        TUI.set_diff_addition_color(color)

        IO.puts("")

        IO.puts("    Additions color set to #{IO.ANSI.green()}#{color}#{IO.ANSI.reset()}")

        IO.puts("")

      :deletions ->
        TUI.set_diff_deletion_color(color)

        IO.puts("")

        IO.puts("    Deletions color set to #{IO.ANSI.red()}#{color}#{IO.ANSI.reset()}")

        IO.puts("")

      nil ->
        IO.puts(
          IO.ANSI.red() <>
            "    Unknown subcommand: '#{subcmd}'. Use 'additions' or 'deletions'." <>
            IO.ANSI.reset()
        )

        print_usage()
    end
  end

  defp normalize_subcmd(subcmd) do
    down = String.downcase(subcmd)

    cond do
      down in @addition_aliases -> :additions
      down in @deletion_aliases -> :deletions
      true -> nil
    end
  end

  defp print_usage do
    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        "    Usage: /diff [additions|deletions] <color>" <>
        IO.ANSI.reset()
    )

    IO.puts(
      "    #{IO.ANSI.faint()}Aliases: additions|addition|add, deletions|deletion|del#{IO.ANSI.reset()}"
    )

    IO.puts(
      "    #{IO.ANSI.faint()}Use /diff without arguments to see current colors#{IO.ANSI.reset()}"
    )

    IO.puts("")
  end

  defp print_usage_hint do
    IO.puts(
      "    #{IO.ANSI.faint()}Use /diff [additions|deletions] <color> to change#{IO.ANSI.reset()}"
    )
  end

  @spec extract_args(String.t()) :: String.t()
  defp extract_args("/" <> rest) do
    case String.split(rest, " ", parts: 2) do
      [_name] -> ""
      [_name, args] -> args
    end
  end

  defp extract_args(_line), do: ""
end
