defmodule CodePuppyControl.HookEngine.Aliases do
  @moduledoc """
  Tool name alias registry — maps each AI provider's tool names to code_puppy's
  internal tool names, enabling hooks written for any provider to fire correctly.

  Ported from `code_puppy/hook_engine/aliases.py`.

  ## Adding a new provider

  1. Add a new map following the pattern below.
  2. Register it in `provider_aliases/0`.
  3. That's it — the matcher picks it up automatically.
  """

  # ── Provider Aliases (module constants) ─────────────────────────

  @claude_code_aliases %{
    "Bash" => "agent_run_shell_command",
    "Glob" => "list_files",
    "Read" => "read_file",
    "Grep" => "grep",
    "Edit" => "replace_in_file",
    "Write" => "create_file",
    "Delete" => "delete_file",
    "AskUserQuestion" => "ask_user_question",
    "Task" => "invoke_agent",
    "Skill" => "activate_skill",
    "ToolSearch" => "list_or_search_skills"
  }

  @gemini_aliases %{}
  @codex_aliases %{}
  @swarm_aliases %{}

  @doc """
  Returns the master provider alias registry.

  To disable a provider's aliases, remove its entry from this map.
  """
  @spec provider_aliases() :: %{atom() => %{String.t() => String.t()}}
  def provider_aliases do
    %{
      claude: @claude_code_aliases,
      gemini: @gemini_aliases,
      codex: @codex_aliases,
      swarm: @swarm_aliases
    }
  end

  # ── Lazy-compiled lookup table ─────────────────────────────────
  # Built once on first call, then cached in a process dictionary or
  # Agent.  Using :persistent_term for zero-copy read performance.

  @lookup_key {__MODULE__, :lookup}

  @doc """
  Returns all known equivalent names for `tool_name` (including itself).

  Returns a MapSet containing only `tool_name` when no aliases exist.

  ## Examples

      iex> CodePuppyControl.HookEngine.Aliases.get_aliases("Bash")
      MapSet.new(["Bash", "agent_run_shell_command"])

      iex> CodePuppyControl.HookEngine.Aliases.get_aliases("unknown_tool")
      MapSet.new(["unknown_tool"])
  """
  @spec get_aliases(String.t()) :: MapSet.t(String.t())
  def get_aliases(tool_name) when is_binary(tool_name) do
    lookup = get_or_build_lookup()
    Map.get(lookup, String.downcase(tool_name), MapSet.new([tool_name]))
  end

  @doc """
  Returns the code_puppy internal tool name for a given provider tool name,
  or `nil` if the name is not a known provider alias.

  ## Examples

      iex> CodePuppyControl.HookEngine.Aliases.resolve_internal_name("Bash")
      "agent_run_shell_command"

      iex> CodePuppyControl.HookEngine.Aliases.resolve_internal_name("unknown")
      nil
  """
  @spec resolve_internal_name(String.t()) :: String.t() | nil
  def resolve_internal_name(provider_tool_name) when is_binary(provider_tool_name) do
    lower = String.downcase(provider_tool_name)

    Enum.find_value(provider_aliases(), fn {_provider, aliases} ->
      Enum.find_value(aliases, fn
        {pname, internal} ->
          if String.downcase(pname) == lower, do: internal, else: nil
      end)
    end)
  end

  @doc """
  Returns the internal-to-provider mapping (inverse lookup).
  Useful for diagnostics and testing.
  """
  @spec internal_to_provider_map() :: %{String.t() => [String.t()]}
  def internal_to_provider_map do
    Enum.reduce(provider_aliases(), %{}, fn {_provider, aliases}, acc ->
      Enum.reduce(aliases, acc, fn {pname, internal}, inner_acc ->
        Map.update(inner_acc, internal, [pname], fn existing -> [pname | existing] end)
      end)
    end)
  end

  # ── Private ─────────────────────────────────────────────────────

  # Build or retrieve the cached lookup table. Uses :persistent_term
  # for O(1) reads across all processes without ETS overhead.

  defp get_or_build_lookup do
    try do
      :persistent_term.get(@lookup_key)
    rescue
      ArgumentError ->
        lookup = build_lookup()
        :persistent_term.put(@lookup_key, lookup)
        lookup
    end
  end

  defp build_lookup do
    groups =
      Enum.reduce(provider_aliases(), %{}, fn {_provider, aliases}, acc ->
        Enum.reduce(aliases, acc, fn {pname, internal}, inner_acc ->
          key = String.downcase(internal)

          inner_acc
          |> Map.update(key, MapSet.new([internal, pname]), fn existing ->
            MapSet.put(existing, pname)
          end)
          |> Map.update(String.downcase(pname), MapSet.new([internal, pname]), fn existing ->
            MapSet.put(existing, pname)
          end)
        end)
      end)

    # Every name points to its full alias group
    Enum.reduce(groups, %{}, fn {_key, group}, acc ->
      Enum.reduce(group, acc, fn name, inner_acc ->
        Map.put(inner_acc, String.downcase(name), group)
      end)
    end)
  end

  @doc false
  # Reset the cached lookup (for tests)
  @spec reset_cache() :: :ok
  def reset_cache do
    try do
      :persistent_term.erase(@lookup_key)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
