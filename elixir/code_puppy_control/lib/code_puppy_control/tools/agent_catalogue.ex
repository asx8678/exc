defmodule CodePuppyControl.Tools.AgentCatalogue do
  @moduledoc """
  Agent catalogue service for CodePuppy.

  This module maintains a registry of available agents with their metadata:
  - name: The internal agent identifier (e.g., "code_puppy")
  - display_name: Human-readable name (e.g., "Code Puppy")
  - description: What this agent does
  - module: The agent behaviour module (e.g., `CodePuppyControl.Agents.CodePuppy`)

  ## Purpose

  - Provides discovery of available sub-agents
  - Enables introspection of agent capabilities
  - Integrates with the JSON-RPC transport for agent listing
  - Auto-discovers agent modules implementing `CodePuppyControl.Agent.Behaviour`

  ## Storage

  Uses ETS for fast concurrent reads and GenServer-coordinated writes.
  The ETS table is `:set` type with `agent_name -> agent_info` mapping.

  ## API

  - `register_agent/3` - Register an agent with the catalogue
  - `list_agents/0` - List all registered agents
  - `get_agent_info/1` - Get info about a specific agent
  - `get_agent_module/1` - Get the module for a given agent name
  - `discover_agent_modules/0` - Find all modules implementing Agent.Behaviour
  - `unregister_agent/1` - Remove an agent from the catalogue
  - `clear_catalogue/0` - Clear all registered agents

  ## RPC Methods

  The stdio service exposes these JSON-RPC methods:
  - `agent.list` - List all available agents
  - `agent.get_info` - Get info about a specific agent
  """

  use GenServer

  require Logger

  alias __MODULE__.AgentInfo

  @table :agent_catalogue

  @typedoc "Agent information record"
  @type agent_info :: %AgentInfo{
          name: String.t(),
          display_name: String.t(),
          description: String.t(),
          module: module() | nil
        }

  # ============================================================================
  # AgentInfo Struct
  # ============================================================================

  defmodule AgentInfo do
    @moduledoc """
    Information about an available agent.

    Fields:
    - `name`: The internal agent identifier (e.g., "code_puppy")
    - `display_name`: Human-readable name (e.g., "Code Puppy")
    - `description`: What this agent does
    - `module`: The agent behaviour module, or `nil` for manually registered agents
    """

    @derive Jason.Encoder
    defstruct [:name, :display_name, :description, :module]

    @type t :: %__MODULE__{
            name: String.t(),
            display_name: String.t(),
            description: String.t(),
            module: module() | nil
          }

    @doc """
    Creates a new AgentInfo struct.
    """
    @spec new(String.t(), String.t(), String.t(), module() | nil) :: t()
    def new(name, display_name, description, module \\ nil) do
      %__MODULE__{
        name: name,
        display_name: display_name,
        description: description,
        module: module
      }
    end
  end

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the AgentCatalogue GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers an agent with the catalogue.

  ## Parameters
  - `name`: The internal agent identifier (e.g., "elixir-dev")
  - `display_name`: Human-readable name (e.g., "Elixir Developer")
  - `description`: What this agent does

  ## Returns
  - `:ok` on success

  ## Examples

      iex> AgentCatalogue.register_agent("elixir-dev", "Elixir Developer", "Elixir/OTP expert")
      :ok
  """
  @spec register_agent(String.t(), String.t(), String.t()) :: :ok
  def register_agent(name, display_name, description)
      when is_binary(name) and is_binary(display_name) and is_binary(description) do
    GenServer.call(__MODULE__, {:register, name, display_name, description})
  end

  @doc """
  Lists all registered agents.

  ## Returns
  - List of AgentInfo structs

  ## Examples

      iex> AgentCatalogue.list_agents()
      [%AgentInfo{name: "code_puppy", display_name: "Code Puppy", ...}]
  """
  @spec list_agents() :: list(agent_info())
  def list_agents do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, info} -> info end)
    |> Enum.sort_by(fn info -> info.name end)
  end

  @doc """
  Gets information about a specific agent.

  ## Parameters
  - `name`: The agent identifier (string or atom)

  ## Returns
  - `{:ok, AgentInfo}` if found
  - `:not_found` if agent is not registered

  ## Examples

      iex> AgentCatalogue.get_agent_info("code_puppy")
      {:ok, %AgentInfo{name: "code_puppy", ...}}

      iex> AgentCatalogue.get_agent_info(:code_puppy)
      {:ok, %AgentInfo{name: "code_puppy", ...}}

      iex> AgentCatalogue.get_agent_info("unknown")
      :not_found
  """
  @spec get_agent_info(String.t() | atom()) :: {:ok, agent_info()} | :not_found
  def get_agent_info(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, info}] -> {:ok, info}
      [] -> :not_found
    end
  end

  def get_agent_info(name) when is_atom(name) do
    get_agent_info(to_string(name))
  end

  @doc """
  Gets the module implementing `Agent.Behaviour` for a given agent name.

  This is the primary lookup used when dispatching to an agent — it maps
  from the agent's atom name (e.g., `:code_puppy`) to the module that
  implements the behaviour callbacks.

  ## Parameters
  - `name`: The agent identifier (atom or string)

  ## Returns
  - `{:ok, module}` if found and the agent has a backing module
  - `:not_found` if the agent name is not in the catalogue
  - `{:error, :no_module}` if the agent was registered manually without a module

  ## Examples

      iex> AgentCatalogue.get_agent_module(:code_puppy)
      {:ok, CodePuppyControl.Agents.CodePuppy}

      iex> AgentCatalogue.get_agent_module("pack_leader")
      {:ok, CodePuppyControl.Agents.PackLeader}

      iex> AgentCatalogue.get_agent_module(:unknown)
      :not_found
  """
  @spec get_agent_module(atom() | String.t()) ::
          {:ok, module()} | :not_found | {:error, :no_module}
  def get_agent_module(name) when is_atom(name) do
    case get_agent_info(name) do
      {:ok, %{module: mod}} when is_atom(mod) and not is_nil(mod) -> {:ok, mod}
      {:ok, %{module: nil}} -> {:error, :no_module}
      :not_found -> :not_found
    end
  end

  def get_agent_module(name) when is_binary(name) do
    case get_agent_info(name) do
      {:ok, %{module: mod}} when is_atom(mod) and not is_nil(mod) -> {:ok, mod}
      {:ok, %{module: nil}} -> {:error, :no_module}
      :not_found -> :not_found
    end
  end

  @doc """
  Discovers all modules implementing `CodePuppyControl.Agent.Behaviour`
  in the `CodePuppyControl.Agents` namespace.

  Uses `:application.get_key/2` to enumerate all compiled modules in the
  `:code_puppy_control` application, then filters for those that:
  1. Are in the `CodePuppyControl.Agents` namespace
  2. Export `name/0` and `system_prompt/1` (the core behaviour callbacks)

  ## Returns
  - List of `{module, name_atom, display_name, description}` tuples

  ## Examples

      iex> AgentCatalogue.discover_agent_modules()
      [
        {CodePuppyControl.Agents.CodePuppy, :code_puppy, "Code Puppy", "..."},
        {CodePuppyControl.Agents.PackLeader, :pack_leader, "Pack Leader", "..."},
        ...
      ]
  """
  @spec discover_agent_modules() ::
          list({module(), atom(), String.t(), String.t()})
  def discover_agent_modules do
    {:ok, modules} = :application.get_key(:code_puppy_control, :modules)

    modules
    |> Enum.filter(&agent_module?/1)
    |> Enum.map(&extract_agent_metadata/1)
    |> Enum.sort_by(fn {_mod, name, _display, _desc} -> name end)
  end

  @doc """
  Unregisters an agent from the catalogue.

  ## Parameters
  - `name`: The agent identifier to remove

  ## Returns
  - `:ok` on success
  """
  @spec unregister_agent(String.t()) :: :ok
  def unregister_agent(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc """
  Clears all registered agents from the catalogue.

  ## Returns
  - `:ok` on success
  """
  @spec clear_catalogue() :: :ok
  def clear_catalogue do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Batch registers multiple agents at once.

  ## Parameters
  - `agents`: List of `{name, display_name, description}` tuples

  ## Returns
  - `{:ok, count}` with number of agents registered

  ## Examples

      iex> AgentCatalogue.register_agents([
      ...>   {"elixir-dev", "Elixir Developer", "Elixir/OTP expert"},
      ...>   {"python-dev", "Python Developer", "Python expert"}
      ...> ])
      {:ok, 2}
  """
  @spec register_agents(list({String.t(), String.t(), String.t()})) ::
          {:ok, non_neg_integer()}
  def register_agents(agents) when is_list(agents) do
    GenServer.call(__MODULE__, {:register_batch, agents})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create public set table for concurrent reads
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Load initial agents: discover from modules + any from app env
    discovered = load_initial_agents()

    for info <- discovered do
      :ets.insert(table, {info.name, info})
    end

    Logger.info("AgentCatalogue initialized with #{length(discovered)} initial agents")

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, name, display_name, description}, _from, state) do
    info = AgentInfo.new(name, display_name, description)
    :ets.insert(@table, {name, info})
    Logger.debug("AgentCatalogue: registered agent #{name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(@table, name)
    Logger.debug("AgentCatalogue: unregistered agent #{name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    Logger.debug("AgentCatalogue: cleared all agents")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_batch, agents}, _from, state) do
    count =
      Enum.reduce(agents, 0, fn {name, display_name, description}, acc ->
        info = AgentInfo.new(name, display_name, description)
        :ets.insert(@table, {name, info})
        acc + 1
      end)

    Logger.debug("AgentCatalogue: batch registered #{count} agents")
    {:reply, {:ok, count}, state}
  end

  # ============================================================================
  # Private Functions — Module Discovery
  # ============================================================================

  # Returns list of AgentInfo structs for all discovered agent modules,
  # plus any manually configured agents from application environment.
  defp load_initial_agents do
    discovered =
      discover_agent_modules()
      |> Enum.map(fn {mod, name_atom, display_name, description} ->
        AgentInfo.new(
          to_string(name_atom),
          display_name,
          description,
          mod
        )
      end)

    # Allow application env to provide additional manual agents
    # as {name, display_name, description} tuples (no module)
    manual_agents =
      Application.get_env(:code_puppy_control, :initial_agents, [])
      |> Enum.map(fn {name, display_name, description} ->
        AgentInfo.new(to_string(name), to_string(display_name), to_string(description))
      end)

    discovered ++ manual_agents
  end

  # Checks whether a module is in the CodePuppyControl.Agents namespace
  # and implements the Agent.Behaviour callbacks.
  #
  # Uses Code.ensure_loaded/1 first because function_exported?/3 only
  # returns true for modules that have been loaded into the VM.
  # During init, some modules may not be loaded yet.
  defp agent_module?(mod) do
    mod
    |> Atom.to_string()
    |> String.starts_with?("Elixir.CodePuppyControl.Agents.") and
      Code.ensure_loaded?(mod) and
      function_exported?(mod, :name, 0) and
      function_exported?(mod, :system_prompt, 1)
  end

  # Extracts metadata from a discovered agent module.
  # Uses `module.name/0` for the atom name.
  # Display name is always derived from the atom (reliable and consistent).
  # Description is extracted from `@moduledoc` first line after em-dash,
  # or falls back to a generated description.
  defp extract_agent_metadata(mod) do
    name_atom = mod.name()
    display_name = derive_display_name(name_atom)
    description = extract_description(mod, name_atom)
    {mod, name_atom, display_name, description}
  end

  # Extracts description from the module's @moduledoc.
  #
  # The first line of moduledoc typically follows one of:
  #   "The Code Puppy — a helpful, friendly AI coding assistant."
  #   "Issue tracking specialist — follows dependency trails with bd."
  #   "QA Kitten — a browser automation and QA testing specialist."
  #
  # We extract the part after the em-dash (—) as the description.
  # If no em-dash is present, the full first line is used.
  # Falls back to deriving description from the atom name.
  defp extract_description(mod, name_atom) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) ->
        parse_description(doc, name_atom)

      _ ->
        derive_description(name_atom)
    end
  end

  # Parses the moduledoc string to extract the description.
  #
  # Pattern: "The Pack Leader — orchestration agent that coordinates..."
  #   description = "Orchestration agent that coordinates..."
  #
  # Pattern (no dash): "The Code Scout."
  #   description = second non-empty line, or derived fallback
  defp parse_description(doc, name_atom) do
    lines =
      doc
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] ->
        derive_description(name_atom)

      [first | _rest] ->
        case String.split(first, "—", parts: 2) do
          [_title_part, desc_part] ->
            desc_part
            |> String.trim()
            |> String.trim_trailing(".")
            |> capitalize_first()

          [_no_dash] ->
            # No em-dash; try the second line or fall back
            case Enum.drop(lines, 1) |> Enum.filter(&(&1 != "")) do
              [second | _] -> String.trim_trailing(second, ".")
              [] -> derive_description(name_atom)
            end
        end
    end
  end

  # Derives a human-readable display name from an atom.
  # :code_puppy → "Code Puppy"
  # :pack_leader → "Pack Leader"
  # :qa_expert → "QA Expert"
  defp derive_display_name(name_atom) do
    name_atom
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map(&capitalize_acronym/1)
    |> Enum.join(" ")
  end

  # Capitalizes a word, but preserves known acronyms (QA, etc.)
  defp capitalize_acronym("qa"), do: "QA"
  defp capitalize_acronym(word), do: String.capitalize(word)

  # Derives a basic description from the atom name.
  defp derive_description(name_atom) do
    display = derive_display_name(name_atom)
    "#{display} agent"
  end

  # Capitalizes only the first character of a string, preserving the
  # casing of the rest (unlike String.capitalize/1 which lowercases
  # everything after the first character). This preserves acronyms
  # like "AI", "QA", "OWASP" in descriptions.
  defp capitalize_first(<<first::utf8, rest::binary>>) do
    String.upcase(<<first::utf8>>) <> rest
  end

  defp capitalize_first(""), do: ""
end
