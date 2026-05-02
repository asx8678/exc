defmodule CodePuppyControl.Pack.Dispatcher do
  @moduledoc """
  Round-robin dispatcher for selecting worker nodes based on capabilities.

  Routes sub-agent dispatch requests to the least-recently-used worker
  that has matching capabilities. This is separate from model routing
  (`Routing.Router`) — this selects WHICH NODE runs a task.

  ## Architecture

  Uses a **GenServer** with zero own-storage — capability data is queried
  at dispatch-time from `NamingService` and `DistributedSupervisor`. The
  GenServer owns ONLY round-robin counter state.

  This ensures no TOCTOU race: worker selection is fully atomic within
  a single `GenServer.call`, and there is no duplicate registry.

  ## Round-Robin Semantics

  Each sub-agent type (`:terrier`, `:watchdog`, etc.) maintains its own
  independent round-robin counter. Dispatch for `:terrier` rotates across
  matching workers independently from `:watchdog` dispatch.

  ## Usage

      # Register workers via NamingService (NOT via Dispatcher)
      NamingService.register_node(:worker_a@host, %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      # Round-robin dispatch (queries NamingService internally)
      Dispatcher.dispatch(:terrier)
      # => {:ok, :worker_a@host}

      Dispatcher.dispatch(:terrier)
      # => {:ok, :worker_b@host}  (different worker if available)

      Dispatcher.dispatch(:watchdog)
      # => {:ok, :worker_a@host}  (independent counter)

  ## Graceful Degradation

  If `NamingService` or `DistributedSupervisor` are not running (e.g. test
  env without full supervision tree), dispatch returns
  `{:error, :no_workers_available}` rather than crashing.

  ## Telemetry

  Emits `[:code_puppy, :distributed_pack, :dispatch, :selected]` for every
  successful dispatch selection, with `sub_agent_type`, `worker_node`, and
  `matching_workers` count in metadata.

  ## References

  - Design doc `distributed-packs.md` §13.5: Round-robin across workers
  - Issue `code_puppy-5vd.1`: Round-robin dispatch with capability matching
  - Queries `NamingService` for worker capabilities (no duplicate registry)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Pack.NamingService
  alias CodePuppyControl.Pack.DistributedSupervisor

  @default_max_concurrent_runs 4

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Starts the Dispatcher GenServer.

  ## Options

    * `:name` — registration name (default: `__MODULE__`)

  Accepts any `GenServer.start_link/2` option.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Selects the next worker for a given sub-agent type using round-robin.

  Queries `NamingService` for eligible workers (with optional capability
  filters), cross-references with `DistributedSupervisor` for connectivity,
  and returns the least-recently-used worker.

  Returns `{:ok, node_name}` when a matching, connected worker exists, or
  `{:error, :no_workers_available}` when none are found.

  Returns `{:error, :dispatcher_not_started}` if the Dispatcher GenServer
  is not running.

  ## Options

    * `:host_os` — filter by host OS string (e.g. `"linux"`, `"macos"`)
    * `:model` — filter by available model name (string)

  The round-robin counter advances atomically after selection. Per-agent-type
  counters are independent — dispatching `:terrier` doesn't affect the
  `:watchdog` counter.

  ## Examples

      iex> Dispatcher.dispatch(:terrier)
      {:ok, :worker_a@host}

      iex> Dispatcher.dispatch(:terrier, host_os: "linux")
      {:ok, :worker_b@host}

      iex> Dispatcher.dispatch(:nonexistent)
      {:error, :no_workers_available}

  Workers at their `max_concurrent_runs` limit are skipped. If ALL matching
  workers are at capacity, returns `{:error, :all_workers_at_capacity}`.
  """
  @spec dispatch(atom(), keyword(), GenServer.server()) ::
          {:ok, node()}
          | {:error, :no_workers_available}
          | {:error, :all_workers_at_capacity}
          | {:error, :dispatcher_not_started}
  def dispatch(sub_agent_type, opts \\ [], server \\ __MODULE__)

  def dispatch(sub_agent_type, opts, server)
      when is_atom(sub_agent_type) and is_list(opts) do
    server_name = resolve_server(server)

    if is_pid(server_name) or (is_atom(server_name) and Process.whereis(server_name) != nil) do
      GenServer.call(server, {:dispatch, sub_agent_type, opts})
    else
      {:error, :dispatcher_not_started}
    end
  end

  @doc """
  Returns the current dispatcher state for debugging and telemetry.

  Includes the round-robin counters.

  ## Examples

      iex> Dispatcher.status()
      %{
        round_robin: %{terrier: 2, watchdog: 0, shepherd: 1, retriever: 0}
      }
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Resets round-robin counters.

  Used primarily in testing to reset state between test runs.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  @doc """
  Acquires a concurrent run slot for the given worker node.

  Returns `:ok` if a slot was successfully acquired, or
  `{:error, :at_capacity}` if the worker has reached its
  `max_concurrent_runs` limit.

  The worker's max capacity is lazily initialized from NamingService
  capabilities, defaulting to `#{@default_max_concurrent_runs}`.

  ## Examples

      iex> Dispatcher.acquire_slot(:worker_a@host)
      :ok

      iex> Dispatcher.acquire_slot(:overloaded@host)
      {:error, :at_capacity}
  """
  @spec acquire_slot(node(), GenServer.server()) :: :ok | {:error, :at_capacity}
  def acquire_slot(worker_node, server \\ __MODULE__) do
    GenServer.call(server, {:acquire_slot, worker_node})
  end

  @doc """
  Releases a concurrent run slot for the given worker node.

  Should be called when a dispatched run completes (success or failure).
  Silently succeeds if the worker has no tracked slots (idempotent).

  ## Examples

      iex> Dispatcher.release_slot(:worker_a@host)
      :ok
  """
  @spec release_slot(node(), GenServer.server()) :: :ok
  def release_slot(worker_node, server \\ __MODULE__) do
    GenServer.call(server, {:release_slot, worker_node})
  end

  @doc """
  Returns the current load information for a specific worker.

  Returns `{:ok, %{active: n, max: m}}` with the current and maximum
  concurrent run counts, or `{:error, :unknown_worker}` if the worker
  has never been tracked.

  ## Examples

      iex> Dispatcher.worker_load(:worker_a@host)
      {:ok, %{active: 2, max: 4}}
  """
  @spec worker_load(node(), GenServer.server()) :: {:ok, map()} | {:error, :unknown_worker}
  def worker_load(worker_node, server \\ __MODULE__) do
    GenServer.call(server, {:worker_load, worker_node})
  end

  @doc """
  Returns all workers with their current slot usage.

  Returns a map of `%{worker_node => %{active: n, max: m}}` for every
  worker that has been tracked by the slot system.

  ## Examples

      iex> Dispatcher.active_slots()
      %{worker_a@host: %{active: 2, max: 4}}
  """
  @spec active_slots(GenServer.server()) :: map()
  def active_slots(server \\ __MODULE__) do
    GenServer.call(server, :active_slots)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Logger.info("Dispatcher initialized")
    supervisor_name = Keyword.get(opts, :supervisor_name, DistributedSupervisor)
    {:ok, %{round_robin: %{}, slots: %{}, supervisor_name: supervisor_name}}
  end

  @impl true
  def handle_call({:dispatch, sub_agent_type, opts}, _from, state) do
    # All dispatch logic is atomic within this single handle_call.
    # No TOCTOU race: worker availability is determined right here.

    filters = build_naming_filters(opts)

    eligible =
      safe_naming(fn ->
        NamingService.find_nodes(sub_agent_type, filters)
      end)

    # Query DistributedSupervisor for connectivity — but gracefully degrade
    # when it's not available (e.g. test env without full supervision tree).
    # When it's unavailable OR has no connected nodes, we trust NamingService
    # data alone. This is critical for single-node setups where remote worker
    # infrastructure isn't deployed — the Dispatcher must still function.
    #
    # Only when both NamingService AND DistributedSupervisor are running AND
    # DistributedSupervisor lists connected nodes do we intersect the sets.
    supervisor_name = state.supervisor_name

    connected =
      safe_distributed(fn -> DistributedSupervisor.list_nodes(supervisor_name) end, :unavailable)

    candidates =
      case {eligible, connected} do
        {[], _} ->
          []

        {_, :unavailable} ->
          # DistributedSupervisor not running — trust NamingService alone
          eligible

        {_, []} ->
          # Running but no connected remote nodes — this is a single-node setup.
          # Trust NamingService data (workers registered locally).
          eligible

        {_, list} when is_list(list) ->
          # Both systems running with connected nodes — intersect
          connected_set = MapSet.new(list)
          Enum.filter(eligible, &MapSet.member?(connected_set, &1))
      end

    available = filter_by_capacity(candidates, state)

    case {candidates, available} do
      {[], _} ->
        {:reply, {:error, :no_workers_available}, state}

      {_, []} ->
        emit_all_at_capacity(sub_agent_type, length(candidates))
        {:reply, {:error, :all_workers_at_capacity}, state}

      {_, workers} ->
        round_robin = state.round_robin
        current_index = Map.get(round_robin, sub_agent_type, 0)
        safe_index = rem(current_index, length(workers))
        selected = Enum.at(workers, safe_index)

        updated_round_robin = Map.put(round_robin, sub_agent_type, current_index + 1)
        state_after_rr = %{state | round_robin: updated_round_robin}

        # Atomically acquire a slot for the selected worker.
        # This is safe because filter_by_capacity already verified capacity,
        # and we're inside the GenServer — no concurrent state mutations.
        {slot, state_with_slot} = get_or_init_slot(state_after_rr, selected)
        acquired_slot = %{slot | active: slot.active + 1}

        final_state = %{
          state_with_slot
          | slots: Map.put(state_with_slot.slots, selected, acquired_slot)
        }

        emit_slot_event(:slot_acquired, selected, acquired_slot)
        emit_selected(sub_agent_type, selected, length(workers))

        {:reply, {:ok, selected}, final_state}
    end
  end

  @impl true
  def handle_call({:acquire_slot, worker_node}, _from, state) do
    {slot, state} = get_or_init_slot(state, worker_node)

    if slot.active < slot.max do
      updated_slot = %{slot | active: slot.active + 1}
      new_state = %{state | slots: Map.put(state.slots, worker_node, updated_slot)}

      emit_slot_event(:slot_acquired, worker_node, updated_slot)

      {:reply, :ok, new_state}
    else
      emit_slot_event(:at_capacity, worker_node, slot)
      {:reply, {:error, :at_capacity}, state}
    end
  end

  @impl true
  def handle_call({:release_slot, worker_node}, _from, state) do
    case Map.get(state.slots, worker_node) do
      nil ->
        {:reply, :ok, state}

      %{active: active} = slot ->
        updated_slot = %{slot | active: max(active - 1, 0)}
        new_state = %{state | slots: Map.put(state.slots, worker_node, updated_slot)}

        emit_slot_event(:slot_released, worker_node, updated_slot)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:worker_load, worker_node}, _from, state) do
    case Map.get(state.slots, worker_node) do
      nil -> {:reply, {:error, :unknown_worker}, state}
      slot -> {:reply, {:ok, slot}, state}
    end
  end

  @impl true
  def handle_call(:active_slots, _from, state) do
    {:reply, state.slots, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{round_robin: state.round_robin, slots: state.slots}, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | round_robin: %{}, slots: %{}}}
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp resolve_server(server) do
    case server do
      {name, node} when is_atom(name) and is_atom(node) -> {name, node}
      {:via, _, _} -> server
      pid when is_pid(pid) -> pid
      name when is_atom(name) -> name
    end
  end

  defp build_naming_filters(opts) do
    # Pass filter values raw to NamingService — it normalizes internally via
    # NamingService.normalize_os/1 (handles both atom and binary OS values,
    # including mapping "darwin" -> :macos). No need to pre-process here.
    opts
    |> Enum.reduce(%{}, fn
      {:host_os, os}, acc -> Map.put(acc, :host_os, os)
      {:model, model}, acc -> Map.put(acc, :model, model)
      _, acc -> acc
    end)
  end

  defp safe_naming(fun, fallback \\ []) do
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

  # ── Slot Helpers ─────────────────────────────────────────────────────────

  defp get_or_init_slot(state, worker_node) do
    case Map.get(state.slots, worker_node) do
      nil ->
        max_runs = lookup_max_concurrent(worker_node)
        slot = %{active: 0, max: max_runs}
        {slot, %{state | slots: Map.put(state.slots, worker_node, slot)}}

      slot ->
        {slot, state}
    end
  end

  defp lookup_max_concurrent(worker_node) do
    caps = safe_naming(fn -> NamingService.node_capabilities(worker_node) end, nil)

    case caps do
      %{max_concurrent_runs: max} when is_integer(max) and max > 0 -> max
      _ -> @default_max_concurrent_runs
    end
  end

  defp has_available_slot?(state, worker_node) do
    case Map.get(state.slots, worker_node) do
      nil -> true
      %{active: active, max: max} -> active < max
    end
  end

  defp filter_by_capacity(candidates, state) do
    Enum.filter(candidates, &has_available_slot?(state, &1))
  end

  # ── Telemetry ────────────────────────────────────────────────────────────

  defp emit_selected(sub_agent_type, worker_node, matching_count) do
    :telemetry.execute(
      [:code_puppy, :distributed_pack, :dispatch, :selected],
      %{system_time: System.system_time(:millisecond)},
      %{
        sub_agent_type: sub_agent_type,
        worker_node: worker_node,
        matching_workers: matching_count
      }
    )
  end

  defp emit_slot_event(event, worker_node, slot) do
    :telemetry.execute(
      [:code_puppy, :pack, :dispatcher, event],
      %{active: slot.active, max: slot.max},
      %{worker_node: worker_node}
    )
  end

  defp emit_all_at_capacity(sub_agent_type, candidate_count) do
    :telemetry.execute(
      [:code_puppy, :pack, :dispatcher, :at_capacity],
      %{candidate_count: candidate_count},
      %{sub_agent_type: sub_agent_type}
    )
  end
end
