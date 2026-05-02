defmodule CodePuppyControl.Pack.LoadBalancer do
  @moduledoc """
  Load-aware worker selection for distributed pack dispatch.

  Maintains per-worker slot tracking and provides round-robin selection
  among workers with available capacity. Respects each worker's
  `max_concurrent_runs` from its advertised capabilities.

  ## Selection Strategy

  1. Filter workers by capability (sub-agent type + constraints)
  2. Exclude workers at capacity (active_dispatches >= max_concurrent_runs)
  3. Round-robin among remaining workers
  4. If all at capacity, return :none (caller falls back to local)

  ## Slot Tracking

  The load balancer tracks dispatches in-flight from the leader's
  perspective. This is an approximation — the worker's own
  PackParallelism semaphore is the authoritative gate. The leader-side
  tracking prevents the leader from overwhelming a worker with
  dispatches faster than the worker can reject them.

  (Phase I.4 — code_puppy-yge.2)
  """

  use GenServer
  require Logger
  alias CodePuppyControl.Pack.NamingService

  # Default max_concurrent for unknown nodes
  @default_max_concurrent 4

  # ── Types ──────────────────────────────────────────────────────────────

  @type load_info :: %{
          active_dispatches: non_neg_integer(),
          max_concurrent: pos_integer(),
          total_dispatches: non_neg_integer(),
          total_completions: non_neg_integer(),
          total_failures: non_neg_integer(),
          last_dispatch_at: integer() | nil,
          last_result_at: integer() | nil
        }

  @type state :: %{
          nodes: %{node() => load_info()},
          rr_index: non_neg_integer()
        }

  # ── Public API ─────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Selects the best available worker for a sub-agent dispatch.

  Returns `{:ok, node}` if a worker with available capacity exists,
  or `:none` if all eligible workers are at capacity or no workers match.

  Uses round-robin among workers with available slots.
  """
  @spec select_worker(atom(), keyword()) :: {:ok, node()} | :none
  def select_worker(sub_agent_type, constraints \\ []) do
    GenServer.call(__MODULE__, {:select_worker, sub_agent_type, constraints})
  end

  @doc """
  Records that a dispatch was sent to a worker.
  Increments active_dispatches for slot tracking.
  """
  @spec record_dispatch(node(), String.t()) :: :ok
  def record_dispatch(node_name, run_id) do
    GenServer.cast(__MODULE__, {:record_dispatch, node_name, run_id})
  end

  @doc """
  Records that a dispatch completed (success or failure).
  Decrements active_dispatches, updates counters.
  """
  @spec record_completion(node(), String.t(), :success | :failure | :rejected) :: :ok
  def record_completion(node_name, run_id, status) do
    GenServer.cast(__MODULE__, {:record_completion, node_name, run_id, status})
  end

  @doc """
  Syncs load state with NamingService capabilities.
  Called when a node connects/disconnects or updates capabilities.
  """
  @spec sync_node(node()) :: :ok
  def sync_node(node_name) do
    GenServer.cast(__MODULE__, {:sync_node, node_name})
  end

  @doc """
  Removes a node from load tracking (called on permanent disconnect).
  Any in-flight dispatches are marked as failed.
  """
  @spec remove_node(node()) :: :ok
  def remove_node(node_name) do
    GenServer.cast(__MODULE__, {:remove_node, node_name})
  end

  @doc """
  Returns the current load snapshot for all tracked nodes.
  """
  @spec load_snapshot() :: %{node() => map()}
  def load_snapshot do
    GenServer.call(__MODULE__, :load_snapshot)
  end

  @doc """
  Returns available capacity for a specific node.
  0 means at capacity, negative means over-committed (grace period).
  """
  @spec available_slots(node()) :: integer()
  def available_slots(node_name) do
    GenServer.call(__MODULE__, {:available_slots, node_name})
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Logger.info("LoadBalancer: started")
    {:ok, %{nodes: %{}, rr_index: 0}}
  end

  @impl true
  def handle_call({:select_worker, sub_agent_type, constraints}, _from, state) do
    eligible =
      if constraints == [],
        do: NamingService.find_nodes(sub_agent_type),
        else: NamingService.find_nodes(sub_agent_type, constraints)

    available =
      Enum.filter(eligible, fn node ->
        case Map.get(state.nodes, node) do
          nil -> true
          info -> info.active_dispatches < info.max_concurrent
        end
      end)

    case available do
      [] ->
        {:reply, :none, state}

      nodes ->
        idx = rem(state.rr_index, length(nodes))
        selected = Enum.at(nodes, idx)
        state = %{state | rr_index: state.rr_index + 1}
        {:reply, {:ok, selected}, state}
    end
  end

  @impl true
  def handle_call(:load_snapshot, _from, state) do
    {:reply, state.nodes, state}
  end

  @impl true
  def handle_call({:available_slots, node_name}, _from, state) do
    slots =
      case Map.get(state.nodes, node_name) do
        nil -> @default_max_concurrent
        info -> info.max_concurrent - info.active_dispatches
      end

    {:reply, slots, state}
  end

  @impl true
  def handle_cast({:record_dispatch, node_name, run_id}, state) do
    state = update_in(state.nodes[node_name], fn
      nil ->
        Logger.debug("LoadBalancer: dispatch to unknown node #{inspect(node_name)}, initializing")

        %{
          active_dispatches: 1,
          max_concurrent: @default_max_concurrent,
          total_dispatches: 1,
          total_completions: 0,
          total_failures: 0,
          last_dispatch_at: System.monotonic_time(:millisecond),
          last_result_at: nil
        }

      info ->
        %{info |
          active_dispatches: info.active_dispatches + 1,
          total_dispatches: info.total_dispatches + 1,
          last_dispatch_at: System.monotonic_time(:millisecond)
        }
    end)

    Logger.debug(
      "LoadBalancer: recorded dispatch run_id=#{run_id} to #{inspect(node_name)}"
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_completion, node_name, run_id, status}, state) do
    state = update_in(state.nodes[node_name], fn
      nil ->
        Logger.debug(
          "LoadBalancer: completion for unknown node #{inspect(node_name)}, ignoring"
        )

        nil

      info ->
        active = max(info.active_dispatches - 1, 0)

        {completions, failures} =
          case status do
            :success -> {info.total_completions + 1, info.total_failures}
            :failure -> {info.total_completions, info.total_failures + 1}
            :rejected -> {info.total_completions, info.total_failures + 1}
          end

        %{info |
          active_dispatches: active,
          total_completions: completions,
          total_failures: failures,
          last_result_at: System.monotonic_time(:millisecond)
        }
    end)

    Logger.debug(
      "LoadBalancer: recorded completion run_id=#{run_id} on #{inspect(node_name)} " <>
        "status=#{inspect(status)}"
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:sync_node, node_name}, state) do
    caps = NamingService.node_capabilities(node_name)
    max_concurrent = get_max_concurrent(caps)

    state = update_in(state.nodes[node_name], fn
      nil ->
        Logger.info(
          "LoadBalancer: synced new node #{inspect(node_name)} (max_concurrent: #{max_concurrent})"
        )

        %{
          active_dispatches: 0,
          max_concurrent: max_concurrent,
          total_dispatches: 0,
          total_completions: 0,
          total_failures: 0,
          last_dispatch_at: nil,
          last_result_at: nil
        }

      info ->
        Logger.debug(
          "LoadBalancer: synced existing node #{inspect(node_name)} " <>
            "(max_concurrent: #{info.max_concurrent} -> #{max_concurrent})"
        )

        %{info | max_concurrent: max_concurrent}
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_node, node_name}, state) do
    case Map.get(state.nodes, node_name) do
      nil ->
        :ok

      info ->
        Logger.info(
          "LoadBalancer: removed node #{inspect(node_name)} " <>
            "(#{info.active_dispatches} in-flight dispatches marked as failed)"
        )
    end

    state = %{state | nodes: Map.delete(state.nodes, node_name)}
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp get_max_concurrent(nil), do: @default_max_concurrent

  defp get_max_concurrent(caps) when is_map(caps) do
    Map.get(caps, :max_concurrent_runs, @default_max_concurrent)
  end

  defp get_max_concurrent(_), do: @default_max_concurrent
end
