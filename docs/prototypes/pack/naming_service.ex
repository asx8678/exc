defmodule CodePuppyControl.Pack.NamingService do
  @moduledoc """
  ETS-backed capability index for remote pack worker nodes.

  Maintains a lookup table mapping `{sub_agent_type, capability_key} ->
  [node()]` so the Pack Leader can answer queries like "which nodes can run
  a watchdog on Linux?"

  ## Index Structure

  The ETS table `:pack_worker_capabilities` has two row types:

      # Capability index: {agent_type, capability_key} -> [node_names]
      {{:terrier, :linux}, [:"pup_builder@host1", :"pup_worker@host2"]}
      {{:watchdog, :macos}, [:"pup_local@Adams-MacBook-Pro"]}

      # Node metadata: node_name -> %{capabilities_map}
      {:"pup_builder@host1", %{sub_agents: [:terrier, :watchdog], host_os: "linux", ...}}

  ## Usage

      # Register a node when it connects
      NamingService.register_node(:"pup_worker@host", %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 4,
        available_models: ["claude-sonnet-4-20250514"]
      })

      # Find nodes that can run a terrier
      NamingService.find_nodes(:terrier, %{host_os: "linux"})

      # Query all capabilities for a specific node
      NamingService.node_capabilities(:"pup_worker@host")

  ## References

  - Design doc §10: Capability Advertisement
  - Design doc §5.1: Leader-side supervision tree (NamingService entry)
  """

  use GenServer

  require Logger

  @table :pack_worker_capabilities

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Initializes the ETS table. Called once at application startup.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers or updates a node's capabilities in the index.

  ## Examples

      iex> NamingService.register_node(
      ...>   :"pup_worker@host",
      ...>   %{sub_agents: [:terrier, :watchdog], host_os: "linux"}
      ...> )
      :ok
  """
  @spec register_node(node(), map()) :: :ok
  def register_node(node_name, capabilities) when is_atom(node_name) and is_map(capabilities) do
    GenServer.call(__MODULE__, {:register, node_name, capabilities})
  end

  @doc """
  Removes a node from the index (e.g., on disconnection).

  ## Examples

      iex> NamingService.unregister_node(:"pup_worker@host")
      :ok
  """
  @spec unregister_node(node()) :: :ok
  def unregister_node(node_name) when is_atom(node_name) do
    GenServer.call(__MODULE__, {:unregister, node_name})
  end

  @doc """
  Finds nodes matching a sub-agent type and optional capability filters.

  ## Examples

      # Find all nodes that can run terrier
      NamingService.find_nodes(:terrier)
      #=> [:"pup_worker@host", :"pup_builder@host"]

      # Find nodes that can run watchdog on Linux
      NamingService.find_nodes(:watchdog, %{host_os: "linux"})
      #=> [:"pup_builder@host"]
  """
  @spec find_nodes(atom(), map()) :: [node()]
  def find_nodes(sub_agent_type, filters \\ %{})

  def find_nodes(sub_agent_type, filters) when is_atom(sub_agent_type) and is_map(filters) do
    GenServer.call(__MODULE__, {:find, sub_agent_type, filters})
  end

  @doc """
  Returns the capabilities for a specific node.
  """
  @spec node_capabilities(node()) :: map() | nil
  def node_capabilities(node_name) when is_atom(node_name) do
    case :ets.lookup(@table, node_name) do
      [{^node_name, capabilities}] -> capabilities
      [] -> nil
    end
  end

  @doc """
  Lists all registered nodes.
  """
  @spec list_nodes() :: [node()]
  def list_nodes do
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
    # Filter out index rows
    |> Enum.filter(&(not match?({{_, _}, _}, &1)))
  end

  @doc """
  Returns the full index as a human-readable map. Useful for debugging.
  """
  @spec dump() :: %{nodes: [node()], index: %{atom() => [node()]}}
  def dump do
    GenServer.call(__MODULE__, :dump)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Create the ETS table if it doesn't exist (idempotent)
    _table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: false
      ])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, node_name, capabilities}, _from, state) do
    # 1. Remove old index entries for this node
    remove_node_indexes(node_name)

    # 2. Store capabilities metadata
    :ets.insert(@table, {node_name, capabilities})

    # 3. Create index entries for each sub_agent x capability combination
    sub_agents = Map.get(capabilities, :sub_agents, Map.get(capabilities, "sub_agents", []))
    host_os = Map.get(capabilities, :host_os, Map.get(capabilities, "host_os", "unknown"))

    for agent_type <- sub_agents do
      # Index by {agent_type, host_os}
      add_to_index({agent_type, String.to_atom(host_os)}, node_name)
      # Index by {agent_type, :any} (catch-all for "any OS")
      add_to_index({agent_type, :any}, node_name)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, node_name}, _from, state) do
    # Remove all index entries for this node
    remove_node_indexes(node_name)
    :ets.delete(@table, node_name)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:find, sub_agent_type, filters}, _from, state) do
    host_os =
      case Map.get(filters, :host_os) || Map.get(filters, "host_os") do
        nil -> :any
        os when is_binary(os) -> String.to_atom(os)
        os when is_atom(os) -> os
      end

    key = {sub_agent_type, host_os}

    nodes =
      case :ets.lookup(@table, key) do
        [{^key, node_list}] -> node_list
        [] -> []
      end

    # Filter by additional criteria (e.g., model availability)
    nodes = apply_additional_filters(nodes, filters)

    {:reply, nodes, state}
  end

  @impl true
  def handle_call(:dump, _from, state) do
    # Collect all rows (both index and metadata)
    all_rows = :ets.tab2list(@table)

    {index_rows, meta_rows} =
      Enum.split_with(all_rows, fn
        {{_, _}, _} -> true
        _ -> false
      end)

    index =
      Enum.reduce(index_rows, %{}, fn {{agent_type, os_key}, nodes}, acc ->
        key = "#{agent_type}/#{os_key}"
        Map.put(acc, key, nodes)
      end)

    nodes =
      Enum.reduce(meta_rows, [], fn {node_name, _caps}, acc ->
        [node_name | acc]
      end)

    {:reply, %{nodes: nodes, index: index}, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp add_to_index(key, node_name) do
    current =
      case :ets.lookup(@table, key) do
        [{^key, nodes}] -> nodes
        [] -> []
      end

    if node_name not in current do
      :ets.insert(@table, {key, [node_name | current]})
    end
  end

  defp remove_node_indexes(node_name) do
    # Select all index keys that contain this node
    match_pattern = {{{:"$1", :"$2"}, :"$3"}, [{:is_list, :"$3"}], [{{{{:"$1", :"$2"}, :"$3"}}}]}

    @table
    |> :ets.select(match_pattern)
    |> Enum.each(fn {{{agent_type, os_key}, nodes}} ->
      new_nodes = List.delete(nodes, node_name)

      if new_nodes == [] do
        :ets.delete(@table, {agent_type, os_key})
      else
        :ets.insert(@table, {{agent_type, os_key}, new_nodes})
      end
    end)
  end

  defp apply_additional_filters(nodes, filters) do
    # Filter by model availability if the query asks for it
    requested_model = Map.get(filters, :model) || Map.get(filters, "model")

    if requested_model and nodes != [] do
      Enum.filter(nodes, fn node_name ->
        case :ets.lookup(@table, node_name) do
          [{^node_name, caps}] ->
            available_models =
              Map.get(caps, :available_models, Map.get(caps, "available_models", []))

            requested_model in available_models

          [] ->
            false
        end
      end)
    else
      nodes
    end
  end
end
