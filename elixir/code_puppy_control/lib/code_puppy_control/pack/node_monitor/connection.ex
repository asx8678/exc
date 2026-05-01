defmodule CodePuppyControl.Pack.NodeMonitor.Connection do
  @moduledoc """
  Async connection management for NodeMonitor.

  Handles connection attempts to remote pack worker nodes via injected
  `connect_fn` with configurable timeouts. Results are sent back to the
  caller process as `{:connect_result, node_atom, worker_name, result}`.

  All functions are pure (no GenServer side-effects) — they take a state
  map and return a (possibly modified) state map or `:ok`.
  """

  require Logger

  alias CodePuppyControl.Pack.DistributedSupervisor

  @ets_table :pack_node_monitor_state

  @doc """
  Iterates configured workers and attempts connections to disconnected nodes.
  """
  def attempt_all(state) do
    Enum.reduce(state.configured_workers, state, fn worker_name, acc ->
      node_atom = String.to_atom(worker_name)

      cond do
        node_connected?(acc.node_states, node_atom) ->
          acc

        node_lost?(acc.node_states, node_atom) ->
          acc

        true ->
          attempt_connect_async(acc, node_atom, worker_name)
      end
    end)
  end

  @doc """
  Spawns an async Task to connect to a node with a timeout.
  """
  def attempt_connect_async(state, node_atom, worker_name) do
    caller = self()
    timeout = state.connect_timeout
    connect_fn = state.connect_fn

    # Spawn an unlinked temp process for async connect — Node.connect/1 can
    # block on slow/unreachable hosts, so we don't want to block the GenServer.
    # The connect_timeout from config is respected via Task.yield/2.
    Task.start(fn ->
      task = Task.async(fn -> connect_fn.(node_atom) end)

      result =
        case Task.yield(task, timeout) do
          {:ok, {:ok, connect_result}} ->
            connect_result

          {:ok, connect_result} ->
            connect_result

          nil ->
            Task.shutdown(task, :brutal_kill)
            :connect_timeout
        end

      send(caller, {:connect_result, node_atom, worker_name, result})
    end)

    state
  end

  @doc """
  Handles a connect result from an async Task.

  Called by NodeMonitor's `handle_info({:connect_result, ...})`.
  Returns updated state.
  """
  def handle_result(state, node_atom, worker_name, result) do
    # Don't overwrite :connected from a {:nodeup} event
    if node_connected?(state.node_states, node_atom) do
      Logger.debug("[NodeMonitor] connect result for #{worker_name} ignored — already connected")
      state
    else
      do_handle_result(state, node_atom, worker_name, result)
    end
  end

  @doc """
  Best-effort call to DistributedSupervisor.add_node/2.

  Passes proxy_opts from state so test mocks work without distribution.
  Uses supervisor_name from state so tests can use custom supervisors.
  """
  def safe_add_node(node_name, state) do
    opts = [supervisor_name: state.supervisor_name, proxy_opts: state.proxy_opts]

    case DistributedSupervisor.add_node(node_name, opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_present, _pid}} ->
        Logger.debug(
          "[NodeMonitor] node #{inspect(node_name)} already present in DistributedSupervisor"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[NodeMonitor] safe_add_node for #{inspect(node_name)} returned error: " <>
            "#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e in RuntimeError ->
      Logger.debug(
        "[NodeMonitor] safe_add_node for #{inspect(node_name)}: #{Exception.message(e)}"
      )

      :ok

    e ->
      Logger.warning(
        "[NodeMonitor] safe_add_node for #{inspect(node_name)} raised: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.debug(
        "[NodeMonitor] safe_add_node for #{inspect(node_name)} exited: #{inspect(reason)}"
      )

      :ok

    kind, reason ->
      Logger.warning(
        "[NodeMonitor] safe_add_node for #{inspect(node_name)} caught #{kind}: #{inspect(reason)}"
      )

      :ok
  end

  @doc """
  Best-effort call to DistributedSupervisor.remove_node/2.
  """
  def safe_remove_node(node_name, state) do
    case DistributedSupervisor.remove_node(node_name, state.supervisor_name) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Logger.debug(
          "[NodeMonitor] node #{inspect(node_name)} not found in DistributedSupervisor for removal"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[NodeMonitor] safe_remove_node for #{inspect(node_name)} returned error: " <>
            "#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e in RuntimeError ->
      Logger.debug(
        "[NodeMonitor] safe_remove_node for #{inspect(node_name)}: #{Exception.message(e)}"
      )

      :ok

    e ->
      Logger.warning(
        "[NodeMonitor] safe_remove_node for #{inspect(node_name)} raised: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.debug(
        "[NodeMonitor] safe_remove_node for #{inspect(node_name)} exited: #{inspect(reason)}"
      )

      :ok

    kind, reason ->
      Logger.warning(
        "[NodeMonitor] safe_remove_node for #{inspect(node_name)} caught #{kind}: #{inspect(reason)}"
      )

      :ok
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp node_connected?(node_states, node_atom) do
    case Map.get(node_states, node_atom) do
      %{status: :connected} -> true
      _ -> false
    end
  end

  defp node_lost?(node_states, node_atom) do
    case Map.get(node_states, node_atom) do
      %{status: :lost} -> true
      _ -> false
    end
  end

  defp do_handle_result(state, node_atom, worker_name, result) do
    existing = Map.get(state.node_states, node_atom, %{})
    preserved_grace = existing[:grace_until]

    case result do
      true ->
        Logger.info("[NodeMonitor] connected to worker #{worker_name}")

        new_state = %{
          status: :connected,
          grace_until: nil,
          retry_count: 0
        }

        :ets.insert(@ets_table, {node_atom, new_state})
        node_states = Map.put(state.node_states, node_atom, new_state)

        safe_add_node(node_atom, state)

        %{state | node_states: node_states}

      :connect_timeout ->
        retries = (existing[:retry_count] || 0) + 1
        Logger.debug("[NodeMonitor] connect timeout for #{worker_name} (attempt #{retries})")
        update_failed_state(state, node_atom, preserved_grace, retries)

      false ->
        retries = (existing[:retry_count] || 0) + 1

        Logger.debug(
          "[NodeMonitor] failed to connect to worker #{worker_name} (attempt #{retries})"
        )

        update_failed_state(state, node_atom, preserved_grace, retries)

      :ignored ->
        retries = (existing[:retry_count] || 0) + 1

        Logger.debug(
          "[NodeMonitor] distribution not started, cannot connect to " <>
            "worker #{worker_name} (attempt #{retries})"
        )

        update_failed_state(state, node_atom, preserved_grace, retries)
    end
  end

  defp update_failed_state(state, node_atom, preserved_grace, retries) do
    failed_state = %{
      status: :disconnected,
      grace_until: preserved_grace,
      retry_count: retries
    }

    :ets.insert(@ets_table, {node_atom, failed_state})
    node_states = Map.put(state.node_states, node_atom, failed_state)
    %{state | node_states: node_states}
  end
end
