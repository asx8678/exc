defmodule CodePuppyControl.Pack.NamingService do
  @moduledoc """
  ETS-backed capability index for worker node selection.

  Maps {sub_agent_type, capability_key} → [qualifying_nodes] for fast
  O(1) lookup by the Pack Leader when dispatching sub-agents.

  Updated by NodeMonitor when workers connect/disconnect/update capabilities.

  (Phase I.1 — code_puppy-yge.2)
  """

  use GenServer

  require Logger

  @table :pack_worker_capabilities

  # ── Client API ────────────────────────────────────────────────────────────

  @doc """
  Starts the NamingService GenServer and creates the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a node's capabilities into the ETS index.

  Capabilities map shape:

      %{
        sub_agents: [:terrier, :watchdog, ...],
        host_os: "linux",
        available_models: ["claude-sonnet-4-20250514", ...],
        max_concurrent_runs: 4,
        features: %{file_ops: true, shell_access: true, ...}
      }

  Upserts — calling again for the same node replaces its previous capabilities.
  """
  @spec register_capabilities(node(), map()) :: :ok
  def register_capabilities(node_name, capabilities) do
    GenServer.call(__MODULE__, {:register, node_name, capabilities})
  end

  @doc """
  Removes all entries for a node from the capability index.
  """
  @spec unregister_node(node()) :: :ok
  def unregister_node(node_name) do
    GenServer.call(__MODULE__, {:unregister, node_name})
  end

  @doc """
  Returns all nodes that can run the given sub-agent type.

  ## Examples

      NamingService.find_nodes(:terrier)
      #=> [:"pup_builder@build-01", :"pup_worker@dev-box"]
  """
  @spec find_nodes(atom()) :: [node()]
  def find_nodes(sub_agent_type) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        :ets.tab2list(@table)
        |> Enum.filter(fn {_node, caps} ->
          sub_agent_type in Map.get(caps, :sub_agents, [])
        end)
        |> Enum.map(fn {node, _caps} -> node end)
    end
  end

  @doc """
  Returns all nodes that can run the given sub-agent type AND match
  the provided constraints.

  Constraints is a keyword list or map of capability keys and values:

      NamingService.find_nodes(:terrier, host_os: "linux")
      #=> [:"pup_builder@build-01"]

  """
  @spec find_nodes(atom(), keyword() | map()) :: [node()]
  def find_nodes(sub_agent_type, constraints) when is_list(constraints) do
    find_nodes(sub_agent_type, Map.new(constraints))
  end

  def find_nodes(sub_agent_type, constraints) when is_map(constraints) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        :ets.tab2list(@table)
        |> Enum.filter(fn {_node, caps} ->
          sub_agent_type in Map.get(caps, :sub_agents, []) and
            matches_constraints?(caps, constraints)
        end)
        |> Enum.map(fn {node, _caps} -> node end)
    end
  end

  @doc """
  Returns the full map of all registered node capabilities.

      NamingService.all_capabilities()
      #=> %{
      #=>   :"pup_builder@build-01" => %{sub_agents: [:terrier], host_os: "linux", ...},
      #=>   :"pup_worker@dev-box" => %{sub_agents: [:watchdog], host_os: "macos", ...}
      #=> }
  """
  @spec all_capabilities() :: %{node() => map()}
  def all_capabilities do
    case :ets.whereis(@table) do
      :undefined ->
        %{}

      _tid ->
        :ets.tab2list(@table)
        |> Map.new(fn {node, caps} -> {node, caps} end)
    end
  end

  @doc """
  Returns capabilities for a specific node, or nil if unknown.
  """
  @spec node_capabilities(node()) :: map() | nil
  def node_capabilities(node_name) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _tid ->
        case :ets.lookup(@table, node_name) do
          [{^node_name, caps}] -> caps
          [] -> nil
        end
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Create the ETS table — owned by this GenServer so it survives
    # as long as the process is alive.
    table = create_table()
    Logger.debug("NamingService: ETS table #{inspect(@table)} created (ref: #{inspect(table)})")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, node_name, capabilities}, _from, state) do
    :ets.insert(@table, {node_name, capabilities})
    Logger.debug("NamingService: registered capabilities for #{inspect(node_name)}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, node_name}, _from, state) do
    :ets.delete(@table, node_name)
    Logger.debug("NamingService: unregistered node #{inspect(node_name)}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp create_table do
    # Use :set for unique keys (one row per node)
    # :public for concurrent reads from any process
    # :named_table for global access by name
    # read_concurrency for high-read workloads
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])
  end

  defp matches_constraints?(caps, constraints) do
    Enum.all?(constraints, fn {key, value} ->
      case Map.get(caps, key) do
        nil -> false
        cap_value when is_list(cap_value) -> value in cap_value
        cap_value -> cap_value == value
      end
    end)
  end
end
