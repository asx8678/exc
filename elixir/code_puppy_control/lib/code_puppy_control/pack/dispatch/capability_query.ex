defmodule CodePuppyControl.Pack.Dispatch.CapabilityQuery do
  @moduledoc """
  High-level query interface for finding workers with matching capabilities.

  Used by Pack Leader to answer: "which workers can run this task?"
  Combines NamingService capability index with DistributedSupervisor
  connection status to return only CONNECTED, CAPABLE workers.

  ## Usage

      # Find all connected Linux workers that can run a terrier
      CapabilityQuery.find_eligible(:terrier, %{host_os: "linux"})
      #=> [%{node: :pup_worker_a@dev, capabilities: %{...}, status: :connected}]

      # Is anyone available for a watchdog task?
      CapabilityQuery.any_eligible?(:watchdog)
      #=> true

      # Best worker for a retriever task (least loaded, matching caps)
      CapabilityQuery.best_worker(:retriever)
      #=> {:ok, %{node: :pup_worker_b@dev, capabilities: %{...}, status: :connected}}

      # Cluster summary for /pack cluster display
      CapabilityQuery.cluster_summary()
      #=> %{total_workers: 3, connected_workers: 2, ...}

  All functions handle gracefully when NamingService or DistributedSupervisor
  aren't running — returning empty/zero values rather than crashing.

  ## References

  - Issue `code-puppy-aeg.1`: Pack Leader queries NamingService for eligible workers
  - Design doc §10: Capability Advertisement
  - Design doc §5.1: Leader-side supervision tree
  """

  alias CodePuppyControl.Pack.{NamingService, DistributedSupervisor, RemoteNodeProxy}

  @type query_opts :: [
          sub_agent: atom(),
          model: String.t(),
          host_os: String.t(),
          exclude_nodes: [node()]
        ]

  @type worker_info :: %{
          :node => node(),
          :capabilities => map(),
          :status => :connected | :disconnected,
          optional(:active_runs) => non_neg_integer()
        }

  @doc """
  Find workers that can handle the given sub-agent type with optional capability filters.

  Returns only workers that are BOTH registered in NamingService with matching
  capabilities AND currently connected according to DistributedSupervisor.

  ## Supported Filters

  Same as `NamingService.find_nodes/2`:
    * `:host_os` — OS string or atom (`"linux"`, `"macos"`, `:windows`)
    * `:model` — model name string

  ## Examples

      iex> CapabilityQuery.find_eligible(:terrier)
      [%{node: :pup_worker_a@dev, capabilities: %{...}, status: :connected}]

      iex> CapabilityQuery.find_eligible(:terrier, %{host_os: "linux"})
      [%{node: :pup_worker_a@dev, capabilities: %{...}, status: :connected}]
  """
  @spec find_eligible(atom(), map()) :: [worker_info()]
  def find_eligible(sub_agent_type, filters \\ %{})

  def find_eligible(sub_agent_type, filters) when is_atom(sub_agent_type) and is_map(filters) do
    candidate_nodes = safe_naming(fn -> NamingService.find_nodes(sub_agent_type, filters) end, [])
    connected_nodes = safe_distributed(fn -> DistributedSupervisor.list_nodes() end, [])
    connected_set = MapSet.new(connected_nodes)

    candidate_nodes
    |> Enum.filter(&MapSet.member?(connected_set, &1))
    |> Enum.map(fn node ->
      caps = safe_naming(fn -> NamingService.node_capabilities(node) end, %{})

      %{
        node: node,
        capabilities: caps || %{},
        status: :connected
      }
    end)
  end

  @doc """
  Returns `true` if ANY worker can handle the given requirements.

  Fast-path for dispatch decisions — uses short-circuit evaluation
  to avoid loading full capability data when not needed.

  ## Examples

      iex> CapabilityQuery.any_eligible?(:terrier)
      true

      iex> CapabilityQuery.any_eligible?(:nonexistent)
      false
  """
  @spec any_eligible?(atom(), map()) :: boolean()
  def any_eligible?(sub_agent_type, filters \\ %{})

  def any_eligible?(sub_agent_type, filters) when is_atom(sub_agent_type) and is_map(filters) do
    candidate_nodes = safe_naming(fn -> NamingService.find_nodes(sub_agent_type, filters) end, [])
    connected_nodes = safe_distributed(fn -> DistributedSupervisor.list_nodes() end, [])
    connected_set = MapSet.new(connected_nodes)

    Enum.any?(candidate_nodes, &MapSet.member?(connected_set, &1))
  end

  @doc """
  Returns the best worker for a task — the connected worker with matching
  capabilities and the fewest active runs (least loaded).

  ## Examples

      iex> CapabilityQuery.best_worker(:terrier)
      {:ok, %{node: :pup_worker_a@dev, capabilities: %{...}, status: :connected, active_runs: 0}}

      iex> CapabilityQuery.best_worker(:nonexistent)
      {:error, :no_eligible_workers}
  """
  @spec best_worker(atom(), map()) :: {:ok, worker_info()} | {:error, :no_eligible_workers}
  def best_worker(sub_agent_type, filters \\ %{})

  def best_worker(sub_agent_type, filters) when is_atom(sub_agent_type) and is_map(filters) do
    eligible = find_eligible(sub_agent_type, filters)

    case eligible do
      [] ->
        {:error, :no_eligible_workers}

      workers ->
        workers_with_load =
          Enum.map(workers, fn worker ->
            active = get_active_runs(worker.node)
            Map.put(worker, :active_runs, active)
          end)

        best = Enum.min_by(workers_with_load, & &1.active_runs)
        {:ok, best}
    end
  end

  @doc """
  Summary of cluster capabilities for display (used by `/pack cluster`).

  Aggregates capability data across ALL registered nodes (not just connected)
  to give a complete picture of the cluster's potential.

  ## Examples

      iex> CapabilityQuery.cluster_summary()
      %{
        total_workers: 3,
        connected_workers: 2,
        total_capacity: 16,
        available_agents: [:terrier, :watchdog, :shepherd],
        available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"]
      }
  """
  @spec cluster_summary() :: %{
          total_workers: non_neg_integer(),
          connected_workers: non_neg_integer(),
          total_capacity: non_neg_integer(),
          available_agents: [atom()],
          available_models: [String.t()]
        }
  def cluster_summary() do
    all_nodes = safe_naming(fn -> NamingService.list_nodes() end, [])
    connected_nodes = safe_distributed(fn -> DistributedSupervisor.list_nodes() end, [])

    {total_capacity, available_agents, available_models} =
      all_nodes
      |> Enum.reduce({0, [], []}, fn node, {cap_acc, agent_acc, model_acc} ->
        caps = safe_naming(fn -> NamingService.node_capabilities(node) end, %{})
        caps = caps || %{}

        new_cap = cap_acc + Map.get(caps, :max_concurrent_runs, 1)

        new_agents =
          agent_acc ++
            (Map.get(caps, :sub_agents, []) |> Enum.filter(& &1))

        new_models =
          model_acc ++
            (Map.get(caps, :available_models, [])
             |> Enum.filter(&is_binary(&1) and &1 != ""))

        {new_cap, new_agents, new_models}
      end)

    %{
      total_workers: length(all_nodes),
      connected_workers: length(connected_nodes),
      total_capacity: total_capacity,
      available_agents: available_agents |> Enum.uniq(),
      available_models: available_models |> Enum.uniq()
    }
  end

  # ── Private Helpers ──────────────────────────────────────────────────────

  defp get_active_runs(node_name) do
    case Registry.lookup(RemoteNodeProxy.Registry, node_name) do
      [{pid, _}] ->
        status = RemoteNodeProxy.status(pid)
        Map.get(status, :active_runs, 0)

      [] ->
        0
    end
  rescue
    _ -> 0
  catch
    :exit, _reason -> 0
  end

  defp safe_naming(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _reason -> fallback
  end

  defp safe_distributed(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _reason -> fallback
  end
end
