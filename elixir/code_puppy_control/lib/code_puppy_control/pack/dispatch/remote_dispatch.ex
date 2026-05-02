defmodule CodePuppyControl.Pack.Dispatch.RemoteDispatch do
  @moduledoc """
  Dispatches agent invocations to remote worker nodes.

  Bridges the gap between cp_invoke_agent's local execution path
  and the distributed pack's remote worker infrastructure.

  ## Dispatch Modes

    * **Explicit** — `dispatch_to_node/3` targets a specific node by name.
    * **Automatic** — `dispatch_auto/3` picks the best available remote worker
      via `NamingService.find_nodes/2`, falling back to local dispatch when
      no remote workers are available.

  All dispatches are **asynchronous** per §11.2 — the caller receives a
  `run_id` immediately; results arrive later via `{:result, run_id, payload}`
  casts from the worker.

  ## Telemetry

    * `[:code_puppy, :distributed_pack, :remote_dispatch, :start]`
    * `[:code_puppy, :distributed_pack, :remote_dispatch, :fallback]`
    * `[:code_puppy, :distributed_pack, :remote_dispatch, :exception]`

  Refs: code_puppy-aeg.2
  """

  require Logger

  alias CodePuppyControl.Pack.DistributedSupervisor
  alias CodePuppyControl.Pack.NamingService

  # ── Types ────────────────────────────────────────────────────────────────

  @type dispatch_opts :: [
          node: node(),
          run_id: String.t(),
          timeout: pos_integer(),
          supervisor_name: atom()
        ]

  @default_timeout 30_000
  @default_supervisor CodePuppyControl.Pack.DistributedSupervisor

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Dispatch a sub-agent invocation to a specific remote node.

  Validates that the target node is tracked by `DistributedSupervisor`,
  then delegates to `DistributedSupervisor.dispatch/4`.

  Returns `{:ok, run_id}` on successful dispatch (async — result comes later).
  Returns `{:error, reason}` on dispatch failure.

  ## Options

    * `:node` — (required) target node atom.
    * `:run_id` — unique run identifier; auto-generated if omitted.
    * `:timeout` — dispatch timeout in ms (default: 30_000).
    * `:supervisor_name` — DistributedSupervisor registration name
      (default: `CodePuppyControl.Pack.DistributedSupervisor`).

  ## Examples

      iex> RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"},
      ...>   node: :"pup_worker@host")
      {:ok, "terrier-aBcDeFgH"}
  """
  @spec dispatch_to_node(atom(), map(), dispatch_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch_to_node(sub_agent, params, opts) when is_atom(sub_agent) and is_map(params) do
    node_name = Keyword.get(opts, :node)

    unless is_atom(node_name) and node_name != nil do
      {:error, {:invalid_node, node_name}}
    else
      supervisor_name = Keyword.get(opts, :supervisor_name, @default_supervisor)
      run_id = resolve_run_id(opts, sub_agent)

      if node_available?(node_name, supervisor_name: supervisor_name) do
        do_dispatch_to_node(node_name, sub_agent, params, run_id, supervisor_name, opts)
      else
        {:error, {:node_not_available, node_name}}
      end
    end
  end

  @doc """
  Check if a specific node is available for dispatch.

  A node is considered available when it is tracked by the
  `DistributedSupervisor` (i.e., a `RemoteNodeSupervisor` child
  exists for it with a live process).

  ## Options

    * `:supervisor_name` — DistributedSupervisor registration name
      (default: `CodePuppyControl.Pack.DistributedSupervisor`).

  ## Examples

      iex> RemoteDispatch.node_available?(:"pup_worker@host")
      false
  """
  @spec node_available?(node(), keyword()) :: boolean()
  def node_available?(node_name, opts \\ [])

  def node_available?(node_name, opts) when is_atom(node_name) and is_list(opts) do
    supervisor_name = Keyword.get(opts, :supervisor_name, @default_supervisor)
    node_name in DistributedSupervisor.list_nodes(supervisor_name)
  end

  @doc """
  Dispatch with automatic node selection.

  Uses `NamingService.find_nodes/2` to find an optimal remote worker
  for the given sub-agent type. Falls back to local dispatch if no
  remote workers are available.

  Returns `{:ok, :local}` when dispatching locally (no remote workers).
  Returns `{:ok, {:remote, node, run_id}}` when dispatched to a remote worker.
  Returns `{:error, reason}` on failure.

  ## Options

    * `:run_id` — unique run identifier; auto-generated if omitted.
    * `:timeout` — dispatch timeout in ms (default: 30_000).
    * `:supervisor_name` — DistributedSupervisor registration name
      (default: `CodePuppyControl.Pack.DistributedSupervisor`).

  ## Examples

      iex> RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"}, [])
      {:ok, :local}
  """
  @spec dispatch_auto(atom(), map(), keyword()) ::
          {:ok, :local} | {:ok, {:remote, node(), String.t()}} | {:error, term()}
  def dispatch_auto(sub_agent, params, opts \\ [])
      when is_atom(sub_agent) and is_map(params) and is_list(opts) do
    supervisor_name = Keyword.get(opts, :supervisor_name, @default_supervisor)
    run_id = resolve_run_id(opts, sub_agent)
    candidate_nodes = find_candidate_nodes(sub_agent, supervisor_name)

    case select_best_node(candidate_nodes) do
      {:ok, node_name} ->
        dispatch_result =
          do_dispatch_to_node(node_name, sub_agent, params, run_id, supervisor_name, opts)

        case dispatch_result do
          {:ok, ^run_id} ->
            emit_telemetry(:start, %{run_id: run_id}, %{
              node: node_name,
              sub_agent: sub_agent,
              mode: :auto
            })

            {:ok, {:remote, node_name, run_id}}

          {:error, reason} ->
            Logger.warning(
              "[RemoteDispatch] auto-dispatch to #{inspect(node_name)} failed: " <>
                "#{inspect(reason)} — falling back to local"
            )

            fallback_to_local(sub_agent, run_id)
        end

      :no_remote ->
        fallback_to_local(sub_agent, run_id)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp do_dispatch_to_node(node_name, sub_agent, params, run_id, supervisor_name, opts) do
    try do
      case DistributedSupervisor.dispatch(node_name, sub_agent, params, supervisor_name) do
        {:ok, _proxy_run_id} ->
          # The proxy generates its own run_id internally. We surface the
          # caller-provided run_id for correlation; the proxy's run_id is
          # used for wire-level tracking.
          timeout = Keyword.get(opts, :timeout, @default_timeout)

          emit_telemetry(:start, %{run_id: run_id, timeout: timeout}, %{
            node: node_name,
            sub_agent: sub_agent,
            mode: :explicit
          })

          {:ok, run_id}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("[RemoteDispatch] dispatch_to_node crashed: #{Exception.message(e)}")

        emit_telemetry(:exception, %{run_id: run_id, error: Exception.message(e)}, %{
          node: node_name,
          sub_agent: sub_agent
        })

        {:error, {:dispatch_crashed, Exception.message(e)}}
    end
  end

  defp resolve_run_id(opts, sub_agent) do
    case Keyword.get(opts, :run_id) do
      nil -> generate_run_id(sub_agent)
      run_id when is_binary(run_id) and run_id != "" -> run_id
      _ -> generate_run_id(sub_agent)
    end
  end

  @spec generate_run_id(atom()) :: String.t()
  defp generate_run_id(sub_agent) do
    rand =
      :crypto.strong_rand_bytes(8)
      |> Base.url_encode64(padding: false)

    "#{sub_agent}-#{rand}"
  end

  defp find_candidate_nodes(sub_agent, supervisor_name) do
    # Query NamingService for nodes advertising this sub-agent capability.
    # Wrap calls in try/catch — NamingService or DistributedSupervisor may not
    # be running (e.g. test env without full app tree), and we gracefully fall
    # back to empty candidates → local dispatch.
    naming_nodes =
      try do
        NamingService.find_nodes(sub_agent)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    connected_nodes =
      try do
        DistributedSupervisor.list_nodes(supervisor_name)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    if naming_nodes == [] do
      # No NamingService entries — fall back to all connected nodes
      connected_nodes
    else
      # Intersection: only nodes that are both capable AND connected
      naming_set = MapSet.new(naming_nodes)
      Enum.filter(connected_nodes, &MapSet.member?(naming_set, &1))
    end
  end

  defp select_best_node([]) do
    :no_remote
  end

  defp select_best_node([node_name | _rest]) do
    # Simple first-fit selection. Future: load-aware selection via
    # CapabilityQuery.best_worker/2 when that module is implemented.
    {:ok, node_name}
  end

  defp fallback_to_local(sub_agent, run_id) do
    emit_telemetry(:fallback, %{run_id: run_id}, %{
      sub_agent: sub_agent,
      reason: :no_remote_workers
    })

    {:ok, :local}
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(
      [:code_puppy, :distributed_pack, :remote_dispatch, event],
      measurements,
      metadata
    )
  end
end
