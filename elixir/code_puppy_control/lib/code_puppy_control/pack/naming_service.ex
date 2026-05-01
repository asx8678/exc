defmodule CodePuppyControl.Pack.NamingService do
  @moduledoc """
  ETS-backed capability index for remote pack worker nodes.

  Maintains a lookup table mapping `{sub_agent_type, os_atom} -> [node()]`
  so the Pack Leader can answer queries like "which nodes can run a watchdog
  on Linux?"

  ## Index Structure

  The ETS table `:pack_worker_capabilities` has two row types:

      # Capability index: {agent_type, os_atom} -> [node_names]
      {{:terrier, :linux}, [:"pup_builder@host1", :"pup_worker@host2"]}
      {{:watchdog, :any},  [:"pup_worker@host2", :"pup_local@Adams-MacBook-Pro"]}

      # Node metadata: node_name -> %{capabilities_map}
      {:"pup_builder@host1", %{sub_agents: [:terrier, :watchdog], host_os: "linux", ...}}

  Each registered node creates index entries per sub-agent type with both
  a specific OS atom and a catch-all `:any` entry for unfiltered lookups.

  ## Usage

      # Register a node when it connects
      NamingService.register_node(:"pup_worker@host", %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 4,
        available_models: ["claude-sonnet-4-20250514"]
      })

      # Find nodes that can run a terrier on Linux
      NamingService.find_nodes(:terrier, %{host_os: "linux"})

      # Query all capabilities for a specific node
      NamingService.node_capabilities(:"pup_worker@host")

  ## References

  - Design doc distributed-packs.md §10: Capability Advertisement
  """

  use GenServer

  require Logger

  @table :pack_worker_capabilities

  @os_map %{
    "linux" => :linux,
    "macos" => :macos,
    "darwin" => :macos,
    "windows" => :windows,
    "unknown" => :unknown
  }

  @sub_agent_types [:terrier, :watchdog, :shepherd, :retriever]

  @sub_agent_map Map.new(@sub_agent_types, fn t -> {Atom.to_string(t), t} end)

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the NamingService GenServer and creates the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers or updates a node's capabilities in the index.

  Replaces any existing index entries for the node, then builds new index
  entries for each sub-agent type × OS combination (including the `:any`
  catch-all).

  Returns `{:error, :invalid_capabilities}` if the host OS or sub-agent types
  are not recognized.

  ## Examples

      iex> NamingService.register_node(
      ...>   :"pup_worker@host",
      ...>   %{sub_agents: [:terrier, :watchdog], host_os: "linux"}
      ...> )
      :ok
  """
  @spec register_node(node(), map()) :: :ok | {:error, :invalid_capabilities}
  def register_node(node_name, capabilities) when is_atom(node_name) and is_map(capabilities) do
    GenServer.call(__MODULE__, {:register, node_name, capabilities})
  end

  @doc """
  Removes a node and all its index entries from the capability table.

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

  ## Supported Filters

    * `:host_os` — string or atom OS key (`"linux"`, `"macos"`, `:windows`)
    * `:model` — model name string; filters to nodes with that model available

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
    GenServer.call(__MODULE__, {:find_nodes, sub_agent_type, filters})
  end

  @doc """
  Returns the capabilities for a specific node, or `nil` if not registered.

  ## Examples

      iex> NamingService.node_capabilities(:"pup_worker@host")
      %{sub_agents: [:terrier, :watchdog], host_os: "linux"}
  """
  @spec node_capabilities(node()) :: map() | nil
  def node_capabilities(node_name) when is_atom(node_name) do
    case :ets.lookup(@table, node_name) do
      [{^node_name, capabilities}] -> capabilities
      [] -> nil
    end
  end

  @doc """
  Lists all registered node names.
  """
  @spec list_nodes() :: [node()]
  def list_nodes do
    # Match node metadata rows where the key is an atom (node name).
    # Index rows have tuple keys like {{:terrier, :linux}, [...]}.
    # We use tab2list + Elixir filter because ETS match spec guards for
    # type checks (is_atom, is_map) are unreliable across OTP versions.
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _val} -> is_atom(key) end)
    |> Enum.map(fn {name, _caps} -> name end)
  end

  @doc """
  Clears all entries from the capability table.

  Used primarily in testing to reset state between test runs. Requires
  GenServer ownership because the ETS table is `:protected`.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Returns the full index as a human-readable map for debugging.
  """
  @spec dump() :: %{nodes: [node()], index: %{String.t() => [node()]}}
  def dump do
    GenServer.call(__MODULE__, :dump)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :protected,
      :named_table,
      read_concurrency: true,
      write_concurrency: false
    ])

    Logger.info("NamingService initialized: ETS table :#{@table} created")
    {:ok, %{size: 0}}
  end

  @impl true
  def handle_call({:register, node_name, capabilities}, _from, state) do
    # 1. Extract and normalize OS and sub-agents from capabilities
    host_os = Map.get(capabilities, :host_os, Map.get(capabilities, "host_os", "unknown"))

    sub_agents_raw =
      Map.get(capabilities, :sub_agents, Map.get(capabilities, "sub_agents", []))

    with {:ok, host_os_atom} <- normalize_os(host_os),
         {:ok, sub_agents} <- normalize_sub_agents(sub_agents_raw) do
      # 2. Remove old index entries (only after validation passes!)
      remove_node_indexes(node_name)

      # 3. Store normalized capabilities metadata
      normalized =
        capabilities
        |> Map.drop(["sub_agents", "host_os"])
        |> Map.put(:sub_agents, sub_agents)
        |> Map.put(:host_os, host_os)

      :ets.insert(@table, {node_name, normalized})

      # 4. Build index entries for each sub-agent type × OS combination
      for agent_type <- sub_agents do
        add_to_index({agent_type, host_os_atom}, node_name)
        add_to_index({agent_type, :any}, node_name)
      end

      new_size = :ets.info(@table, :size)

      Logger.info(
        "NamingService: registered node #{inspect(node_name)} (table size: #{new_size})"
      )

      {:reply, :ok, %{state | size: new_size}}
    else
      {:error, _reason} ->
        {:reply, {:error, :invalid_capabilities}, state}
    end
  end

  @impl true
  def handle_call({:unregister, node_name}, _from, state) do
    remove_node_indexes(node_name)
    :ets.delete(@table, node_name)

    new_size = :ets.info(@table, :size)

    Logger.info(
      "NamingService: unregistered node #{inspect(node_name)} (table size: #{new_size})"
    )

    {:reply, :ok, %{state | size: new_size}}
  end

  @impl true
  def handle_call({:find_nodes, sub_agent_type, filters}, _from, state) do
    requested_os =
      case Map.get(filters, :host_os) || Map.get(filters, "host_os") do
        nil ->
          :any

        os when is_atom(os) ->
          os

        os when is_binary(os) ->
          case normalize_os(os) do
            {:ok, atom_os} -> atom_os
            {:error, :invalid_os} -> nil
          end
      end

    nodes = if requested_os, do: lookup_by_os(sub_agent_type, requested_os), else: []
    filtered_nodes = apply_additional_filters(nodes, filters)

    {:reply, filtered_nodes, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{size: 0}}
  end

  @impl true
  def handle_call(:dump, _from, state) do
    all_rows = :ets.tab2list(@table)

    {index_rows, meta_rows} =
      Enum.split_with(all_rows, fn
        {{_, _}, list} when is_list(list) -> true
        _ -> false
      end)

    index =
      Enum.reduce(index_rows, %{}, fn {{agent_type, cap_key}, nodes}, acc ->
        human_key = "#{agent_type}/#{cap_key}"
        Map.put(acc, human_key, nodes)
      end)

    nodes =
      Enum.reduce(meta_rows, [], fn {node_name, _caps}, acc ->
        [node_name | acc]
      end)
      |> Enum.reverse()

    {:reply, %{nodes: nodes, index: index}, state}
  end

  # ── OS / Sub-Agent Normalization ───────────────────────────────────────

  @doc false
  def normalize_os(os) when is_atom(os) and os in [:linux, :macos, :windows, :unknown] do
    {:ok, os}
  end

  def normalize_os(os) when is_binary(os) do
    case Map.fetch(@os_map, String.downcase(String.trim(os))) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_os}
    end
  end

  def normalize_os(_) do
    {:error, :invalid_os}
  end

  defp normalize_sub_agents(sub_agents) when is_list(sub_agents) do
    result =
      Enum.map(sub_agents, fn
        agent when is_atom(agent) and agent in @sub_agent_types -> agent
        agent when is_binary(agent) -> Map.get(@sub_agent_map, agent, agent)
        other -> other
      end)

    if Enum.all?(result, &(&1 in @sub_agent_types)) do
      {:ok, result}
    else
      {:error, :invalid_sub_agents}
    end
  end

  defp normalize_sub_agents(_), do: {:error, :invalid_sub_agents}

  # ── Index Helpers ─────────────────────────────────────────────────────

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
    # Read the node's current capabilities to reconstruct index keys
    case :ets.lookup(@table, node_name) do
      [{^node_name, capabilities}] ->
        sub_agents = Map.get(capabilities, :sub_agents, [])
        host_os = Map.get(capabilities, :host_os, "unknown")

        case normalize_os(host_os) do
          {:ok, host_os_atom} ->
            for agent_type <- sub_agents do
              remove_from_index({agent_type, host_os_atom}, node_name)
              remove_from_index({agent_type, :any}, node_name)
            end

          {:error, :invalid_os} ->
            :ok
        end

      [] ->
        :ok
    end
  end

  defp remove_from_index(key, node_name) do
    case :ets.lookup(@table, key) do
      [{^key, nodes}] ->
        case List.delete(nodes, node_name) do
          [] -> :ets.delete(@table, key)
          remaining -> :ets.insert(@table, {key, remaining})
        end

      [] ->
        :ok
    end
  end

  defp lookup_by_os(sub_agent_type, requested_os) do
    # Direct lookup: {agent_type, requested_os_atom}
    # - When :any (no host_os filter): returns all nodes registered for
    #   this agent type via the catch-all index.
    # - When a specific OS (e.g., :linux, :macos): exact match only.
    #   No fallback to :any — if the caller asked for Linux, they mean
    #   Linux, not "whatever you've got".
    key = {sub_agent_type, requested_os}

    case :ets.lookup(@table, key) do
      [{^key, nodes}] -> nodes
      [] -> []
    end
  end

  defp apply_additional_filters(nodes, _filters) when nodes == [], do: []

  defp apply_additional_filters(nodes, filters) do
    requested_model = Map.get(filters, :model) || Map.get(filters, "model")

    if requested_model do
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
