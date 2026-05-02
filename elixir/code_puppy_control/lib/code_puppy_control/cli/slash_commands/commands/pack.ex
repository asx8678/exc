defmodule CodePuppyControl.CLI.SlashCommands.Commands.Pack do
  @moduledoc """
  Pack slash command: /pack [pack_name].

  Shows current model pack and available packs, or switches to a named pack.
  Ports the Python /pack command from code_puppy/command_line/pack_commands.py.
  """

  alias CodePuppyControl.ModelPacks

  @doc """
  Handles `/pack` — shows current pack and available packs.

  Handles `/pack <name>` — switches to the named pack and shows confirmation.
  """
  @spec handle_pack(String.t(), any()) :: {:continue, any()}
  def handle_pack(line, state) do
    case extract_args(line) |> String.trim() do
      "" ->
        show_current_pack()

      args ->
        pack_name = String.downcase(args)

        if String.contains?(pack_name, " ") do
          print_usage()
        else
          switch_pack(pack_name)
        end
    end

    {:continue, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp show_current_pack do
    current = ModelPacks.get_current_pack()
    packs = ModelPacks.list_packs()

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "    Model Pack" <> IO.ANSI.reset())
    IO.puts("")
    IO.puts("    Current pack: #{IO.ANSI.cyan()}#{current.name}#{IO.ANSI.reset()}")
    IO.puts("    #{IO.ANSI.faint()}#{current.description}#{IO.ANSI.reset()}")
    IO.puts("")

    if map_size(current.roles) > 0 do
      IO.puts("    Current role configuration:")

      current.roles
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.each(fn {role_name, role_config} ->
        chain = format_chain(role_config)
        marker = if role_name == current.default_role, do: "→ ", else: "  "

        IO.puts(
          "    #{marker}#{IO.ANSI.cyan()}#{String.pad_trailing(role_name, 12)}#{IO.ANSI.reset()} #{chain}"
        )
      end)

      IO.puts("")
    end

    IO.puts("    Available packs:")

    Enum.each(packs, fn pack ->
      marker = if pack.name == current.name, do: "→ ", else: "  "

      IO.puts(
        "    #{marker}#{IO.ANSI.cyan()}#{String.pad_trailing(pack.name, 12)}#{IO.ANSI.reset()} " <>
          "#{IO.ANSI.faint()}#{pack.description}#{IO.ANSI.reset()}"
      )
    end)

    IO.puts("")
    IO.puts("    #{IO.ANSI.faint()}Use /pack <name> to switch packs#{IO.ANSI.reset()}")
    IO.puts("")
  end

  defp switch_pack(pack_name) do
    case ModelPacks.set_current_pack(pack_name) do
      :ok ->
        pack = ModelPacks.get_pack(pack_name)

        IO.puts("")
        IO.puts("    Switched to pack: #{IO.ANSI.cyan()}#{pack.name}#{IO.ANSI.reset()}")
        IO.puts("    #{IO.ANSI.faint()}#{pack.description}#{IO.ANSI.reset()}")
        IO.puts("")

        if map_size(pack.roles) > 0 do
          IO.puts("    Role configuration:")

          pack.roles
          |> Enum.sort_by(fn {name, _} -> name end)
          |> Enum.each(fn {role_name, role_config} ->
            chain = format_chain(role_config)

            IO.puts(
              "      #{IO.ANSI.cyan()}#{String.pad_trailing(role_name, 12)}#{IO.ANSI.reset()} #{chain}"
            )
          end)

          IO.puts("")
        end

      {:error, :not_found} ->
        available = ModelPacks.list_packs() |> Enum.map(& &1.name) |> Enum.join(", ")

        IO.puts(
          IO.ANSI.red() <>
            "    Unknown pack: '#{pack_name}'. Available: #{available}" <>
            IO.ANSI.reset()
        )
    end
  end

  defp print_usage do
    IO.puts(
      IO.ANSI.yellow() <>
        "    Usage: /pack [pack_name]" <> IO.ANSI.reset()
    )

    IO.puts(
      "    #{IO.ANSI.faint()}Use /pack without arguments to see current pack#{IO.ANSI.reset()}"
    )
  end

  defp format_chain(role_config) do
    primary = role_config.primary
    fallbacks = role_config.fallbacks || []

    if fallbacks == [] do
      primary
    else
      # Show at most 2 fallbacks inline, like the Python version
      {shown, extra} =
        case fallbacks do
          [a, b | rest] -> {[a, b], length(rest)}
          list -> {list, 0}
        end

      chain = Enum.join([primary | shown], " → ")

      if extra > 0 do
        "#{chain} (+#{extra} more)"
      else
        chain
      end
    end
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
