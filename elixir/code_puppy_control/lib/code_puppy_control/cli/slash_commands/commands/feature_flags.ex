defmodule CodePuppyControl.CLI.SlashCommands.Commands.FeatureFlags do
  @moduledoc """
  Feature flag slash command: /feature-flags [list|set <capability> <bool>|reload].

  Lists and manages the ADR-004 v1 Elixir rollout flags without overloading
  `/flags`, which intentionally remains WorkflowState-only.
  """

  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.FeatureFlags.Flags
  alias CodePuppyControl.RuntimeSelector.Status, as: RuntimeStatus

  @usage "Usage: /feature-flags [list|set <capability> <true|false>|reload]"

  @doc """
  Handles `/feature-flags` and its subcommands.

  Subcommands:
    /feature-flags                         — list all feature flags
    /feature-flags list                    — list all feature flags
    /feature-flags set <capability> <bool> — set a v1 capability
    /feature-flags reload                  — reload flags from disk
  """
  @spec handle_feature_flags(String.t(), any()) :: {:continue, any()}
  def handle_feature_flags(line, state) do
    line
    |> parse_args()
    |> run_command()

    {:continue, state}
  end

  # ── Subcommand handlers ─────────────────────────────────────────────────

  defp run_command([]), do: list_flags()
  defp run_command(["list"]), do: list_flags()
  defp run_command(["help"]), do: print_usage()
  defp run_command(["-h"]), do: print_usage()
  defp run_command(["--help"]), do: print_usage()
  defp run_command(["reload"]), do: reload_flags()

  defp run_command(["list" | _extra]) do
    print_error("Unexpected arguments for list. #{@usage}")
  end

  defp run_command(["reload" | _extra]) do
    print_error("Unexpected arguments for reload. #{@usage}")
  end

  defp run_command(["set"]), do: print_error("Missing capability. #{@usage}")

  defp run_command(["set", capability]) do
    print_error("Missing boolean value for capability \"#{capability}\". Use true/false.")
  end

  defp run_command(["set", capability, raw_bool]) do
    set_flag(capability, raw_bool)
  end

  defp run_command(["set" | _too_many]) do
    print_error("Too many arguments for set. #{@usage}")
  end

  defp run_command([unknown | _args]) do
    print_error("Unknown subcommand \"#{unknown}\". #{@usage}")
  end

  defp list_flags do
    entries = FeatureFlags.list()

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> IO.ANSI.cyan() <> "    Feature Flags" <> IO.ANSI.reset())
    IO.puts("")

    Enum.each(entries, &print_flag_row/1)

    IO.puts("")

    # Append runtime selector status summary
    print_runtime_status()

    IO.puts(
      "    #{IO.ANSI.faint()}Use /feature-flags set <capability> <true|false> to change a flag#{IO.ANSI.reset()}"
    )

    IO.puts("")
  end

  defp print_runtime_status do
    report = RuntimeStatus.report()

    mode_color =
      case report.mode do
        :elixir -> IO.ANSI.green()
        :python -> IO.ANSI.yellow()
        :auto -> IO.ANSI.cyan()
      end

    IO.puts(
      "    #{IO.ANSI.bright()}Runtime:#{IO.ANSI.reset()} #{mode_color}#{report.mode}#{IO.ANSI.reset()}"
    )

    if report.pup_runtime_env do
      IO.puts("    #{IO.ANSI.faint()}PUP_RUNTIME=#{report.pup_runtime_env}#{IO.ANSI.reset()}")
    end

    routing_lines =
      report.capabilities
      |> Enum.sort_by(fn {cap, _rt} -> cap end)
      |> Enum.map(fn {cap, rt} ->
        icon = if rt == :elixir, do: "◆", else: "◇"
        color = if rt == :elixir, do: IO.ANSI.green(), else: IO.ANSI.faint()

        "    #{icon} #{color}#{String.pad_trailing(Atom.to_string(cap), 14)}#{IO.ANSI.reset()} → #{rt}"
      end)

    Enum.each(routing_lines, &IO.puts/1)
    IO.puts("")
  end

  defp set_flag(raw_capability, raw_bool) do
    with {:ok, capability} <- Flags.resolve(raw_capability),
         {:ok, value} <- parse_bool(raw_bool),
         :ok <- FeatureFlags.set(capability, value, source: :slash_command) do
      print_success("Feature flag #{capability} set to #{value}")
    else
      {:error, :unknown} ->
        print_error(
          "Unknown capability \"#{raw_capability}\". Known capabilities: #{known_capabilities()}"
        )

      {:error, {:invalid_bool, invalid}} ->
        print_error("Invalid boolean \"#{invalid}\". Use true/false.")

      {:error, reason} ->
        print_error("Failed to set feature flag \"#{raw_capability}\": #{format_error(reason)}")
    end
  end

  defp reload_flags do
    case FeatureFlags.reload() do
      :ok -> print_success("Feature flags reloaded from disk")
      {:error, reason} -> print_error("Failed to reload feature flags: #{format_error(reason)}")
    end
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

  defp parse_bool(raw) do
    case String.downcase(raw) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, {:invalid_bool, raw}}
    end
  end

  defp print_flag_row({capability, true, description}) do
    IO.puts(
      "    ✓ #{IO.ANSI.green()}#{String.pad_trailing(to_string(capability), 12)}#{IO.ANSI.reset()} " <>
        "enabled  #{description}"
    )
  end

  defp print_flag_row({capability, false, description}) do
    IO.puts(
      "    ○ #{IO.ANSI.faint()}#{String.pad_trailing(to_string(capability), 12)}#{IO.ANSI.reset()} " <>
        "disabled #{IO.ANSI.faint()}#{description}#{IO.ANSI.reset()}"
    )
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

  defp print_usage do
    IO.puts(IO.ANSI.yellow() <> "    #{@usage}" <> IO.ANSI.reset())
  end
end
