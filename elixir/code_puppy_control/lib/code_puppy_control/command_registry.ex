defmodule CodePuppyControl.CommandRegistry do
  @moduledoc """
  Public API for slash command discovery, lookup, and autocomplete.

  Thin facade over `CodePuppyControl.CLI.SlashCommands.Registry` that
  provides the REST-facing interface for `CommandsController`.

  ## Design

  This module intentionally keeps no state — it delegates to the ETS-backed
  `SlashCommands.Registry` GenServer for all storage and retrieval. The only
  value-add here is:
  - A public API surface shaped for HTTP consumers (maps, not structs)
  - Autocomplete with fuzzy (Jaro-Winkler) scoring
  - Plugin `:custom_command_help` callback integration for extra commands

  ## Examples

      iex> CommandRegistry.list_commands()
      [%{name: "help", description: "Show available commands", ...}, ...]

      iex> CommandRegistry.get_command("help")
      {:ok, %{name: "help", ...}}

      iex> CommandRegistry.autocomplete("/he")
      [%{name: "help", ...}, %{name: "history", ...}]
  """

  alias CodePuppyControl.CLI.SlashCommands.Registry
  alias CodePuppyControl.Text.JaroWinkler

  @fuzzy_threshold 0.6

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Lists all registered commands (deduplicated by primary name).

  Returns a list of maps suitable for JSON serialization.
  """
  @spec list_commands() :: [map()]
  def list_commands do
    commands =
      Registry.list_all()
      |> Enum.map(&command_to_map/1)

    # Merge in plugin-contributed commands from `:custom_command_help` callbacks
    plugin_commands = collect_plugin_commands()
    commands ++ plugin_commands
  end

  @doc """
  Looks up a command by name or alias (case-insensitive).

  Returns `{:ok, map}` or `{:error, :not_found}`.
  """
  @spec get_command(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_command(name) when is_binary(name) do
    case Registry.get(name) do
      {:ok, cmd_info} ->
        {:ok, command_to_map(cmd_info)}

      {:error, :not_found} ->
        # Check plugin-contributed commands
        case find_plugin_command(name) do
          nil -> {:error, :not_found}
          cmd -> {:ok, cmd}
        end
    end
  end

  @doc """
  Autocomplete suggestions for a partial command string.

  Accepts the raw input (e.g. `"/he"`) and returns a sorted list of
  matching command maps, best match first.

  Matching strategy:
  1. Exact prefix match (sorted alphabetically)
  2. Fuzzy Jaro-Winkler scoring above `@fuzzy_threshold`

  Deduplicates so that aliases and primary names appear at most once.
  """
  @spec autocomplete(String.t()) :: [map()]
  def autocomplete(partial) when is_binary(partial) do
    # Strip leading "/" if present
    query =
      partial
      |> String.trim_leading("/")

    if query == "" do
      list_commands()
    else
      all = list_commands()
      query_lower = String.downcase(query)

      # Phase 1: exact prefix matches
      prefix_matches =
        all
        |> Enum.filter(fn cmd ->
          String.starts_with?(String.downcase(cmd.name), query_lower)
        end)
        |> Enum.sort_by(& &1.name)

      # Phase 2: fuzzy matches (skip commands already found by prefix)
      prefix_names = MapSet.new(Enum.map(prefix_matches, & &1.name))

      fuzzy_matches =
        all
        |> Enum.reject(fn cmd -> MapSet.member?(prefix_names, cmd.name) end)
        |> Enum.map(fn cmd ->
          score = JaroWinkler.similarity(query_lower, String.downcase(cmd.name))
          {cmd, score}
        end)
        |> Enum.filter(fn {_cmd, score} -> score >= @fuzzy_threshold end)
        |> Enum.sort_by(fn {_cmd, score} -> score end, :desc)
        |> Enum.map(fn {cmd, _score} -> cmd end)

      # Also include fuzzy matches on aliases
      alias_fuzzy =
        all
        |> Enum.reject(fn cmd ->
          MapSet.member?(prefix_names, cmd.name) or
            Enum.any?(fuzzy_matches, fn m -> m.name == cmd.name end)
        end)
        |> Enum.flat_map(fn cmd ->
          alias_scores =
            Enum.map(cmd.aliases || [], fn alias_name ->
              score = JaroWinkler.similarity(query_lower, String.downcase(alias_name))
              {cmd, score}
            end)

          best_alias_score =
            alias_scores
            |> Enum.filter(fn {_cmd, score} -> score >= @fuzzy_threshold end)
            |> case do
              [] -> nil
              filtered -> Enum.max_by(filtered, fn {_cmd, score} -> score end)
            end

          case best_alias_score do
            {cmd, score} -> [{cmd, score}]
            _ -> []
          end
        end)
        |> Enum.sort_by(fn {_cmd, score} -> score end, :desc)
        |> Enum.map(fn {cmd, _score} -> cmd end)

      (prefix_matches ++ fuzzy_matches ++ alias_fuzzy)
      |> Enum.uniq_by(& &1.name)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  @spec command_to_map(any()) :: map()
  defp command_to_map(cmd_info) do
    %{
      name: cmd_info.name,
      description: cmd_info.description,
      usage: cmd_info.usage || "/#{cmd_info.name}",
      aliases: cmd_info.aliases || [],
      category: cmd_info.category || "core",
      detailed_help: cmd_info.detailed_help
    }
  end

  # Collect commands contributed by plugin `:custom_command_help` callbacks.
  # Each callback should return a list of maps with at least "name" and
  # "description" keys.
  @spec collect_plugin_commands() :: [map()]
  defp collect_plugin_commands do
    try do
      CodePuppyControl.Callbacks.trigger_raw(:custom_command_help, [])
      |> Enum.flat_map(fn
        {:ok, commands} when is_list(commands) ->
          Enum.map(commands, &normalize_plugin_command/1)

        {:ok, %{} = cmd} ->
          [normalize_plugin_command(cmd)]

        _ ->
          []
      end)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  @spec normalize_plugin_command(map()) :: map()
  defp normalize_plugin_command(cmd) when is_map(cmd) do
    %{
      name: cmd[:name] || cmd["name"],
      description: cmd[:description] || cmd["description"] || "",
      usage: cmd[:usage] || cmd["usage"] || "/#{cmd[:name] || cmd["name"]}",
      aliases: cmd[:aliases] || cmd["aliases"] || [],
      category: cmd[:category] || cmd["category"] || "plugin",
      detailed_help: cmd[:detailed_help] || cmd["detailed_help"]
    }
  end

  @spec find_plugin_command(String.t()) :: map() | nil
  defp find_plugin_command(name) do
    name_lower = String.downcase(name)

    list_commands()
    |> Enum.find(fn cmd ->
      String.downcase(cmd.name) == name_lower or
        Enum.any?(cmd.aliases || [], fn a -> String.downcase(a) == name_lower end)
    end)
  end
end
