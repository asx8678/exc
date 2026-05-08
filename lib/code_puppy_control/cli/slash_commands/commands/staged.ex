defmodule CodePuppyControl.CLI.SlashCommands.Commands.Staged do
  @moduledoc """
  Staged slash command: /staged [on|off|diff|preview|clear|apply|reject|save|load|status].

  Shows or manages staged changes for safe edit application.
  Ports the Python /staged command from
  `code_puppy/command_line/staged_commands.py`.

  ## Usage

    /staged              — show current staged changes summary
    /staged on           — enable staging mode
    /staged off          — disable staging mode
    /staged diff         — show combined diff of all staged changes
    /staged preview      — preview changes by file
    /staged clear        — clear all staged changes
    /staged apply        — apply all staged changes
    /staged reject       — reject all staged changes
    /staged save         — save staged changes to disk
    /staged load         — load staged changes from disk
    /staged status       — show summary (alias for bare /staged)
  """

  alias CodePuppyControl.Tools.StagedChanges

  @doc """
  Handles `/staged` — show or manage staged changes.
  """
  @spec handle_staged(String.t(), any()) :: {:continue, any()}
  def handle_staged(line, state) do
    case extract_args(line) |> String.trim() do
      "" ->
        show_summary()

      args ->
        parts = String.split(args, ~r/\s+/, trim: true)
        subcmd = hd(parts)

        case subcmd do
          "on" -> do_on()
          "off" -> do_off()
          "diff" -> do_diff()
          "preview" -> do_preview()
          "clear" -> do_clear()
          "apply" -> do_apply()
          "reject" -> do_reject()
          "save" -> do_save()
          "load" -> do_load()
          s when s in ["status", "summary"] -> show_summary()
          _ -> print_usage()
        end
    end

    {:continue, state}
  end

  # ── Subcommand handlers ─────────────────────────────────────────────────

  defp do_on do
    StagedChanges.enable()

    IO.puts(
      IO.ANSI.green() <>
        "    Staging mode enabled - file edits will be staged for review" <> IO.ANSI.reset()
    )

    show_summary()
  end

  defp do_off do
    StagedChanges.disable()

    IO.puts(
      IO.ANSI.yellow() <>
        "    Staging mode disabled - file edits will be applied immediately" <> IO.ANSI.reset()
    )
  end

  defp do_diff do
    diff = StagedChanges.get_combined_diff()

    if diff == "" do
      IO.puts(IO.ANSI.faint() <> "    No staged changes to diff" <> IO.ANSI.reset())
    else
      IO.puts("")

      IO.puts(
        IO.ANSI.bright() <>
          IO.ANSI.magenta() <> "Combined Diff of Staged Changes:" <> IO.ANSI.reset()
      )

      IO.puts("")
      IO.puts(diff)
    end
  end

  defp do_preview do
    preview = StagedChanges.preview_changes()

    if map_size(preview) == 0 do
      IO.puts(IO.ANSI.faint() <> "    No staged changes to preview" <> IO.ANSI.reset())
    else
      IO.puts("")

      IO.puts(
        IO.ANSI.bright() <>
          IO.ANSI.magenta() <> "Preview of Staged Changes by File:" <> IO.ANSI.reset()
      )

      IO.puts("")

      Enum.each(preview, fn {file_path, diff} ->
        IO.puts(IO.ANSI.bright() <> IO.ANSI.cyan() <> "    #{file_path}" <> IO.ANSI.reset())

        if diff != "" do
          IO.puts("    ```diff")
          # Indent diff lines for readability
          diff
          |> String.split("\n")
          |> Enum.each(&IO.puts("    #{&1}"))

          IO.puts("    ```")
        else
          IO.puts(IO.ANSI.faint() <> "    No diff available" <> IO.ANSI.reset())
        end

        IO.puts("")
      end)
    end
  end

  defp do_clear do
    c = StagedChanges.count()

    if c > 0 do
      StagedChanges.clear()
      IO.puts(IO.ANSI.green() <> "    Cleared #{c} staged changes" <> IO.ANSI.reset())
    else
      IO.puts(IO.ANSI.faint() <> "    No staged changes to clear" <> IO.ANSI.reset())
    end
  end

  defp do_apply do
    case StagedChanges.apply_all() do
      {:ok, 0} ->
        IO.puts(IO.ANSI.faint() <> "    No staged changes to apply" <> IO.ANSI.reset())

      {:ok, n} ->
        IO.puts(
          IO.ANSI.green() <> "    Applied #{n} staged changes successfully" <> IO.ANSI.reset()
        )

      {:error, msg} ->
        IO.puts(IO.ANSI.red() <> "    Error applying changes: #{msg}" <> IO.ANSI.reset())
    end
  end

  defp do_reject do
    n = StagedChanges.reject_all()

    if n > 0 do
      IO.puts(IO.ANSI.green() <> "    Rejected #{n} staged changes" <> IO.ANSI.reset())
    else
      IO.puts(IO.ANSI.faint() <> "    No staged changes to reject" <> IO.ANSI.reset())
    end
  end

  defp do_save do
    case StagedChanges.save_to_disk() do
      {:ok, path} ->
        IO.puts(IO.ANSI.green() <> "    Staged changes saved to #{path}" <> IO.ANSI.reset())

      {:error, msg} ->
        IO.puts(IO.ANSI.red() <> "    Save failed: #{msg}" <> IO.ANSI.reset())
    end
  end

  defp do_load do
    if StagedChanges.load_from_disk() do
      IO.puts(IO.ANSI.green() <> "    Staged changes loaded from disk" <> IO.ANSI.reset())
      show_summary()
    else
      IO.puts(IO.ANSI.red() <> "    No saved staged changes found" <> IO.ANSI.reset())
    end
  end

  # ── Summary display ─────────────────────────────────────────────────────

  defp show_summary do
    summary = StagedChanges.get_summary()

    status = if summary.enabled, do: "ON", else: "OFF"
    status_color = if summary.enabled, do: IO.ANSI.green(), else: IO.ANSI.red()

    IO.puts("")

    IO.puts(
      IO.ANSI.bright() <>
        IO.ANSI.magenta() <>
        "    Staged Changes" <> IO.ANSI.reset() <> " (#{status_color}#{status}#{IO.ANSI.reset()})"
    )

    IO.puts("")

    total = summary.total

    if total == 0 do
      IO.puts(IO.ANSI.faint() <> "    No pending staged changes" <> IO.ANSI.reset())
    else
      IO.puts(
        "    #{IO.ANSI.bright()}#{total}#{IO.ANSI.reset()} pending change#{if total != 1, do: "s", else: ""}"
      )

      # By type
      by_type = summary.by_type

      if map_size(by_type) > 0 do
        IO.puts("")
        IO.puts("    #{IO.ANSI.bright()}By type:#{IO.ANSI.reset()}")

        Enum.each(by_type, fn {type_name, count} ->
          IO.puts("      #{type_name}: #{IO.ANSI.cyan()}#{count}#{IO.ANSI.reset()}")
        end)
      end

      # Files affected
      files = summary.files

      if length(files) > 0 do
        IO.puts("")

        IO.puts(
          "    #{IO.ANSI.bright()}Files affected:#{IO.ANSI.reset()} #{IO.ANSI.cyan()}#{length(files)}#{IO.ANSI.reset()}"
        )

        Enum.take(files, 5)
        |> Enum.each(fn f ->
          IO.puts(IO.ANSI.faint() <> "      #{f}" <> IO.ANSI.reset())
        end)

        if length(files) > 5 do
          IO.puts(IO.ANSI.faint() <> "      ... and #{length(files) - 5} more" <> IO.ANSI.reset())
        end
      end
    end

    IO.puts("")
    print_usage_hint()
    IO.puts("")
  end

  # ── Usage helpers ───────────────────────────────────────────────────────

  defp print_usage do
    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        "    Usage: /staged [on|off|diff|preview|clear|apply|reject|save|load|status]" <>
        IO.ANSI.reset()
    )

    IO.puts("")
  end

  defp print_usage_hint do
    IO.puts(
      IO.ANSI.faint() <>
        "    Commands: /staged on|off|diff|preview|clear|apply|reject|save|load" <>
        IO.ANSI.reset()
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
