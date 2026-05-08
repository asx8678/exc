defmodule CodePuppyControl.CLI.SlashCommands.Commands.Mode do
  @moduledoc """
  Mode slash command: /mode [preset_name].

  Shows the current configuration preset and available presets, or switches
  to a named preset. Ports the Python /mode command from
  `code_puppy/command_line/preset_commands.py`.

  ## Usage

    /mode              — show current mode and list presets
    /mode basic        — switch to the "basic" preset
    /mode full         — switch to the "full" preset (enables YOLO)
  """

  alias CodePuppyControl.Config.Presets

  @doc """
  Handles `/mode` — shows current mode and available presets.

  Handles `/mode <preset>` — applies the named preset and shows confirmation.
  """
  @spec handle_mode(String.t(), any()) :: {:continue, any()}
  def handle_mode(line, state) do
    case extract_args(line) |> String.trim() do
      "" ->
        show_current_mode()

      args ->
        parts = String.split(args, ~r/\s+/, trim: true)

        case parts do
          [preset_name] ->
            switch_preset(String.downcase(preset_name))

          _more ->
            print_usage()
        end
    end

    {:continue, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp show_current_mode do
    current = Presets.current_preset_guess()
    presets = Presets.list_presets()

    IO.puts("")

    IO.puts("    #{IO.ANSI.bright()}Configuration Mode#{IO.ANSI.reset()}")

    IO.puts("")

    if current do
      preset = Presets.get_preset(current)

      IO.puts("    Current mode: #{IO.ANSI.cyan()}#{preset.display_name}#{IO.ANSI.reset()}")

      IO.puts("    #{IO.ANSI.faint()}#{preset.description}#{IO.ANSI.reset()}")
    else
      IO.puts("    Current mode: #{IO.ANSI.yellow()}Custom#{IO.ANSI.reset()}")

      IO.puts(
        "    #{IO.ANSI.faint()}Your configuration doesn't match any preset.#{IO.ANSI.reset()}"
      )
    end

    IO.puts("")
    IO.puts("    Available presets:")

    Enum.each(presets, fn preset ->
      marker = if preset.name == current, do: "→ ", else: "  "

      IO.puts(
        "    #{marker}#{IO.ANSI.cyan()}#{String.pad_trailing(preset.name, 10)}#{IO.ANSI.reset()} " <>
          "#{IO.ANSI.faint()}#{preset.description}#{IO.ANSI.reset()}"
      )
    end)

    IO.puts("")
    IO.puts("    #{IO.ANSI.faint()}Use /mode <preset> to switch modes#{IO.ANSI.reset()}")
    IO.puts("")
  end

  defp switch_preset(preset_name) do
    case Presets.apply_preset(preset_name) do
      :ok ->
        preset = Presets.get_preset(preset_name)

        IO.puts("")

        IO.puts("    Applied '#{preset.display_name}' preset: #{preset.description}")

        if preset_name == "full" do
          IO.puts(
            IO.ANSI.yellow() <>
              "    WARNING: YOLO mode is now enabled — shell commands will execute without confirmation!" <>
              IO.ANSI.reset()
          )
        end

        IO.puts("")

      {:error, :not_found} ->
        available = Presets.list_presets() |> Enum.map(& &1.name) |> Enum.join(", ")

        IO.puts(
          IO.ANSI.red() <>
            "    Unknown preset: '#{preset_name}'. Available: #{available}" <>
            IO.ANSI.reset()
        )
    end
  end

  defp print_usage do
    IO.puts(
      IO.ANSI.yellow() <>
        "    Usage: /mode [basic|semi|full|pack]" <> IO.ANSI.reset()
    )

    IO.puts(
      "    #{IO.ANSI.faint()}Use /mode without arguments to see current mode#{IO.ANSI.reset()}"
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
