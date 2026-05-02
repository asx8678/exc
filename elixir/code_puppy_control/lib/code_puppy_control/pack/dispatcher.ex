defmodule CodePuppyControl.Pack.Dispatcher do
  @moduledoc """
  Round-robin dispatcher for selecting worker nodes based on capabilities.

  Routes sub-agent dispatch requests to the least-recently-used worker
  that has matching capabilities. This is separate from model routing
  (`Routing.Router`) — this selects WHICH NODE runs a task.

  ## Architecture

  Uses a **GenServer + ETS** split:

  - **ETS table** (`:pack_dispatcher`) — fast reads for worker capability
    lookups and availability queries. Same pattern as `NamingService`.
  - **GenServer** — serializes writes (registration, unregistration) and
    tracks per-sub-agent-type round-robin counters in state.

  ## Round-Robin Semantics

  Each sub-agent type (`:terrier`, `:watchdog`, etc.) maintains its own
  independent round-robin counter. Dispatch for `:terrier` rotates across
  matching workers independently from `:watchdog` dispatch.

  ## Usage

      # Register workers
      Dispatcher.register_worker(:worker_a@host, %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      # Round-robin dispatch
      Dispatcher.dispatch(:terrier)
      # => {:ok, :worker_a@host}

      Dispatcher.dispatch(:terrier)
      # => {:ok, :worker_b@host}  (different worker if available)

      Dispatcher.dispatch(:watchdog)
      # => {:ok, :worker_a@host}  (independent counter)

  ## Telemetry

  Emits `[:code_puppy, :distributed_pack, :dispatch, :selected]` for every
  successful dispatch selection, with `sub_agent_type`, `worker_node`, and
  `matching_workers` count in metadata.

  ## References

  - Design doc `distributed-packs.md` §13.5: Round-robin across workers
  - Issue `code_puppy-5vd.1`: Round-robin dispatch with capability matching
  - Built on top of existing `NamingService` capability index
  """

  use GenServer

  require Logger

  @table :pack_dispatcher

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Starts the Dispatcher GenServer and creates the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers or updates a worker's capabilities in the dispatcher registry.

  Stores the full capabilities map in ETS and indexes the worker under
  each sub-agent type it supports. Replaces any existing registration
  for the same node atom.

  ## Examples

      iex> Dispatcher.register_worker(:worker_a@host, %{
      ...>   sub_agents: [:terrier, :watchdog],
      ...>   host_os: "linux",
      ...>   max_concurrent_runs: 4
      ...> })
      :ok
  """
  @spec register_worker(node(), map(), atom()) :: :ok
  def register_worker(node_name, capabilities, server \\ __MODULE__)
      when is_atom(node_name) and is_map(capabilities) and is_atom(server) do
    GenServer.call(server, {:register_worker, node_name, capabilities})
  end

  @doc """
  Removes a worker and all its index entries from the dispatcher.

  ## Examples

      iex> Dispatcher.unregister_worker(:worker_a@host)
      :ok
  """
  @spec unregister_worker(node(), atom()) :: :ok
  def unregister_worker(node_name, server \\ __MODULE__)
      when is_atom(node_name) and is_atom(server) do
    GenServer.call(server, {:unregister_worker, node_name})
  end

  @doc """
  Selects the next worker for a given sub-agent type using round-robin.

  Returns `{:ok, node_name}` when a matching, registered worker exists, or
  `{:error, :no_workers_available}` when none are found.

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
  @spec dispatch(atom(), keyword(), atom()) :: {:ok, node()} | {:error, term()}
  def dispatch(sub_agent_type, opts \\ [], server \\ __MODULE__)

  def dispatch(sub_agent_type, opts, server)
      when is_atom(sub_agent_type) and is_list(opts) and is_atom(server) do
    workers = available_workers(sub_agent_type: sub_agent_type, opts: opts)

    case workers do
      [] ->
        {:error, :no_workers_available}

      _ ->
        GenServer.call(server, {:dispatch_select, sub_agent_type, workers})
    end
  end

  @doc """
  Returns a list of registered worker node atoms, optionally filtered.

  ## Options

    * `:sub_agent_type` — atom; only return workers supporting this agent type
    * `:host_os` — string or atom; filter by host OS
    * `:model` — string; filter by available model name
    * `:opts` — keyword list of additional filter options (for delegation)

  When no options are given, returns ALL registered workers.

  ## Examples

      iex> Dispatcher.available_workers(sub_agent_type: :terrier)
      [:worker_a@host, :worker_b@host]

      iex> Dispatcher.available_workers()
      [:worker_a@host, :worker_b@host, :worker_c@host]
  """
  @spec available_workers(keyword()) :: [node()]
  def available_workers(opts \\ []) do
    available_workers_fn(opts)
  end

  defp available_workers_fn(opts) when is_list(opts) do
    sub_agent_type = Keyword.get(opts, :sub_agent_type)

    candidates =
      case sub_agent_type do
        nil ->
          # No type filter — return all registered workers
          list_worker_nodes()

        type when is_atom(type) ->
          # Look up the agent-to-workers index
          case :ets.lookup(@table, {type, :workers}) do
            [{{^type, :workers}, nodes}] -> nodes
            [] -> []
          end
      end

    extra_opts = Keyword.get(opts, :opts, [])

    candidates
    |> apply_os_filter(opts, extra_opts)
    |> apply_model_filter(opts, extra_opts)
    |> Enum.reverse()
  end

  @doc """
  Returns the current dispatcher state for debugging and telemetry.

  Includes the round-robin counters and the count of registered workers.

  ## Examples

      iex> Dispatcher.status()
      %{
        workers: 3,
        round_robin: %{terrier: 2, watchdog: 0, shepherd: 1, retriever: 0}
      }
  """
  @spec status(atom()) :: map()
  def status(server \\ __MODULE__) when is_atom(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Clears ALL registered workers and resets round-robin counters.

  Used primarily in testing to reset state between test runs. Requires
  GenServer ownership because the ETS table is `:protected`.
  """
  @spec clear(atom()) :: :ok
  def clear(server \\ __MODULE__) when is_atom(server) do
    GenServer.call(server, :clear)
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

    state = %{round_robin: %{}}

    Logger.info("Dispatcher initialized: ETS table :#{@table} created")
    {:ok, state}
  end

  @impl true
  def handle_call({:register_worker, node_name, capabilities}, _from, state) do
    sub_agents = Map.get(capabilities, :sub_agents, [])

    # Remove old index entries if this node is already registered
    remove_worker_indexes(node_name)

    # Store capabilities metadata
    :ets.insert(@table, {node_name, capabilities})

    # Index the sub-agents this worker supports
    :ets.insert(@table, {{node_name, :sub_agents}, sub_agents})

    # For each sub-agent type, add this worker to its index
    for agent_type <- sub_agents do
      add_worker_to_agent_index(agent_type, node_name)
    end

    Logger.info(
      "Dispatcher: registered worker #{inspect(node_name)} with sub-agents: #{inspect(sub_agents)}"
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister_worker, node_name}, _from, state) do
    remove_worker_indexes(node_name)
    Logger.info("Dispatcher: unregistered worker #{inspect(node_name)}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:dispatch_select, sub_agent_type, workers}, _from, state) do
    round_robin = state.round_robin
    current_index = Map.get(round_robin, sub_agent_type, 0)
    worker_count = length(workers)
    safe_index = rem(current_index, worker_count)
    selected = Enum.at(workers, safe_index)

    # Advance the counter (wrap-around is handled by rem on next call)
    updated_round_robin = Map.put(round_robin, sub_agent_type, current_index + 1)

    emit_selected(sub_agent_type, selected, worker_count)

    {:reply, {:ok, selected}, %{state | round_robin: updated_round_robin}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    worker_count = length(list_worker_nodes())

    reply = %{
      workers: worker_count,
      round_robin: state.round_robin
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{round_robin: %{}}}
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp add_worker_to_agent_index(agent_type, node_name) do
    key = {agent_type, :workers}
    current = :ets.lookup(@table, key)

    nodes =
      case current do
        [{^key, existing_nodes}] ->
          if node_name not in existing_nodes do
            [node_name | existing_nodes]
          else
            existing_nodes
          end

        [] ->
          [node_name]
      end

    :ets.insert(@table, {key, nodes})
  end

  defp remove_worker_indexes(node_name) do
    # Read current sub-agents for this worker to clean up agent indices
    case :ets.lookup(@table, {node_name, :sub_agents}) do
      [{{^node_name, :sub_agents}, sub_agents}] ->
        for agent_type <- sub_agents do
          remove_worker_from_agent_index(agent_type, node_name)
        end

      [] ->
        :ok
    end

    # Remove capabilities and sub-agent metadata
    :ets.delete(@table, node_name)
    :ets.delete(@table, {node_name, :sub_agents})
  end

  defp remove_worker_from_agent_index(agent_type, node_name) do
    key = {agent_type, :workers}

    case :ets.lookup(@table, key) do
      [{^key, nodes}] ->
        remaining = List.delete(nodes, node_name)

        case remaining do
          [] -> :ets.delete(@table, key)
          _ -> :ets.insert(@table, {key, remaining})
        end

      [] ->
        :ok
    end
  end

  defp list_worker_nodes do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _val} ->
      # Worker metadata rows have atom keys (node names).
      # Index rows have tuple keys like {:terrier, :workers}.
      is_atom(key)
    end)
    |> Enum.map(fn {name, _caps} -> name end)
  end

  defp apply_os_filter(candidates, opts, extra_opts) do
    host_os = Keyword.get(opts, :host_os) || Keyword.get(extra_opts, :host_os)

    case host_os do
      nil -> candidates
      os -> Enum.filter(candidates, &worker_matches_os?(&1, os))
    end
  end

  defp apply_model_filter(candidates, opts, extra_opts) do
    model = Keyword.get(opts, :model) || Keyword.get(extra_opts, :model)

    case model do
      nil -> candidates
      m -> Enum.filter(candidates, &worker_has_model?(&1, m))
    end
  end

  defp worker_matches_os?(node_name, os_filter) do
    os_str =
      case os_filter do
        os when is_binary(os) -> String.downcase(String.trim(os))
        os when is_atom(os) -> Atom.to_string(os)
      end

    case :ets.lookup(@table, node_name) do
      [{^node_name, caps}] ->
        worker_os = Map.get(caps, :host_os, "")
        String.downcase(String.trim(worker_os)) == os_str

      [] ->
        false
    end
  end

  defp worker_has_model?(node_name, model_filter) do
    case :ets.lookup(@table, node_name) do
      [{^node_name, caps}] ->
        models = Map.get(caps, :available_models, [])
        model_filter in models

      [] ->
        false
    end
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
