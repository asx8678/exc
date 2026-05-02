defmodule CodePuppyControl.CLI.SlashCommands.Commands.Flags do
  @moduledoc """
  Flags slash command: /flags [reset|set <flag>|clear <flag>].

  Shows workflow state and all known flags with active/inactive markers,
  or manipulates individual flags.

  Ports the Python /flags command from `code_puppy/command_line/workflow_commands.py`.
  """

  alias CodePuppyControl.Workflow.State

  @usage "Usage: /flags [reset|set <flag>|clear <flag>]"

  @doc """
  Handles `/flags` — show workflow state and all known flags.

  Subcommands:
    /flags             — show all flags with active/inactive markers
    /flags reset       — reset workflow state
    /flags set <flag>  — set (activate) a named flag
    /flags clear <flag> — clear (deactivate) a named flag
  """
  @spec handle_flags(String.t(), any()) :: {:continue, any()}
  def handle_flags(line, state) do
    case parse_args(line) do
      [] ->
        show_workflow_state()

      ["reset"] ->
        State.reset()
        print_success("Workflow state reset")

      ["set", flag_name] ->
        set_flag_command(flag_name)

      ["clear", flag_name] ->
        clear_flag_command(flag_name)

      _other ->
        print_usage()
    end

    {:continue, state}
  end

  # ── Subcommand Handlers ──────────────────────────────────────────────────

  defp show_workflow_state do
    active_count = State.active_count()
    all_flags = State.all_flags()
    total = length(all_flags)

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> IO.ANSI.magenta() <> "    Workflow State" <> IO.ANSI.reset())
    IO.puts("")

    Enum.each(all_flags, fn {flag_name, description} ->
      if State.has_flag?(flag_name) do
        IO.puts(
          "    ✓ #{IO.ANSI.green()}#{String.pad_trailing(to_string(flag_name), 27)}#{IO.ANSI.reset()} #{description}"
        )
      else
        IO.puts(
          "    ○ #{IO.ANSI.faint()}#{String.pad_trailing(to_string(flag_name), 27)}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{description}#{IO.ANSI.reset()}"
        )
      end
    end)

    IO.puts("")
    IO.puts("    #{IO.ANSI.faint()}Active flags: #{active_count}/#{total}#{IO.ANSI.reset()}")

    metadata = State.metadata()

    if map_size(metadata) > 0 do
      IO.puts("")
      IO.puts("    #{IO.ANSI.bright()}Metadata:#{IO.ANSI.reset()}")

      metadata
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.each(fn {key, value} ->
        formatted = format_metadata_value(value)
        IO.puts("      #{key}: #{formatted}")
      end)
    end

    IO.puts("")
  end

  defp set_flag_command(raw_name) do
    flag_atom = normalize_flag(raw_name)

    if State.known_flag?(flag_atom) do
      State.set_flag(flag_atom)
      print_success("Flag #{flag_atom} set")
    else
      print_warning("Unknown flag: #{raw_name}")
    end
  end

  defp clear_flag_command(raw_name) do
    flag_atom = normalize_flag(raw_name)

    if State.known_flag?(flag_atom) do
      State.clear_flag(flag_atom)
      print_success("Flag #{flag_atom} cleared")
    else
      print_warning("Unknown flag: #{raw_name}")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Safe flag lookup: match user input against known flag atoms
  # without calling String.to_atom/1, which would create atoms from
  # arbitrary user input (atom table exhaustion risk).
  defp normalize_flag(name) when is_binary(name) do
    downcased = String.downcase(name)

    State.flag_names()
    |> Enum.find(fn atom -> Atom.to_string(atom) == downcased end)
  end

  defp parse_args("/" <> rest) do
    rest
    |> String.trim()
    |> String.split(~r/\s+/, parts: 3)
    |> case do
      [_name] -> []
      [_name, sub] -> [String.downcase(sub)]
      [_name, sub, arg] -> [String.downcase(sub), String.trim(arg)]
    end
  end

  defp parse_args(_line), do: []

  # Safely format metadata values for display.
  # Strings are shown as-is; everything else is inspected.
  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value), do: inspect(value)

  defp print_success(msg) do
    IO.puts(IO.ANSI.green() <> "    ✓ #{msg}" <> IO.ANSI.reset())
  end

  defp print_warning(msg) do
    IO.puts(IO.ANSI.yellow() <> "    ⚠ #{msg}" <> IO.ANSI.reset())
  end

  defp print_usage do
    IO.puts(IO.ANSI.yellow() <> "    #{@usage}" <> IO.ANSI.reset())
  end
end
