defmodule CodePuppyControl.CLI.SlashCommands.Commands.Rollout do
  @moduledoc """
  Gradual rollout management: /rollout [status|set <capability> <pct>|step-up <cap>|step-down <cap>].

  Manages percentage-based rollout for ADR-004 v1 feature flags, complementing
  the boolean toggle in `/feature-flags set` with precise integer 0..100 control
  and predefined step ladders.
  """

  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.FeatureFlags.Flags

  @rollout_steps [0, 5, 25, 50, 100]

  @usage "Usage: /rollout [status|set <capability> <0..100>|step-up <capability>|step-down <capability>]"

  @doc """
  Handles `/rollout` and its subcommands.

  Subcommands:
    /rollout                         — show rollout status for all capabilities
    /rollout status                  — show rollout status with progress bars
    /rollout set <cap> <pct>         — set rollout percentage (0..100)
    /rollout step-up <cap>           — bump to next rollout step
    /rollout step-down <cap>         — drop to previous rollout step
  """
  @spec handle_rollout(String.t(), any()) :: {:continue, any()}
  def handle_rollout(line, state) do
    line
    |> parse_args()
    |> run_command()

    {:continue, state}
  end

  # ── Subcommand handlers ─────────────────────────────────────────────────

  defp run_command([]), do: show_status()
  defp run_command(["status"]), do: show_status()
  defp run_command(["help"]), do: print_usage()
  defp run_command(["-h"]), do: print_usage()
  defp run_command(["--help"]), do: print_usage()

  defp run_command(["status" | _extra]) do
    print_error("Unexpected arguments for status. #{@usage}")
  end

  defp run_command(["set"]), do: print_error("Missing capability. #{@usage}")

  defp run_command(["set", cap_str]) do
    print_error("Missing percentage for capability \"#{cap_str}\". Use 0..100.")
  end

  defp run_command(["set", cap_str, raw_pct]) do
    set_percentage(cap_str, raw_pct)
  end

  defp run_command(["set" | _too_many]) do
    print_error("Too many arguments for set. #{@usage}")
  end

  defp run_command(["step-up"]), do: print_error("Missing capability. #{@usage}")

  defp run_command(["step-up", cap_str]) do
    step_ladder(:up, cap_str)
  end

  defp run_command(["step-up" | _too_many]) do
    print_error("Too many arguments for step-up. #{@usage}")
  end

  defp run_command(["step-down"]), do: print_error("Missing capability. #{@usage}")

  defp run_command(["step-down", cap_str]) do
    step_ladder(:down, cap_str)
  end

  defp run_command(["step-down" | _too_many]) do
    print_error("Too many arguments for step-down. #{@usage}")
  end

  defp run_command([unknown | _args]) do
    print_error("Unknown subcommand \"#{unknown}\". #{@usage}")
  end

  defp show_status do
    entries = FeatureFlags.list()

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> IO.ANSI.cyan() <> "    Rollout Status" <> IO.ANSI.reset())
    IO.puts("")

    Enum.each(entries, &print_rollout_row/1)

    IO.puts("")

    IO.puts(
      "    #{IO.ANSI.faint()}Use /rollout set <capability> <0..100> or step-up/step-down#{IO.ANSI.reset()}"
    )

    IO.puts("")
  end

  defp print_rollout_row({capability, _enabled, percentage, description}) do
    bar = progress_bar(percentage)
    pct_str = String.pad_leading(Integer.to_string(percentage), 3)

    IO.puts(
      "    #{IO.ANSI.bright()}#{String.pad_trailing(Atom.to_string(capability), 14)}" <>
        "#{IO.ANSI.reset()} #{bar} #{colorize_pct(percentage)}#{pct_str}%#{IO.ANSI.reset()}  " <>
        "#{IO.ANSI.faint()}#{description}#{IO.ANSI.reset()}"
    )
  end

  defp colorize_pct(0), do: IO.ANSI.faint()
  defp colorize_pct(pct) when pct > 0 and pct < 100, do: IO.ANSI.yellow()
  defp colorize_pct(100), do: IO.ANSI.green()

  defp set_percentage(raw_capability, raw_pct) do
    with {:ok, capability} <- Flags.resolve(raw_capability),
         {:ok, pct} <- parse_percentage(raw_pct),
         :ok <- FeatureFlags.set(capability, pct, source: :slash_command) do
      print_success("Rollout for #{capability} set to #{pct}%")
    else
      {:error, :unknown} ->
        print_error("Unknown capability \"#{raw_capability}\". Known: #{known_capabilities()}")

      {:error, {:invalid_pct, invalid}} ->
        print_error("Invalid percentage \"#{invalid}\". Use an integer 0..100.")

      {:error, reason} ->
        print_error("Failed to set rollout: #{format_error(reason)}")
    end
  end

  defp step_ladder(direction, raw_capability) do
    direction_label = if direction == :up, do: "up", else: "down"

    with {:ok, capability} <- Flags.resolve(String.trim(raw_capability)),
         current <- FeatureFlags.percentage(capability),
         next <- next_step(direction, current) do
      if next == current do
        print_info(
          "#{capability} already at #{(direction == :up && "maximum") || "minimum"} (#{current}%)"
        )
      else
        case FeatureFlags.set(capability, next, source: :slash_command) do
          :ok ->
            print_success(
              "Rollout for #{capability} stepped #{direction_label}: #{current}% → #{next}%"
            )

          {:error, reason} ->
            print_error(
              "Failed to step #{direction_label} #{capability}: #{format_error(reason)}"
            )
        end
      end
    else
      {:error, :unknown} ->
        print_error("Unknown capability \"#{raw_capability}\". Known: #{known_capabilities()}")
    end
  end

  defp next_step(:up, current) do
    Enum.find(@rollout_steps, 100, &(&1 > current))
  end

  defp next_step(:down, current) do
    @rollout_steps
    |> Enum.reverse()
    |> Enum.find(0, &(&1 < current))
  end

  @doc """
  Renders a progress bar string for the given percentage.

  ## Examples

      iex> CodePuppyControl.CLI.SlashCommands.Commands.Rollout.progress_bar(0)
      "[░░░░░░░░░░░░░░░░░░░░]"

      iex> CodePuppyControl.CLI.SlashCommands.Commands.Rollout.progress_bar(50)
      "[██████████░░░░░░░░░░]"

      iex> CodePuppyControl.CLI.SlashCommands.Commands.Rollout.progress_bar(100)
      "[████████████████████]"

      iex> CodePuppyControl.CLI.SlashCommands.Commands.Rollout.progress_bar(25, 10)
      "[██░░░░░░░░]"
  """
  @spec progress_bar(0..100, pos_integer()) :: String.t()
  def progress_bar(percentage, width \\ 20) do
    filled = round(percentage / 100 * width)
    empty = width - filled
    "[" <> String.duplicate("█", filled) <> String.duplicate("░", empty) <> "]"
  end

  # ── Parsing and formatting ───────────────────────────────────────────────

  defp parse_args("/" <> rest) do
    rest
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> case do
      [] -> []
      [_name] -> []
      [_name | args] -> normalize_subcommand(args)
    end
  end

  defp parse_args(_line), do: []

  defp normalize_subcommand([]), do: []

  defp normalize_subcommand([subcommand | rest]) do
    [String.downcase(subcommand) | rest]
  end

  defp parse_percentage(raw) do
    case Integer.parse(raw) do
      {pct, ""} when pct in 0..100 -> {:ok, pct}
      _other -> {:error, {:invalid_pct, raw}}
    end
  end

  defp known_capabilities do
    Flags.names()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join(", ")
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp print_success(msg) do
    IO.puts(IO.ANSI.green() <> "    ✓ #{msg}" <> IO.ANSI.reset())
  end

  defp print_error(msg) do
    IO.puts(IO.ANSI.red() <> "    ✗ #{msg}" <> IO.ANSI.reset())
  end

  defp print_info(msg) do
    IO.puts(IO.ANSI.cyan() <> "    ℹ #{msg}" <> IO.ANSI.reset())
  end

  defp print_usage do
    IO.puts(IO.ANSI.yellow() <> "    #{@usage}" <> IO.ANSI.reset())
  end
end
