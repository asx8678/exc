defmodule CodePuppyControl.Tool.Registry do
  @moduledoc """
  ETS-backed registry for tool modules.

  Provides fast concurrent reads for tool lookups with GenServer-serialized
  writes. Tools are stored as `%ToolEntry{}` structs in a named ETS table
  with `:set` type and `read_concurrency: true`.

  ## Usage

      # Register a tool module
      :ok = Registry.register(MyApp.Tools.Greeter)

      # Batch register
      {:ok, 3} = Registry.register_many([Tool.A, Tool.B, Tool.C])

      # Lookup by atom name
      {:ok, module} = Registry.lookup(:greeter)

      # List all tools for LLM consumption
      tools = Registry.all()
      # => [%{name: "greeter", description: "...", parameters: %{...}}, ...]

      # Filter for a specific agent
      agent_tools = Registry.for_agent(MyApp.Agents.ElixirDev)

  ## Supervision

  Started under `CodePuppyControl.Application` supervision tree.
  The ETS table is created in `init/1` for clean restart handling.
  """

  use GenServer

  require Logger

  @table :tool_registry

  # ── ToolEntry Struct ─────────────────────────────────────────────────────

  defmodule ToolEntry do
    @moduledoc """
    Entry stored in the tool registry ETS table.
    """

    @derive Jason.Encoder
    @enforce_keys [:name, :module, :description, :parameters]
    defstruct [:name, :module, :description, :parameters]

    @type t :: %__MODULE__{
            name: atom(),
            module: module(),
            description: String.t(),
            parameters: map()
          }

    @doc "Creates a new ToolEntry from a tool module."
    @spec from_module(module()) :: t()
    def from_module(tool_module) when is_atom(tool_module) do
      %__MODULE__{
        name: tool_module.name(),
        module: tool_module,
        description: tool_module.description(),
        parameters: tool_module.parameters()
      }
    end
  end

  # ── Client API ───────────────────────────────────────────────────────────

  @doc """
  Starts the Tool Registry GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a tool module in the registry.

  The module must implement `CodePuppyControl.Tool` behaviour callbacks
  (`name/0`, `description/0`, `parameters/0`).

  ## Examples

      iex> Registry.register(MyApp.Tools.Greeter)
      :ok
  """
  @spec register(module()) :: :ok
  def register(tool_module) when is_atom(tool_module) do
    GenServer.call(__MODULE__, {:register, tool_module})
  end

  @doc """
  Batch registers multiple tool modules.

  ## Returns

  `{:ok, count}` where count is the number of tools registered.

  ## Examples

      iex> Registry.register_many([Tool.A, Tool.B, Tool.C])
      {:ok, 3}
  """
  @spec register_many([module()]) :: {:ok, non_neg_integer()}
  def register_many(modules) when is_list(modules) do
    GenServer.call(__MODULE__, {:register_many, modules})
  end

  @doc """
  Looks up a tool by its atom name.

  Returns `{:ok, module}` if found, `:error` if not registered.

  ## Examples

      iex> Registry.lookup(:greeter)
      {:ok, MyApp.Tools.Greeter}

      iex> Registry.lookup(:nonexistent)
      :error
  """
  @spec lookup(atom()) :: {:ok, module()} | :error
  def lookup(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, entry}] -> {:ok, entry.module}
      [] -> :error
    end
  end

  @doc """
  Lists all registered tools as maps for LLM consumption.

  Each entry includes `:name`, `:description`, and `:parameters`.

  ## Examples

      iex> Registry.all()
      [%{name: "greeter", description: "Greets users", parameters: %{}}, ...]
  """
  @spec all() :: [map()]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, entry} -> entry_to_map(entry) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Filters registered tools by an agent's allowed_tools list.

  The agent's `allowed_tools/0` returns a list of atom tool names.
  This function returns only the registered tools matching those names.

  ## Examples

      iex> Registry.for_agent(MyApp.Agents.ElixirDev)
      [%{name: "command_runner", ...}, ...]
  """
  @spec for_agent(module()) :: [map()]
  def for_agent(agent_module) when is_atom(agent_module) do
    if function_exported?(agent_module, :allowed_tools, 0) do
      allowed = MapSet.new(agent_module.allowed_tools())

      @table
      |> :ets.tab2list()
      |> Enum.filter(fn {name, _entry} -> MapSet.member?(allowed, name) end)
      |> Enum.map(fn {_name, entry} -> entry_to_map(entry) end)
      |> Enum.sort_by(& &1.name)
    else
      all()
    end
  end

  @doc """
  Returns the list of all registered tool modules.

  Useful for introspection and debugging.
  """
  @spec list_modules() :: [module()]
  def list_modules do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, entry} -> entry.module end)
    |> Enum.sort()
  end

  @doc """
  Returns the number of registered tools.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  @doc """
  Returns true if a tool with the given name is registered.
  """
  @spec registered?(atom()) :: boolean()
  def registered?(name) when is_atom(name) do
    :ets.member(@table, name)
  end

  @doc """
  Unregisters a tool by name.

  Returns `:ok` regardless of whether the tool was registered.
  """
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc """
  Removes all tools from the registry.

  Primarily useful for testing.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # ── Server Callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Auto-discover and register built-in tools
    builtin_tools = discover_builtin_tools()

    for tool_module <- builtin_tools do
      entry = ToolEntry.from_module(tool_module)
      :ets.insert(table, {entry.name, entry})
    end

    # Auto-discover and register :cp_-prefixed tool wrappers
    # These expose the same functionality under agent-facing names
    # used by CodePuppyControl.Agents.CodePuppy.allowed_tools/0.
    cp_tools = discover_cp_tools()

    for tool_module <- cp_tools do
      entry = ToolEntry.from_module(tool_module)
      :ets.insert(table, {entry.name, entry})
    end

    total = length(builtin_tools) + length(cp_tools)

    Logger.info(
      "Tool.Registry started with #{total} tools " <>
        "(#{length(builtin_tools)} builtin, #{length(cp_tools)} cp_): " <>
        inspect(Enum.map(builtin_tools ++ cp_tools, & &1.name()))
    )

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, tool_module}, _from, state) do
    entry = ToolEntry.from_module(tool_module)
    :ets.insert(@table, {entry.name, entry})
    Logger.debug("Tool.Registry: registered #{entry.name} -> #{inspect(tool_module)}")
    {:reply, :ok, state}
  rescue
    e ->
      Logger.warning(
        "Tool.Registry: failed to register #{inspect(tool_module)}: #{Exception.message(e)}"
      )

      {:reply, {:error, Exception.message(e)}, state}
  end

  @impl true
  def handle_call({:register_many, modules}, _from, state) do
    count =
      Enum.reduce(modules, 0, fn tool_module, acc ->
        try do
          entry = ToolEntry.from_module(tool_module)
          :ets.insert(@table, {entry.name, entry})
          acc + 1
        rescue
          e ->
            Logger.warning(
              "Tool.Registry: failed to register #{inspect(tool_module)}: #{Exception.message(e)}"
            )

            acc
        end
      end)

    Logger.debug("Tool.Registry: batch registered #{count}/#{length(modules)} tools")
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(@table, name)
    Logger.debug("Tool.Registry: unregistered #{name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    Logger.debug("Tool.Registry: cleared all tools")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Tool.Registry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Private Helpers ──────────────────────────────────────────────────────

  defp entry_to_map(%ToolEntry{} = entry) do
    %{
      name: to_string(entry.name),
      description: entry.description,
      parameters: entry.parameters
    }
  end

  @doc false
  # Discovers built-in tool modules that implement the Tool behaviour.
  # Scans known namespaces for modules with name/0 callback.
  defp discover_builtin_tools do
    candidates = [
      CodePuppyControl.Tools.CommandRunner,
      CodePuppyControl.Tools.AgentCatalogue,
      CodePuppyControl.Tools.FileModifications.CreateFile,
      CodePuppyControl.Tools.FileModifications.ReplaceInFile,
      CodePuppyControl.Tools.FileModifications.EditFile,
      CodePuppyControl.Tools.FileModifications.DeleteFile,
      CodePuppyControl.Tools.FileModifications.DeleteSnippet,
      CodePuppyControl.Tools.Skills.ListSkills,
      CodePuppyControl.Tools.Skills.ActivateSkill,
      CodePuppyControl.Tools.SubagentContext.GetContext,
      CodePuppyControl.Tools.SubagentContext.PushContext,
      CodePuppyControl.Tools.SubagentContext.PopContext,
      # Staged change tools are SLASH-ONLY — not exposed to agents.
      # See code-puppy-ctj.5 decision: staging is a user-review mechanism.
      # Register via StagedChanges.register_all/0 for testing only.
      CodePuppyControl.Tools.ProcessRunner.ListProcesses,
      CodePuppyControl.Tools.ProcessRunner.KillProcess,
      CodePuppyControl.Tools.ProcessRunner.KillAllProcesses
    ]

    Enum.filter(candidates, fn mod ->
      Code.ensure_loaded?(mod) and
        function_exported?(mod, :name, 0) and
        function_exported?(mod, :description, 0) and
        function_exported?(mod, :parameters, 0)
    end)
  end

  @doc false
  # Discovers :cp_-prefixed tool modules that implement the Tool behaviour.
  # These are the agent-facing tool names used by
  # CodePuppyControl.Agents.CodePuppy.allowed_tools/0.
  #
  # Refs: code_puppy-4s8.7 (Phase C CI gate)
  defp discover_cp_tools do
    candidates = [
      CodePuppyControl.Tools.CpFileOps.CpListFiles,
      CodePuppyControl.Tools.CpFileOps.CpReadFile,
      CodePuppyControl.Tools.CpFileOps.CpGrep,
      CodePuppyControl.Tools.CpShell.CpRunCommand,
      CodePuppyControl.Tools.CpAgentOps.CpInvokeAgent,
      CodePuppyControl.Tools.CpAgentOps.CpListAgents,
      CodePuppyControl.Tools.CpFileMods.CpCreateFile,
      CodePuppyControl.Tools.CpFileMods.CpReplaceInFile,
      CodePuppyControl.Tools.CpFileMods.CpEditFile,
      CodePuppyControl.Tools.CpFileMods.CpDeleteFile,
      CodePuppyControl.Tools.CpFileMods.CpDeleteSnippet,
      CodePuppyControl.Tools.CpAskUserQuestion,
      # Phase E: skills, scheduler, universal constructor (code_puppy-mmk.2)
      CodePuppyControl.Tools.CpSkillOps.CpListSkills,
      CodePuppyControl.Tools.CpSkillOps.CpActivateSkill,
      CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerListTasks,
      CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerCreateTask,
      CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerDeleteTask,
      CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerToggleTask,
      CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerStatus,
      CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerRunTask,
      CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerViewLog,
      CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerForceCheck,
      CodePuppyControl.Tools.CpUniversalConstructor
    ]

    Enum.filter(candidates, fn mod ->
      Code.ensure_loaded?(mod) and
        function_exported?(mod, :name, 0) and
        function_exported?(mod, :description, 0) and
        function_exported?(mod, :parameters, 0)
    end)
  end
end
