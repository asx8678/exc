defmodule CodePuppyControl.CLI.SlashCommands.Registry do
  @moduledoc """
  ETS-backed registry for slash commands.

  Provides fast concurrent reads for command lookups with GenServer-serialized
  writes. Commands are stored as `%CommandInfo{}` structs, keyed by both
  primary name and aliases in a named ETS table.

  ## Usage

      # Register a command
      :ok = Registry.register(%CommandInfo{name: "help", ...})

      # Lookup by name (case-insensitive)
      {:ok, cmd} = Registry.get("help")

      # List all unique commands (no alias duplicates)
      commands = Registry.list_all()

  ## Supervision

  Started under `CodePuppyControl.Application` supervision tree.
  The ETS table is created in `init/1` for clean restart handling.
  """

  use GenServer

  alias CodePuppyControl.CLI.SlashCommands.CommandInfo

  @table :slash_commands

  # ── Client API ───────────────────────────────────────────────────────────

  @doc """
  Starts the Slash Commands Registry GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a command and all its aliases.

  Returns `:ok` on success, or `{:error, {:name_conflict, conflicting_name}}`
  if the primary name or any alias is already registered. Does NOT silently
  overwrite — unlike Python's latent-bug behaviour.
  """
  @spec register(CommandInfo.t()) :: :ok | {:error, {:name_conflict, String.t()}}
  def register(%CommandInfo{} = cmd_info) do
    GenServer.call(__MODULE__, {:register, cmd_info})
  end

  @doc """
  Looks up a command by name or alias (case-insensitive).

  Tries exact match first, then falls back to case-insensitive matching.
  """
  @spec get(String.t()) :: {:ok, CommandInfo.t()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, cmd_info}] ->
        {:ok, cmd_info}

      [] ->
        # Case-insensitive fallback
        name_lower = String.downcase(name)

        try do
          match = :ets.match_object(@table, {:"$1", :_})

          case Enum.find(match, fn {key, _} ->
                 String.downcase(key) == name_lower
               end) do
            {_, cmd_info} -> {:ok, cmd_info}
            nil -> {:error, :not_found}
          end
        rescue
          _ -> {:error, :not_found}
        end
    end
  end

  @doc """
  Returns all unique commands (deduplicated by primary name).

  Aliases point to the same CommandInfo, so only one entry per command
  is returned.
  """
  @spec list_all() :: [CommandInfo.t()]
  def list_all do
    try do
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_, cmd_info} -> cmd_info end)
      |> Enum.uniq_by(& &1.name)
    rescue
      _ -> []
    end
  end

  @doc """
  Returns commands filtered by category.
  """
  @spec list_by_category(String.t()) :: [CommandInfo.t()]
  def list_by_category(category) when is_binary(category) do
    list_all()
    |> Enum.filter(&(&1.category == category))
  end

  @doc """
  Clears all registered commands. Primarily for test use.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Returns all registered names AND aliases. Useful for tab completion.
  """
  @spec all_names() :: [String.t()]
  def all_names do
    try do
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {key, _} -> key end)
    rescue
      _ -> []
    end
  end

  @doc """
  Registers all built-in slash commands.

  Called from `CodePuppyControl.Application.start/2` after the supervision
  tree is up. Must NOT be called from `init/1` to keep the startup sequence
  testable and resilient.
  """
  @spec register_builtin_commands() :: :ok
  def register_builtin_commands do
    alias CodePuppyControl.CLI.SlashCommands.Commands

    builtins = [
      # Core commands
      CommandInfo.new(
        name: "help",
        description: "Show available commands",
        handler: &Commands.Core.handle_help/2,
        category: "core"
      ),
      CommandInfo.new(
        name: "quit",
        description: "Exit the REPL",
        handler: &Commands.Core.handle_quit/2,
        category: "core"
      ),
      CommandInfo.new(
        name: "exit",
        description: "Exit the REPL (alias for /quit)",
        handler: &Commands.Core.handle_quit/2,
        aliases: [],
        category: "core"
      ),
      CommandInfo.new(
        name: "clear",
        description: "Clear the terminal screen",
        handler: &Commands.Core.handle_clear/2,
        category: "core"
      ),
      CommandInfo.new(
        name: "history",
        description: "Show command history",
        handler: &Commands.Core.handle_history/2,
        category: "core"
      ),
      CommandInfo.new(
        name: "cd",
        description: "Change working directory",
        handler: &Commands.Core.handle_cd/2,
        usage: "/cd <dir>",
        category: "core"
      ),
      # Context commands
      CommandInfo.new(
        name: "model",
        description: "Show or switch the current model",
        handler: &Commands.Context.handle_model/2,
        usage: "/model [name]",
        category: "context"
      ),
      CommandInfo.new(
        name: "agent",
        description: "Show or switch the current agent",
        handler: &Commands.Context.handle_agent/2,
        usage: "/agent [name]",
        category: "context"
      ),
      CommandInfo.new(
        name: "sessions",
        description: "Browse and switch sessions",
        handler: &Commands.Context.handle_sessions/2,
        usage: "/sessions [filter]",
        category: "context"
      ),
      CommandInfo.new(
        name: "tui",
        description: "Launch full TUI interface",
        handler: &Commands.Context.handle_tui/2,
        category: "context"
      ),
      CommandInfo.new(
        name: "agents",
        description: "List agents and manage model pins",
        handler: &Commands.Agents.handle_agents/2,
        usage: "/agents [pin|unpin <agent>]",
        category: "context",
        detailed_help:
          "View all agents with their pinned models. Use '/agents pin <name>' to interactively select a model to pin to an agent."
      ),
      CommandInfo.new(
        name: "pack",
        description: "Show or switch model pack",
        handler: &Commands.Pack.handle_pack/2,
        usage: "/pack [pack_name]",
        category: "context"
      ),
      CommandInfo.new(
        name: "mode",
        description: "Show or switch configuration preset (basic/semi/full/pack)",
        handler: &Commands.Mode.handle_mode/2,
        usage: "/mode [preset_name]",
        category: "context"
      ),
      CommandInfo.new(
        name: "uc",
        description: "Browse and manage Universal Constructor tools",
        handler: &Commands.UC.handle_uc/2,
        usage: "/uc [toggle <name> | info <name>]",
        aliases: ["universal_constructor"],
        category: "context",
        detailed_help:
          "List, toggle, and inspect UC tools. Use '/uc' to list all tools, '/uc toggle <name>' to enable/disable, '/uc info <name>' for details."
      ),
      CommandInfo.new(
        name: "flags",
        description: "Show current workflow flags and state",
        handler: &Commands.Flags.handle_flags/2,
        usage: "/flags [reset|set <flag>|clear <flag>]",
        category: "config"
      ),
      CommandInfo.new(
        name: "diff",
        description: "Show or configure diff highlighting colors",
        handler: &Commands.Diff.handle_diff/2,
        usage: "/diff [additions|deletions] <color>",
        category: "config"
      ),
      # Model settings commands (read-only summary; interactive editor is )
      CommandInfo.new(
        name: "model_settings",
        description: "Show per-model settings (temperature, seed, etc.)",
        handler: &Commands.ModelSettings.handle_model_settings/2,
        usage: "/model_settings --show [model_name]",
        aliases: ["ms"],
        category: "config",
        detailed_help:
          "Display per-model settings like temperature, seed, top_p, reasoning effort, etc. Use --show with an optional model name to view settings. The interactive editor will be added in a future release."
      ),
      # MCP commands
      CommandInfo.new(
        name: "mcp",
        description: "Show MCP server status and management",
        handler: &Commands.MCP.handle_mcp/2,
        usage: "/mcp [help|list|status|start|stop|restart|start-all|stop-all]",
        category: "mcp",
        detailed_help:
          "View and manage MCP servers. Subcommands: list, help, status, start, stop, restart, start-all, stop-all."
      ),
      # Add Model command
      CommandInfo.new(
        name: "add_model",
        description: "Browse and add models from models.dev catalog",
        handler: &Commands.AddModel.handle_add_model/2,
        usage: "/add_model",
        category: "context",
        detailed_help:
          "Interactively browse providers and models from the models.dev catalog. Select a model to add it to your extra_models.json configuration, making it immediately available for use."
      ),
      # Session commands
      CommandInfo.new(
        name: "compact",
        description: "Compact conversation history (stub)",
        handler: &Commands.Session.handle_compact/2,
        category: "session",
        detailed_help:
          "Summarizes and compacts the conversation history to reduce context length. Depends on agent summarization port."
      ),
      CommandInfo.new(
        name: "truncate",
        description: "Truncate conversation to last N messages (stub)",
        handler: &Commands.Session.handle_truncate/2,
        usage: "/truncate <N>",
        category: "session",
        detailed_help:
          "Trims the agent's message history to the last N messages. Depends on agent message history port."
      ),
      CommandInfo.new(
        name: "autosave_load",
        description: "Load the most recent autosaved session",
        handler: &Commands.AutosaveLoad.handle_autosave_load/2,
        usage: "/autosave_load",
        aliases: ["resume"],
        category: "session",
        detailed_help:
          "Loads the most recent autosaved session into the current REPL state. If multiple autosaves exist, shows a numbered list and loads the most recent one by default, or lets you pick by number. Alias: /resume."
      ),
      # Staged changes command
      CommandInfo.new(
        name: "staged",
        description: "Show or manage staged changes for safe edit application",
        handler: &Commands.Staged.handle_staged/2,
        usage: "/staged [on|off|diff|preview|clear|apply|reject|save|load|status]",
        category: "edit",
        detailed_help:
          "View and manage staged file changes. Staging mode intercepts file edits for review before applying. Subcommands: on, off, diff, preview, clear, apply, reject, save, load, status."
      )
    ]

    # Register /quit's alias: /exit points to the quit handler
    # We register /exit as its own command that shares the quit handler.
    # The alias relationship is: /exit is a separate command that acts like /quit.
    # In the Python codebase, /exit is a registered alias of /quit.

    Enum.each(builtins, fn cmd_info ->
      case register(cmd_info) do
        :ok ->
          :ok

        {:error, {:name_conflict, name}} ->
          require Logger
          Logger.warning("Slash command already registered: #{name}, skipping")
      end
    end)

    # Register /exit as an alias of /quit
    case get("quit") do
      {:ok, quit_info} ->
        # Add "exit" as an alias key pointing to the quit CommandInfo
        GenServer.call(__MODULE__, {:register_alias, "exit", quit_info})

      {:error, :not_found} ->
        :ok
    end

    :ok
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, %CommandInfo{} = cmd_info}, _from, state) do
    # Check for conflicts on primary name + all aliases
    all_keys = [cmd_info.name | cmd_info.aliases]

    conflict =
      Enum.find(all_keys, fn key ->
        :ets.member(@table, key)
      end)

    case conflict do
      nil ->
        # No conflicts — insert primary name + all aliases
        Enum.each(all_keys, fn key ->
          :ets.insert(@table, {key, cmd_info})
        end)

        {:reply, :ok, state}

      name ->
        {:reply, {:error, {:name_conflict, name}}, state}
    end
  end

  @impl true
  def handle_call({:register_alias, alias_name, cmd_info}, _from, state) do
    if :ets.member(@table, alias_name) do
      {:reply, {:error, {:name_conflict, alias_name}}, state}
    else
      :ets.insert(@table, {alias_name, cmd_info})
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
