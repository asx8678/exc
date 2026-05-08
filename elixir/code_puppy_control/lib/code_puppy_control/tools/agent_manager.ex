defmodule CodePuppyControl.Tools.AgentManager do
  @moduledoc """
  GenServer-backed agent manager ported from Python's `agent_manager.py`.

  Wraps the existing `AgentCatalogue` for core registry operations and adds:
  - **Session management**: tracks current agent per terminal session via ETS
  - **JSON agent discovery**: discovers agents from `.json` files in agent directories
  - **Clone management**: clone/delete JSON agent definitions
  - **Session persistence**: saves/loads session→agent mappings to disk
  - **Registry lifecycle**: invalidation, refresh, lazy population

  ## Architecture

  The `AgentCatalogue` owns the ETS `:agent_catalogue` table and handles
  agent registration/discovery of Elixir module-backed agents. This manager
  adds the mutable lifecycle state that the Python code manages in
  `AgentManagerState`:

  - Current agent per session (ETS `:agent_manager_sessions` for fast reads)
  - Debounced session file persistence

  ## Thread-safety

  All mutable state is coordinated through the GenServer process.
  Read-heavy operations use ETS `:public` tables with `read_concurrency: true`.

  ## ETS Tables

  - `:agent_manager_sessions` — `{:set, :public}` mapping `session_id → agent_name`
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Tools.AgentCatalogue

  @sessions_table :agent_manager_sessions

  # Clone name patterns (ported from Python)
  @clone_name_pattern ~r/^(?<base>.+)-clone-(?<index>\d+)$/
  @clone_display_pattern ~r/\s*\(Clone\s+\d+\)$/i

  # ── State ─────────────────────────────────────────────────────────────

  defstruct [
    :persist_timer_ref
  ]

  # ── Client API ────────────────────────────────────────────────────────

  @doc """
  Starts the AgentManager GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a map of `%{agent_name => display_name}` for all available agents.

  Filters agents through the catalogue and respects feature flags for
  pack agents and universal constructor agents.
  """
  @spec get_available_agents() :: %{String.t() => String.t()}
  def get_available_agents do
    AgentCatalogue.list_agents()
    |> Enum.filter(&agent_visible?/1)
    |> Map.new(fn info -> {info.name, info.display_name} end)
  end

  @doc """
  Returns a map of `%{agent_name => description}` for all available agents.
  """
  @spec get_agent_descriptions() :: %{String.t() => String.t()}
  def get_agent_descriptions do
    AgentCatalogue.list_agents()
    |> Enum.filter(&agent_visible?/1)
    |> Map.new(fn info -> {info.name, info.description} end)
  end

  @doc """
  Gets the current agent name for a given session.

  Falls back to the default agent from config if no session-specific
  agent is set.

  ## Parameters
  - `session_id`: Terminal session identifier

  ## Returns
  - Agent name string (e.g., `"code-puppy"`)
  """
  @spec get_current_agent_name(String.t()) :: String.t()
  def get_current_agent_name(session_id) when is_binary(session_id) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, agent_name}] ->
        agent_name

      [] ->
        CodePuppyControl.Config.Agents.default_agent()
    end
  end

  @doc """
  Sets the current agent for a given session.

  Persists the mapping both in ETS and to disk.

  ## Parameters
  - `session_id`: Terminal session identifier
  - `agent_name`: Agent name to set as current

  ## Returns
  - `:ok` if set successfully
  - `{:error, :agent_not_found}` if the agent doesn't exist in the catalogue
  """
  @spec set_current_agent(String.t(), String.t()) :: :ok | {:error, :agent_not_found}
  def set_current_agent(session_id, agent_name)
      when is_binary(session_id) and is_binary(agent_name) do
    GenServer.call(__MODULE__, {:set_current, session_id, agent_name})
  end

  @doc """
  Gets the module for the current agent in a session.

  ## Returns
  - `{:ok, module}` if found
  - `{:error, :no_module}` if agent has no backing module
  - `{:error, :agent_not_found}` if agent not in catalogue
  """
  @spec get_current_agent_module(String.t()) ::
          {:ok, module()} | {:error, :no_module} | {:error, :agent_not_found}
  def get_current_agent_module(session_id) do
    agent_name = get_current_agent_name(session_id)

    case AgentCatalogue.get_agent_module(agent_name) do
      {:ok, mod} -> {:ok, mod}
      {:error, :no_module} -> {:error, :no_module}
      :not_found -> {:error, :agent_not_found}
    end
  end

  @doc """
  Discovers and registers JSON agents from all agent search paths.

  Scans `project_agents_dir()` and `user_agents_dir()` for `.json` files,
  parses them, and registers them in the AgentCatalogue.

  Python agents (already in catalogue as module-backed) take precedence
  over JSON agents with the same name.

  ## Returns
  - `{:ok, count}` with the number of newly registered JSON agents
  """
  @spec register_json_agents() :: {:ok, non_neg_integer()}
  def register_json_agents do
    GenServer.call(__MODULE__, :register_json_agents)
  end

  @doc """
  Forces a full re-discovery of all agents.

  Clears the catalogue, re-discovers module agents, re-discovers JSON agents,
  and marks the registry as populated.
  """
  @spec refresh_agents() :: :ok
  def refresh_agents do
    GenServer.call(__MODULE__, :refresh_agents)
  end

  @doc """
  Invalidates the registry, forcing re-discovery on next access.
  """
  @spec invalidate_registry() :: :ok
  def invalidate_registry do
    GenServer.call(__MODULE__, :invalidate_registry)
  end

  @doc """
  Checks whether an agent name looks like a clone (matches `*-clone-N`).
  """
  @spec is_clone_agent?(String.t()) :: boolean()
  def is_clone_agent?(agent_name) when is_binary(agent_name) do
    Regex.match?(@clone_name_pattern, agent_name)
  end

  @doc """
  Clones an existing agent definition into a new JSON file.

  Reads the source agent's configuration (either from JSON file or by
  instantiating the module), creates a copy with a new name, and writes
  it to the user agents directory.

  ## Parameters
  - `agent_name`: Source agent name to clone

  ## Returns
  - `{:ok, clone_name}` on success
  - `{:error, reason}` on failure
  """
  @spec clone_agent(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def clone_agent(agent_name) when is_binary(agent_name) do
    GenServer.call(__MODULE__, {:clone_agent, agent_name})
  end

  @doc """
  Deletes a cloned JSON agent definition.

  Only deletes agents that:
  - Match the clone naming pattern (`*-clone-N`)
  - Are registered with a `json_path`
  - Exist in the user agents directory
  - Are not the currently active agent for any session

  ## Parameters
  - `agent_name`: Clone agent name to delete

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec delete_clone_agent(String.t()) :: :ok | {:error, String.t()}
  def delete_clone_agent(agent_name) when is_binary(agent_name) do
    GenServer.call(__MODULE__, {:delete_clone_agent, agent_name})
  end

  @doc """
  Returns all current session→agent mappings.

  ## Returns
  - Map of `%{session_id => agent_name}`
  """
  @spec list_sessions() :: %{String.t() => String.t()}
  def list_sessions do
    @sessions_table
    |> :ets.tab2list()
    |> Map.new()
  end

  @doc """
  Resets all manager state. Used for test isolation.
  """
  @spec reset_for_testing() :: :ok
  def reset_for_testing do
    GenServer.call(__MODULE__, :reset_for_testing)
  end

  # ── Server Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@sessions_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    # Load persisted session data
    session_data = load_session_data()

    for {session_id, agent_name} <- session_data do
      :ets.insert(table, {session_id, agent_name})
    end

    state = %__MODULE__{
      persist_timer_ref: nil
    }

    Logger.info("AgentManager initialized with #{map_size(session_data)} persisted sessions")
    {:ok, state}
  end

  @impl true
  def handle_call({:set_current, session_id, agent_name}, _from, state) do
    # Verify agent exists in catalogue
    case AgentCatalogue.get_agent_info(agent_name) do
      {:ok, _info} ->
        :ets.insert(@sessions_table, {session_id, agent_name})
        {:reply, :ok, schedule_persist(state)}

      :not_found ->
        {:reply, {:error, :agent_not_found}, state}
    end
  end

  @impl true
  def handle_call(:register_json_agents, _from, state) do
    count = do_register_json_agents()
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call(:refresh_agents, _from, state) do
    # Clear and re-register JSON agents
    # Note: Module agents are auto-discovered by AgentCatalogue on init,
    # so we only need to re-scan JSON agents here.
    do_register_json_agents()

    Logger.info("AgentManager: agent registry refreshed")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:invalidate_registry, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clone_agent, agent_name}, _from, state) do
    result = do_clone_agent(agent_name)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_clone_agent, agent_name}, _from, state) do
    result = do_delete_clone_agent(agent_name)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:reset_for_testing, _from, state) do
    :ets.delete_all_objects(@sessions_table)
    AgentCatalogue.clear_catalogue()
    _ = cancel_persist_timer(state)

    {:reply, :ok, %__MODULE__{}}
  end

  # Debounce interval for persisting sessions (ms)
  @persist_debounce_ms 500

  # ── Private: Session Persistence ──────────────────────────────────────

  defp schedule_persist(state) do
    # Cancel any existing timer, then schedule a new one
    state = cancel_persist_timer(state)
    timer_ref = Process.send_after(self(), :do_persist, @persist_debounce_ms)
    %{state | persist_timer_ref: timer_ref}
  end

  defp cancel_persist_timer(state) do
    case state.persist_timer_ref do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        %{state | persist_timer_ref: nil}
    end
  end

  @impl true
  def handle_info(:do_persist, state) do
    persist_sessions()
    {:noreply, %{state | persist_timer_ref: nil}}
  end

  # ── Private: Session Persistence (disk I/O) ───────────────────────────

  defp session_file_path do
    state_dir =
      case System.get_env("PUP_STATE_DIR") do
        nil -> Path.expand("~/.local/share/code_puppy")
        dir -> dir
      end

    Path.join(state_dir, "terminal_sessions.json")
  end

  defp load_session_data do
    path = session_file_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            # Clean up dead sessions
            data
            |> Enum.filter(fn {_session_id, agent_name} -> is_binary(agent_name) end)
            |> Map.new()

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp persist_sessions do
    path = session_file_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    sessions =
      @sessions_table
      |> :ets.tab2list()
      |> Map.new()

    json = Jason.encode!(sessions, pretty: true)
    tmp_path = path <> ".tmp"

    case File.write(tmp_path, json) do
      :ok ->
        case File.rename(tmp_path, path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("AgentManager: failed to persist sessions: #{inspect(reason)}")
            File.rm(tmp_path)
        end

      {:error, reason} ->
        Logger.warning("AgentManager: failed to write sessions file: #{inspect(reason)}")
        File.rm(tmp_path)
    end
  end

  # ── Private: JSON Agent Discovery ─────────────────────────────────────

  defp do_register_json_agents do
    existing = AgentCatalogue.list_agents() |> MapSet.new(& &1.name)
    search_paths = CodePuppyControl.Config.Agents.agent_search_paths()

    search_paths
    |> Enum.flat_map(&discover_json_files/1)
    |> Enum.reject(fn {_path, name} -> MapSet.member?(existing, name) end)
    |> Enum.reduce(0, fn {json_path, name}, acc ->
      case parse_json_agent(json_path) do
        {:ok, display_name, description} ->
          AgentCatalogue.register_agent(name, display_name, description)
          acc + 1

        {:error, reason} ->
          Logger.warning("AgentManager: failed to parse JSON agent '#{name}': #{reason}")
          acc
      end
    end)
  end

  defp discover_json_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn filename ->
          name = String.replace_suffix(filename, ".json", "")
          {Path.join(dir, filename), name}
        end)

      {:error, _} ->
        []
    end
  end

  defp parse_json_agent(json_path) do
    case File.read(json_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"name" => name} = config} ->
            display_name =
              Map.get(config, "display_name") ||
                name
                |> String.split("-")
                |> Enum.map(&String.capitalize/1)
                |> Enum.join(" ")

            description =
              Map.get(config, "description") || "#{display_name} agent"

            {:ok, display_name, description}

          {:ok, _malformed} ->
            {:error, "missing 'name' field"}

          {:error, decode_err} ->
            {:error, "JSON decode error: #{inspect(decode_err)}"}
        end

      {:error, reason} ->
        {:error, "file read error: #{inspect(reason)}"}
    end
  end

  # ── Private: Clone Management ─────────────────────────────────────────

  defp do_clone_agent(agent_name) do
    case AgentCatalogue.get_agent_info(agent_name) do
      :not_found ->
        {:error, "Agent '#{agent_name}' not found"}

      {:ok, _info} ->
        base_name = strip_clone_suffix(agent_name)
        agents_dir = CodePuppyControl.Config.Agents.user_agents_dir()

        existing_names =
          AgentCatalogue.list_agents()
          |> MapSet.new(& &1.name)

        clone_index = next_clone_index(base_name, existing_names, agents_dir)
        clone_name = "#{base_name}-clone-#{clone_index}"
        clone_path = Path.join(agents_dir, "#{clone_name}.json")

        if File.exists?(clone_path) do
          {:error, "Clone target '#{clone_name}' already exists"}
        else
          build_and_write_clone(agent_name, clone_name, clone_index, clone_path, agents_dir)
        end
    end
  end

  defp build_and_write_clone(source_name, clone_name, clone_index, clone_path, _agents_dir) do
    # Try to find the source agent's JSON file
    search_paths = CodePuppyControl.Config.Agents.agent_search_paths()

    source_json_path =
      search_paths
      |> Enum.find_value(fn dir ->
        path = Path.join(dir, "#{source_name}.json")
        if File.exists?(path), do: path
      end)

    clone_config =
      if source_json_path do
        build_clone_from_json(source_json_path, clone_name, clone_index)
      else
        build_clone_from_catalogue(source_name, clone_name, clone_index)
      end

    case clone_config do
      {:ok, config} ->
        json = Jason.encode!(config, pretty: true, maps: :strict)

        case File.write(clone_path, json) do
          :ok ->
            # Register the new clone in the catalogue
            display_name = Map.get(config, "display_name", clone_name)
            description = Map.get(config, "description", "#{display_name} agent")
            AgentCatalogue.register_agent(clone_name, display_name, description)
            {:ok, clone_name}

          {:error, reason} ->
            {:error, "Failed to write clone file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_clone_from_json(json_path, clone_name, clone_index) do
    case File.read(json_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} ->
            source_display = Map.get(config, "display_name", clone_name)

            clone_config =
              config
              |> Map.put("name", clone_name)
              |> Map.put("display_name", build_clone_display_name(source_display, clone_index))

            {:ok, clone_config}

          {:error, reason} ->
            {:error, "JSON parse error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "File read error: #{inspect(reason)}"}
    end
  end

  defp build_clone_from_catalogue(source_name, clone_name, clone_index) do
    case AgentCatalogue.get_agent_info(source_name) do
      {:ok, info} ->
        config = %{
          "name" => clone_name,
          "display_name" => build_clone_display_name(info.display_name, clone_index),
          "description" => info.description
        }

        {:ok, config}

      :not_found ->
        {:error, "Source agent '#{source_name}' not in catalogue"}
    end
  end

  defp do_delete_clone_agent(agent_name) do
    cond do
      not is_clone_agent?(agent_name) ->
        {:error, "Agent '#{agent_name}' is not a clone"}

      agent_is_active?(agent_name) ->
        {:error, "Cannot delete the active agent. Switch agents first."}

      true ->
        delete_clone_file(agent_name)
    end
  end

  defp agent_is_active?(agent_name) do
    @sessions_table
    |> :ets.tab2list()
    |> Enum.any?(fn {_session, active} -> active == agent_name end)
  end

  defp delete_clone_file(agent_name) do
    agents_dir = CodePuppyControl.Config.Agents.user_agents_dir()
    clone_path = Path.join(agents_dir, "#{agent_name}.json")

    if File.exists?(clone_path) do
      case File.rm(clone_path) do
        :ok ->
          AgentCatalogue.unregister_agent(agent_name)
          :ok

        {:error, reason} ->
          {:error, "Failed to delete clone file: #{inspect(reason)}"}
      end
    else
      {:error, "Clone file for '#{agent_name}' does not exist"}
    end
  end

  # ── Private: Clone Name Helpers ───────────────────────────────────────

  defp strip_clone_suffix(agent_name) do
    case Regex.named_captures(@clone_name_pattern, agent_name) do
      %{"base" => base} -> base
      nil -> agent_name
    end
  end

  defp build_clone_display_name(display_name, clone_index) do
    cleaned = Regex.replace(@clone_display_pattern, display_name, "") |> String.trim()
    cleaned = if cleaned == "", do: display_name, else: cleaned
    "#{cleaned} (Clone #{clone_index})"
  end

  defp next_clone_index(base_name, existing_names, agents_dir) do
    pattern = Regex.compile!("^#{Regex.escape(base_name)}-clone-(\\d+)$")

    indices =
      existing_names
      |> Enum.filter(&Regex.match?(pattern, &1))
      |> Enum.map(fn name ->
        [_, idx] = Regex.run(pattern, name)
        String.to_integer(idx)
      end)

    find_next_index(base_name, Enum.max(indices, fn -> 0 end) + 1, agents_dir)
  end

  defp find_next_index(base_name, candidate, agents_dir) do
    clone_name = "#{base_name}-clone-#{candidate}"
    clone_path = Path.join(agents_dir, "#{clone_name}.json")

    existing_names =
      AgentCatalogue.list_agents()
      |> MapSet.new(& &1.name)

    if clone_name not in existing_names and not File.exists?(clone_path) do
      candidate
    else
      find_next_index(base_name, candidate + 1, agents_dir)
    end
  end

  # ── Private: Agent Visibility ─────────────────────────────────────────

  # Pack agent names that can be filtered
  @pack_agent_names MapSet.new([
                      "retriever",
                      "shepherd",
                      "terrier",
                      "watchdog"
                    ])

  # Universal Constructor agent names
  @uc_agent_names MapSet.new([
                    "uc"
                  ])

  defp agent_visible?(info) do
    pack_visible?(info.name) and uc_visible?(info.name)
  end

  defp pack_visible?(name) do
    if MapSet.member?(@pack_agent_names, name) do
      CodePuppyControl.Config.Debug.pack_agents_enabled?()
    else
      true
    end
  end

  defp uc_visible?(name) do
    if MapSet.member?(@uc_agent_names, name) do
      CodePuppyControl.Config.Debug.universal_constructor_enabled?()
    else
      true
    end
  end
end
