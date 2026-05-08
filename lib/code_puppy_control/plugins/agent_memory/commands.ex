defmodule CodePuppyControl.Plugins.AgentMemory.Commands do
  @moduledoc """
  CLI command handlers for the /memory slash command.

  Subcommands: show, clear, export, help
  """

  alias CodePuppyControl.Plugins.AgentMemory.{Config, Storage}

  @doc "Handle /memory slash commands."
  @spec handle_command(String.t(), String.t()) :: true | nil
  def handle_command(command, name) do
    if name != "memory", do: nil, else: do_handle(command)
  end

  defp do_handle(command) do
    if not Config.enabled?() do
      IO.puts("🧠 Agent memory is disabled. Set memory_enabled=true in puppy.cfg to activate.")
      true
    else
      parts = String.split(command)
      subcommand = if length(parts) > 1, do: Enum.at(parts, 1), else: "help"

      case subcommand do
        "show" ->
          show_memories()

        "clear" ->
          clear_memories()

        "export" ->
          export_memories()

        "help" ->
          show_help()

        _ ->
          IO.puts("Unknown /memory subcommand: #{subcommand}")
          show_help()
      end

      true
    end
  end

  defp show_memories do
    agent_name = get_agent_name()

    if agent_name == nil do
      IO.puts("No active agent to show memories for")
    else
      facts = Storage.load(agent_name)

      if facts == [] do
        IO.puts("📭 No memories stored for #{agent_name}")
      else
        IO.puts("🧠 Memories for #{agent_name}:")

        Enum.each(Enum.with_index(facts, 1), fn {fact, idx} ->
          text = Map.get(fact, "text", "[invalid]")
          conf = Map.get(fact, "confidence", 1.0)
          IO.puts("  #{idx}. #{text} (#{round(conf * 100)}%)")
        end)
      end
    end
  end

  defp clear_memories do
    agent_name = get_agent_name()

    if agent_name == nil do
      IO.puts("No active agent to clear memories for")
    else
      count = Storage.fact_count(agent_name)

      if count == 0 do
        IO.puts("📭 No memories to clear for #{agent_name}")
      else
        Storage.clear(agent_name)

        IO.puts(
          "🗑️  Cleared #{count} #{if count == 1, do: "memory", else: "memories"} for #{agent_name}"
        )
      end
    end
  end

  defp export_memories do
    agent_name = get_agent_name()

    if agent_name == nil do
      IO.puts("No active agent to export memories for")
    else
      facts = Storage.load(agent_name)

      export = %{
        agent_name: agent_name,
        export_timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        fact_count: length(facts),
        facts: facts
      }

      IO.puts(Jason.encode!(export, pretty: true))
    end
  end

  defp show_help do
    IO.puts("""
    🧠 Agent Memory Commands

    /memory show     Display all stored memories for current agent
    /memory clear    Wipe all memories for the current agent
    /memory export   Export memories as formatted JSON
    /memory help     Show this help

    Configuration (puppy.cfg):
      memory_enabled = false          # OPT-IN, default off
      memory_max_facts = 50           # Max facts per agent
      memory_token_budget = 500       # Token budget for injection
    """)
  end

  @doc "Return help entries for the /help menu."
  @spec help_entries() :: [{String.t(), String.t()}]
  def help_entries do
    [{"memory", "Agent memory: /memory show|clear|export|help"}]
  end

  defp get_agent_name do
    Process.get(:current_agent_name) ||
      Application.get_env(:code_puppy_control, :current_agent_name)
  end
end
