defmodule CodePuppyControl.Pack.Dispatcher do
  @moduledoc """
  Capability-aware dispatch router for pack sub-agents.

  Routes sub-agent invocations to either local execution (via Run.Manager)
  or remote execution (via Pack.Worker on a remote node) based on:

  1. Whether distributed packs are enabled
  2. Whether an explicit `node:` target was specified
  3. Whether NamingService has eligible workers for the sub-agent type

  ## Dispatch Resolution Order

  1. Explicit `node: :worker@host` → dispatch to that specific node
  2. Distributed enabled + workers available → select best worker (Phase I.4)
  3. Fallback → local execution (existing behavior, always available)

  ## Graceful Degradation

  If the targeted remote node is unreachable or rejects the dispatch,
  falls back to local execution with a warning log. This ensures the
  system never fails harder than the non-distributed case.

  (Phase I.3 — code_puppy-yge.2)
  """

  require Logger

  alias CodePuppyControl.Pack.{Config, NamingService, Worker, NodeMonitor, LoadBalancer}
  alias CodePuppyControl.Telemetry.DistributedPack, as: PackTelemetry
  alias CodePuppyControl.Tools.AgentInvocation

  # Default dispatch timeout — matches AgentInvocation @default_run_timeout_ms
  @default_timeout 300_000

  # ── Types ────────────────────────────────────────────────────────────────

  @type dispatch_target :: :local | {:remote, node()}

  @type dispatch_opts :: [
          node: node() | nil,
          sub_agent: atom() | nil,
          constraints: keyword() | nil,
          timeout: pos_integer() | nil,
          session_id: String.t() | nil,
          model: String.t() | nil,
          progress_callback: (String.t(), map() -> :ok) | nil
        ]

  @type dispatch_result ::
          {:ok,
           %{
             response: String.t() | nil,
             agent_name: String.t(),
             session_id: String.t() | nil,
             error: nil
           }}
          | {:error,
             %{
               response: nil,
               agent_name: String.t(),
               session_id: String.t() | nil,
               error: String.t()
             }}

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Resolves dispatch target for a sub-agent invocation.

  Returns `:local` or `{:remote, node}` based on config, explicit target,
  and NamingService state. Does NOT execute — just resolves the target.

  ## Resolution Order

  1. Explicit `node:` target → check reachability, then `{:remote, node}`
  2. Distributed enabled + NamingService has workers → `{:remote, node}`
  3. Everything else → `:local` (backward compatible default)
  """
  @spec resolve_target(String.t(), dispatch_opts()) :: dispatch_target()
  def resolve_target(agent_name, opts \\ []) do
    explicit_node = Keyword.get(opts, :node)

    cond do
      # 1. Explicit node target — validate reachability
      explicit_node != nil ->
        if node_reachable?(explicit_node) do
          {:remote, explicit_node}
        else
          Logger.warning(
            "Dispatcher: explicit target #{inspect(explicit_node)} unreachable — " <>
              "falling back to local"
          )

          :local
        end

      # 2. Distributed enabled — check NamingService for eligible workers
      Config.enabled?() ->
        sub_agent = Keyword.get(opts, :sub_agent) || agent_name_to_sub_agent(agent_name)
        constraints = Keyword.get(opts, :constraints, [])

        case find_available_worker(sub_agent, constraints) do
          {:ok, node} -> {:remote, node}
          :none -> :local
        end

      # 3. Not enabled — always local
      true ->
        :local
    end
  end

  @doc """
  Dispatches a sub-agent invocation to the resolved target.

  For local: delegates to `AgentInvocation.invoke/3`.
  For remote: sends `{:dispatch, msg}` cast to the remote `Pack.Worker`,
  then awaits the result via a receive block with timeout.

  Falls back to local execution on timeout or connection failure.
  """
  @spec dispatch(String.t(), String.t(), keyword()) :: dispatch_result()
  def dispatch(agent_name, prompt, opts \\ []) do
    target = resolve_target(agent_name, opts)
    session_id = Keyword.get(opts, :session_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    progress_cb = Keyword.get(opts, :progress_callback)

    case target do
      :local ->
        # Delegate to existing local invocation
        local_result = AgentInvocation.invoke(agent_name, prompt, opts)
        local_to_dispatch_result(local_result)

      {:remote, target_node} ->
        dispatch_remote(agent_name, prompt, target_node, session_id, timeout, progress_cb)
    end
  end

  @doc """
  Returns true if distributed dispatch is available and enabled.
  """
  @spec distributed_available?() :: boolean()
  def distributed_available? do
    Config.enabled?() and NamingService.find_nodes(:retriever) != []
  end

  # ── Public Helpers (testable) ─────────────────────────────────────────────

  @doc """
  Maps agent name strings to sub-agent atoms.

  Known pack sub-agents are mapped explicitly; unknown names
  are converted via `String.to_atom/1`.

  ## Examples

      iex> agent_name_to_sub_agent("retriever")
      :retriever

      iex> agent_name_to_sub_agent(:shepherd)
      :shepherd
  """
  @spec agent_name_to_sub_agent(String.t() | atom()) :: atom()
  def agent_name_to_sub_agent(name) when is_binary(name) do
    case String.downcase(name) do
      "retriever" -> :retriever
      "shepherd" -> :shepherd
      "terrier" -> :terrier
      "watchdog" -> :watchdog
      "pack_leader" -> :pack_leader
      other -> String.to_atom(other)
    end
  end

  def agent_name_to_sub_agent(name) when is_atom(name), do: name

  @doc """
  Checks whether a remote node is reachable.

  First consults `NodeMonitor` for known status. Falls back to
  `Node.connect/1` if NodeMonitor isn't available. Returns `true`
  if the node is connected, `false` otherwise.
  """
  @spec node_reachable?(node()) :: boolean()
  def node_reachable?(node_name) do
    # The local node is always reachable
    if node_name == Node.self() do
      true
    else
      case safe_node_status(node_name) do
        %{status: :connected} -> true
        _ -> try_connect(node_name)
      end
    end
  end

  # Wraps NodeMonitor.node_status/1 — returns nil if the GenServer
  # isn't running (common in single-node or test environments).
  defp safe_node_status(node_name) do
    NodeMonitor.node_status(node_name)
  catch
    :exit, _ -> nil
  end

  @doc """
  Generates a unique run ID for dispatch tracking.

  Format: `pack-run-{16-char-hex}` — distinct from session IDs
  to avoid confusion in logs and telemetry.
  """
  @spec generate_run_id() :: String.t()
  def generate_run_id do
    hex = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "pack-run-#{hex}"
  end

  @doc """
  Formats a remote worker result into the dispatch result shape.

  Handles three result statuses from the Worker protocol:

    * `:success` — agent completed with output
    * `:failure` — agent failed with error
    * `:rejected` — worker rejected the dispatch (no capacity, duplicate, etc.)
  """
  @spec format_remote_result(map(), String.t(), String.t() | nil) :: dispatch_result()
  def format_remote_result(result, agent_name, session_id) do
    case result do
      %{status: :success} ->
        {:ok,
         %{
           response: Map.get(result, :output, "Remote agent completed"),
           agent_name: agent_name,
           session_id: session_id,
           error: nil
         }}

      %{status: :failure} ->
        {:error,
         %{
           response: nil,
           agent_name: agent_name,
           session_id: session_id,
           error: Map.get(result, :error, "Remote agent failed")
         }}

      %{status: :rejected, reason: reason} ->
        {:error,
         %{
           response: nil,
           agent_name: agent_name,
           session_id: session_id,
           error: "Remote worker rejected dispatch: #{inspect(reason)}"
         }}

      # Unknown status — best-effort extraction
      _ ->
        response = Map.get(result, :output)
        error = Map.get(result, :error)

        if error do
          {:error,
           %{
             response: nil,
             agent_name: agent_name,
             session_id: session_id,
             error: error
           }}
        else
          {:ok,
           %{
             response: response || "Remote agent completed (unknown status)",
             agent_name: agent_name,
             session_id: session_id,
             error: nil
           }}
        end
    end
  end

  # ── Private: Progress-aware Await Loop (Phase I.5) ────────────────────

  defp await_with_progress(
         run_id,
         target_node,
         agent_name,
         session_id,
         start_mono,
         timeout,
         progress_cb
       ) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_loop(run_id, target_node, agent_name, session_id, start_mono, deadline, progress_cb)
  end

  defp do_await_loop(
         run_id,
         target_node,
         agent_name,
         session_id,
         start_mono,
         deadline,
         progress_cb
       ) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining <= 0 do
      handle_dispatch_timeout(run_id, target_node, agent_name, session_id)
    else
      receive do
        {:"$gen_cast", {:result, ^run_id, result}} ->
          handle_dispatch_result(run_id, result, target_node, agent_name, session_id, start_mono)

        {:result, ^run_id, result} ->
          handle_dispatch_result(run_id, result, target_node, agent_name, session_id, start_mono)

        {:"$gen_cast", {:progress, ^run_id, payload}} ->
          handle_progress(run_id, payload, progress_cb)

          do_await_loop(
            run_id,
            target_node,
            agent_name,
            session_id,
            start_mono,
            deadline,
            progress_cb
          )

        {:progress, ^run_id, payload} ->
          handle_progress(run_id, payload, progress_cb)

          do_await_loop(
            run_id,
            target_node,
            agent_name,
            session_id,
            start_mono,
            deadline,
            progress_cb
          )
      after
        remaining ->
          handle_dispatch_timeout(run_id, target_node, agent_name, session_id)
      end
    end
  end

  defp handle_progress(run_id, payload, progress_cb) do
    Logger.debug(
      "Dispatcher: progress for #{run_id}: #{inspect(payload.phase)} " <>
        "(#{Float.round(payload.progress * 100, 1)}%)"
    )

    # Emit telemetry
    :telemetry.execute(
      [:code_puppy, :distributed_pack, :progress],
      %{progress: payload.progress, system_time: System.system_time(:millisecond)},
      %{run_id: run_id, phase: payload.phase}
    )

    # Invoke callback if provided
    if is_function(progress_cb, 2) do
      try do
        progress_cb.(run_id, payload)
      rescue
        e -> Logger.warning("Dispatcher: progress callback error: #{inspect(e)}")
      end
    end
  end

  defp handle_dispatch_result(run_id, result, target_node, agent_name, session_id, start_mono) do
    duration = System.monotonic_time(:millisecond) - start_mono
    status = result_status(result)
    PackTelemetry.dispatch_stop(run_id, status, duration)
    safe_lb_record(:completion, target_node, run_id, status)
    safe_unregister_run(target_node, run_id)
    format_remote_result(result, agent_name, session_id)
  end

  defp handle_dispatch_timeout(run_id, target_node, agent_name, session_id) do
    Logger.warning(
      "Dispatcher: remote dispatch to #{inspect(target_node)} timed out — falling back to local"
    )

    PackTelemetry.dispatch_exception(run_id, "timeout")
    safe_lb_record(:completion, target_node, run_id, :failure)
    safe_unregister_run(target_node, run_id)
    local_fallback(agent_name, to_string(session_id), session_id)
  end

  # ── Private: Remote Dispatch ─────────────────────────────────────────────

  defp dispatch_remote(agent_name, prompt, target_node, session_id, timeout, progress_cb) do
    run_id = generate_run_id()
    sub_agent = agent_name_to_sub_agent(agent_name)
    start_mono = System.monotonic_time(:millisecond)

    dispatch_msg = %{
      run_id: run_id,
      sub_agent: sub_agent,
      params: %{
        task_description: prompt,
        model_preference: nil
      },
      leader_node: Node.self(),
      leader_pid: self()
    }

    PackTelemetry.dispatch_start(run_id, sub_agent, target_node)

    # Send dispatch to remote worker via GenServer.cast
    worker_name = Worker.global_name(target_node)

    try do
      GenServer.cast(worker_name, {:dispatch, dispatch_msg})

      # Record dispatch for load tracking (Phase I.4)
      safe_lb_record(:dispatch, target_node, run_id)
      safe_register_run(target_node, run_id)

      # Await result, handling progress updates during the wait (Phase I.5)
      await_with_progress(
        run_id,
        target_node,
        agent_name,
        session_id,
        start_mono,
        timeout,
        progress_cb
      )
    catch
      :exit, reason ->
        Logger.warning(
          "Dispatcher: failed to reach #{inspect(target_node)}: " <>
            "#{inspect(reason)} — falling back to local"
        )

        PackTelemetry.dispatch_exception(run_id, inspect(reason))
        safe_lb_record(:completion, target_node, run_id, :failure)
        safe_unregister_run(target_node, run_id)

        local_fallback(agent_name, prompt, session_id)
    end
  end

  defp local_fallback(agent_name, prompt, session_id) do
    local_result = AgentInvocation.invoke(agent_name, prompt, session_id: session_id)
    local_to_dispatch_result(local_result)
  end

  # ── Private: Worker Selection ─────────────────────────────────────────────

  # Uses LoadBalancer for intelligent selection (Phase I.4).
  # Falls back to NamingService first-match if LoadBalancer isn't running.
  defp find_available_worker(sub_agent, constraints) do
    case safe_lb_select(sub_agent, constraints) do
      {:ok, node} -> {:ok, node}
      :none -> :none
    end
  end

  # Wraps LoadBalancer.select_worker — falls back to NamingService
  # first-match if LoadBalancer isn't running.
  defp safe_lb_select(sub_agent, constraints) do
    LoadBalancer.select_worker(sub_agent, constraints)
  catch
    :exit, _ ->
      # LoadBalancer not running — fall back to NamingService first-match
      nodes =
        if constraints == [],
          do: NamingService.find_nodes(sub_agent),
          else: NamingService.find_nodes(sub_agent, constraints)

      case nodes do
        [] -> :none
        [node | _] -> {:ok, node}
      end
  end

  # ── Private: LoadBalancer Recording ──────────────────────────────────────

  defp safe_lb_record(:dispatch, node, run_id) do
    LoadBalancer.record_dispatch(node, run_id)
  catch
    :exit, _ -> :ok
  end

  defp safe_lb_record(:completion, node, run_id, status) do
    LoadBalancer.record_completion(node, run_id, status)
  catch
    :exit, _ -> :ok
  end

  # ── Private: NodeMonitor Run Tracking ──────────────────────────────────

  defp safe_register_run(node, run_id) do
    NodeMonitor.register_run(node, run_id)
  catch
    :exit, _ -> :ok
  end

  defp safe_unregister_run(node, run_id) do
    NodeMonitor.unregister_run(node, run_id)
  catch
    :exit, _ -> :ok
  end

  # ── Private: Result Helpers ──────────────────────────────────────────────

  defp result_status(%{status: status}), do: status
  defp result_status(_), do: :unknown

  # Converts the local AgentInvocation.invoke/3 result map
  # (flat map with :response, :agent_name, :session_id, :error)
  # into the Dispatcher's {:ok, _} | {:error, _} tagged shape.
  defp local_to_dispatch_result(result) do
    if result.error do
      {:error, result}
    else
      {:ok, result}
    end
  end

  defp try_connect(node_name) do
    case Node.connect(node_name) do
      true -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
