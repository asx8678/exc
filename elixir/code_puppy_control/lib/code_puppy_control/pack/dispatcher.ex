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
  """
  @spec dispatch(atom(), keyword(), GenServer.server()) ::
          {:ok, node()} | {:error, :no_workers_available} | {:error, :dispatcher_not_started}
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

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Logger.info("Dispatcher initialized")
    supervisor_name = Keyword.get(opts, :supervisor_name, DistributedSupervisor)
    {:ok, %{round_robin: %{}, supervisor_name: supervisor_name}}
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

    case candidates do
      [] ->
        {:reply, {:error, :no_workers_available}, state}

      workers ->
        round_robin = state.round_robin
        current_index = Map.get(round_robin, sub_agent_type, 0)
        safe_index = rem(current_index, length(workers))
        selected = Enum.at(workers, safe_index)

        updated_round_robin = Map.put(round_robin, sub_agent_type, current_index + 1)

        emit_selected(sub_agent_type, selected, length(workers))

        {:reply, {:ok, selected}, %{state | round_robin: updated_round_robin}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{round_robin: state.round_robin}, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | round_robin: %{}}}
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
end
