defmodule CodePuppyControl.Pack.Worker do
  @moduledoc """
  Worker-side GenServer for distributed pack execution.

  Runs on headless worker nodes and receives dispatch requests from the
  leader. Each request spawns a sub-agent under the local `SubAgentPool`
  DynamicSupervisor.

  ## Registration

  The worker registers under `{:global, {:pack_worker, node()}}` so the leader
  can `GenServer.call`/`cast` to it via Erlang distribution. Use
  `global_name/1` to get the registration name for a given node.

  ## Lifecycle

  1. Worker starts with `--sname pup_worker_01`.
  2. `start_link/1` initializes capabilities and waits.
  3. Leader connects via `Node.connect/1`.
  4. Leader probes capabilities via `{:request_capabilities, ...}`.
  5. Leader dispatches sub-agents via `{:dispatch, ...}`.
  6. Worker reports progress/results back to the leader via casts.

  ## Dispatch Guards

  Malformed dispatch messages (missing required keys) are rejected with a
  warning. Duplicate `run_id` dispatches are rejected to prevent
  double-execution.

  ## References

  - Design doc §4.2: Worker Node
  - Design doc §6.2: Message shapes
  - Design doc §12.1: Worker-side supervision tree
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Plugins.PackParallelism
  alias CodePuppyControl.Pack.Progress
  alias CodePuppyControl.Telemetry.DistributedPack, as: PackTelemetry

  # ── Configuration ────────────────────────────────────────────────────────

  @pack_worker_name :pack_worker

  @doc false
  # Returns the :global registration name for a given node.
  # Used internally and by the leader to address this worker.
  def global_name(node_name), do: {:global, {@pack_worker_name, node_name}}

  # Required keys in every dispatch message
  @required_dispatch_keys [:run_id, :sub_agent, :leader_node, :leader_pid]

  # ── Types ────────────────────────────────────────────────────────────────

  @type dispatch_msg :: %{
          run_id: String.t(),
          sub_agent: atom(),
          leader_node: node(),
          leader_pid: pid(),
          params: map()
        }

  @type mode :: :ephemeral | :persistent

  @type state :: %{
          node_name: node(),
          mode: mode(),
          leader: pid() | nil,
          capabilities: map(),
          active_runs: %{String.t() => %{sub_agent: atom(), started_at: integer()}},
          idle_since: integer() | nil,
          draining: boolean()
        }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the PackWorker GenServer.

  ## Options

    * `:node_name` — Explicit node name (defaults to `Node.self/0`).
    * `:leader` — Expected leader node (optional, for verification).
    * `:capabilities` — Explicit capabilities map (optional, auto-detected).
    * `:mode` — `:ephemeral` (shut down after idle timeout) or
      `:persistent` (run indefinitely). Default: `:persistent`.
    * `:idle_timeout_ms` — For ephemeral workers, ms of inactivity
      before auto-shutdown. Default: `30_000` (30 seconds).

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    node_name = Keyword.get(opts, :node_name, Node.self())
    GenServer.start_link(__MODULE__, opts, name: global_name(node_name))
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    mode = Keyword.get(opts, :mode, :persistent)
    idle_timeout_ms = Keyword.get(opts, :idle_timeout_ms, 30_000)
    capabilities = Keyword.get(opts, :capabilities, detect_capabilities())

    state = %{
      node_name: Keyword.get(opts, :node_name, Node.self()),
      mode: mode,
      leader: nil,
      capabilities: capabilities,
      active_runs: %{},
      idle_since: nil,
      idle_timeout_ms: idle_timeout_ms,
      draining: false
    }

    Logger.info(
      "PackWorker: started on #{inspect(state.node_name)} (mode: #{mode}) with " <>
        "#{length(Map.get(capabilities, :sub_agents, []))} sub-agents"
    )

    # Subscribe to node events so we can detect leader connections
    :net_kernel.monitor_nodes(true, [:nodedown_reason])

    # Start idle check timer for ephemeral workers
    if mode == :ephemeral do
      schedule_idle_check(state)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:request_capabilities, {leader_pid, _ref}, state) do
    state = %{state | leader: leader_pid}
    Logger.info("PackWorker: capability request from #{inspect(node(leader_pid))}")
    {:reply, state.capabilities, state}
  end

  @doc """
  Puts the worker in drain mode — rejects new dispatches but lets
  active runs complete. Used for graceful shutdown of persistent workers.
  """
  @spec drain(node()) :: :ok
  def drain(node_name \\ Node.self()) do
    GenServer.cast(global_name(node_name), :drain)
  end

  @impl true
  def handle_cast(:drain, state) do
    Logger.info("PackWorker: entering drain mode — no new dispatches accepted")
    state = %{state | draining: true}

    # If no active runs, shut down immediately
    if map_size(state.active_runs) == 0 do
      announce_shutdown(state)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:dispatch, dispatch_msg}, state) do
    # Reject dispatches when draining (Phase I.5)
    if state.draining do
      Logger.info("PackWorker: rejecting dispatch #{dispatch_msg.run_id} — draining")
      reject_dispatch(dispatch_msg, :draining)
      {:noreply, state}
    else
      with :ok <- validate_dispatch_shape(dispatch_msg),
           :ok <- check_duplicate_run_id(dispatch_msg.run_id, state) do
        execute_dispatch(dispatch_msg, state)
      else
        {:error, :malformed_dispatch} ->
          Logger.warning(
            "PackWorker: rejected malformed dispatch (missing " <>
              "required keys #{inspect(@required_dispatch_keys)}): " <>
              inspect(dispatch_msg)
          )

          reject_dispatch(dispatch_msg, :malformed)

          {:noreply, state}

        {:error, {:duplicate_run_id, run_id}} ->
          Logger.warning(
            "PackWorker: rejected duplicate dispatch for run_id=#{run_id}"
          )

          reject_dispatch(dispatch_msg, :duplicate)

          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_cast({:cancel, run_id}, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        Logger.warning("PackWorker: cancel for unknown run #{run_id}")
        {:noreply, state}

      _info ->
        Logger.info("PackWorker: cancelling run #{run_id}")
        PackParallelism.release()

        {:noreply, %{state | active_runs: Map.delete(state.active_runs, run_id)}}
    end
  end

  @impl true
  def handle_info({:sub_agent_completed, run_id, status, _result}, state) do
    Logger.info("PackWorker: sub-agent completed run #{run_id}: #{status}")
    PackParallelism.release()

    active_runs = Map.delete(state.active_runs, run_id)

    # Track idle time for ephemeral workers (code_puppy-jqr.2)
    idle_since =
      if state.mode == :ephemeral and map_size(active_runs) == 0 do
        System.monotonic_time(:millisecond)
      else
        nil
      end

    # Check if we should shut down after draining (Phase I.5)
    if state.draining and map_size(active_runs) == 0 do
      Logger.info("PackWorker: drain complete — all runs finished, shutting down")
      announce_shutdown(state)
      {:stop, :normal, %{state | active_runs: active_runs, idle_since: idle_since}}
    else
      {:noreply, %{state | active_runs: active_runs, idle_since: idle_since}}
    end
  end

  @impl true
  def handle_info(:idle_check, %{mode: :ephemeral} = state) do
    now = System.monotonic_time(:millisecond)
    idle_ms = if state.idle_since, do: now - state.idle_since, else: 0

    if map_size(state.active_runs) == 0 and idle_ms >= state.idle_timeout_ms do
      Logger.info(
        "PackWorker: ephemeral worker idle for #{idle_ms}ms " <>
          "(threshold: #{state.idle_timeout_ms}ms) — shutting down"
      )

      # Announce shutdown to leader before stopping (Phase I.5)
      announce_shutdown(state)

      # Graceful self-shutdown: the supervisor will not restart a transient child
      {:stop, :normal, state}
    else
      schedule_idle_check(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:idle_check, state), do: {:noreply, state}

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("PackWorker: node #{inspect(node)} connected — advertising capabilities")

    # Try to register our capabilities with the remote NamingService
    try do
      GenServer.cast(
        {CodePuppyControl.Pack.NodeMonitor, node},
        {:worker_capabilities, Node.self(), state.capabilities}
      )
    catch
      :exit, _ -> Logger.debug("PackWorker: could not reach NodeMonitor on #{inspect(node)}")
    end

    {:noreply, %{state | leader: node}}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    if node == state.leader do
      Logger.warning("PackWorker: leader node #{inspect(node)} disconnected")
      {:noreply, %{state | leader: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Dispatch Validation ─────────────────────────────────────────────────

  @doc """
  Validates that a dispatch message contains all required keys.

  Returns `:ok` if valid, `{:error, :malformed_dispatch}` otherwise.
  """
  @spec validate_dispatch_shape(map() | nil) :: :ok | {:error, :malformed_dispatch}
  def validate_dispatch_shape(dispatch_msg) when is_map(dispatch_msg) do
    if Enum.all?(@required_dispatch_keys, &Map.has_key?(dispatch_msg, &1)) do
      :ok
    else
      {:error, :malformed_dispatch}
    end
  end

  def validate_dispatch_shape(_), do: {:error, :malformed_dispatch}

  @doc """
  Checks whether a run_id is already active on this worker.

  Returns `:ok` if the run_id is new, `{:error, {:duplicate_run_id, run_id}}`
  if it already exists.
  """
  @spec check_duplicate_run_id(String.t(), state()) ::
          :ok | {:error, {:duplicate_run_id, String.t()}}
  def check_duplicate_run_id(run_id, state) do
    if Map.has_key?(state.active_runs, run_id) do
      {:error, {:duplicate_run_id, run_id}}
    else
      :ok
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp schedule_idle_check(state) do
    # Check at 1/4 of the idle timeout for responsive shutdown
    interval = div(state.idle_timeout_ms, 4)
    Process.send_after(self(), :idle_check, max(interval, 1000))
  end

  # Announce shutdown to the leader's NodeMonitor before stopping.
  # This lets the leader clean up NamingService/LoadBalancer immediately
  # instead of waiting for nodedown detection. (Phase I.5)
  defp announce_shutdown(%{leader: nil}), do: :ok

  defp announce_shutdown(%{leader: leader_node} = state) when is_atom(leader_node) do
    try do
      GenServer.cast(
        {CodePuppyControl.Pack.NodeMonitor, leader_node},
        {:worker_shutting_down, state.node_name, :idle_timeout}
      )
    catch
      :exit, _ -> :ok
    end
  end

  defp announce_shutdown(%{leader: leader_pid}) when is_pid(leader_pid) do
    try do
      GenServer.cast(
        {CodePuppyControl.Pack.NodeMonitor, node(leader_pid)},
        {:worker_shutting_down, Node.self(), :idle_timeout}
      )
    catch
      :exit, _ -> :ok
    end
  end

  defp announce_shutdown(_state), do: :ok

  defp execute_dispatch(dispatch_msg, state) do
    run_id = dispatch_msg.run_id

    case PackParallelism.try_acquire() do
      :ok ->
        PackTelemetry.dispatch_start(run_id, dispatch_msg.sub_agent, dispatch_msg.leader_node)

        spawn_sub_agent(run_id, dispatch_msg, state)

        {:noreply,
         %{
           state
           | active_runs:
               Map.put(state.active_runs, run_id, %{
                 sub_agent: dispatch_msg.sub_agent,
                 started_at: System.monotonic_time()
               }),
             idle_since: nil
         }}

      {:error, :unavailable} ->
        Logger.warning(
          "PackWorker: no slot available for run #{run_id} " <>
            "(sub_agent: #{dispatch_msg.sub_agent})"
        )

        reject_dispatch(dispatch_msg, :no_capacity)

        {:noreply, state}
    end
  end

  defp reject_dispatch(dispatch_msg, reason) do
    send_result_back(dispatch_msg, %{status: :rejected, reason: reason})
  end

  defp spawn_sub_agent(run_id, dispatch_msg, state) do
    leader_pid = dispatch_msg.leader_pid
    sub_agent_name = dispatch_msg.sub_agent

    spawn_link(fn ->
      try do
        Logger.info(
          "PackWorker: executing #{inspect(sub_agent_name)} " <>
            "run_id=#{run_id} on behalf of #{inspect(node(leader_pid))}"
        )

        Progress.send_progress(leader_pid, run_id, :initializing, 0.0,
          message: "Starting #{inspect(sub_agent_name)}"
        )

        # TODO(code_puppy-yge.2): Replace with actual sub-agent execution.
        # See docs/distributed-packs.md §12.2 for the execution model.
        start_mono = System.monotonic_time(:millisecond)

        Progress.send_progress(leader_pid, run_id, :executing, 0.3,
          message: "Running #{inspect(sub_agent_name)}"
        )

        result = %{
          status: :success,
          run_id: run_id,
          output: "Simulated execution of #{sub_agent_name}",
          duration_ms: 0
        }

        Progress.send_progress(leader_pid, run_id, :finalizing, 0.9,
          message: "Completing #{inspect(sub_agent_name)}"
        )

        duration = System.monotonic_time(:millisecond) - start_mono
        PackTelemetry.dispatch_stop(run_id, :success, duration)

        Progress.send_progress(leader_pid, run_id, :streaming_output, 1.0,
          message: "Sending results back"
        )

        send_result_back(dispatch_msg, result)

        send(
          Process.whereis({:global, {@pack_worker_name, state.node_name}}),
          {:sub_agent_completed, run_id, :success, result}
        )
      rescue
        e ->
          PackTelemetry.dispatch_exception(run_id, Exception.message(e))

          Logger.error(
            "PackWorker: sub-agent #{inspect(sub_agent_name)} crashed: #{inspect(e)}"
          )

          send_result_back(dispatch_msg, %{
            status: :failure,
            run_id: run_id,
            error: Exception.message(e)
          })
      end
    end)
  end

  defp send_result_back(dispatch_msg, result) do
    leader_pid = Map.get(dispatch_msg, :leader_pid)

    if leader_pid && node(leader_pid) != :nonode@nohost do
      GenServer.cast(
        {leader_pid, node(leader_pid)},
        {:result, Map.get(dispatch_msg, :run_id), result}
      )
    end
  end

  defp detect_capabilities do
    %{
      sub_agents: [
        CodePuppyControl.Agents.Pack.Retriever,
        CodePuppyControl.Agents.Pack.Shepherd,
        CodePuppyControl.Agents.Pack.Terrier,
        CodePuppyControl.Agents.Pack.Watchdog
      ],
      sub_agent_names: [:retriever, :shepherd, :terrier, :watchdog],
      host_os: detect_os(),
      available_models: detect_available_models(),
      max_concurrent_runs: get_concurrent_limit(),
      mode: :persistent,
      features: %{
        file_ops: CodePuppyControl.CodeContext != nil,
        shell_access: CodePuppyControl.Tools.CommandRunner != nil,
        git_access: CodePuppyControl.Tools.CommandRunner != nil
      }
    }
  end

  defp detect_os do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, :linux} -> "linux"
      {:win32, _} -> "windows"
      {:unix, name} -> Atom.to_string(name)
      _ -> "unknown"
    end
  end

  defp detect_available_models do
    try do
      CodePuppyControl.ModelFactory.ProviderRegistry.all()
      |> Enum.map(fn {type, _mod} -> type end)
    rescue
      _ -> []
    end
  end

  defp get_concurrent_limit do
    try do
      PackParallelism.effective_limit()
    rescue
      _ -> 2
    end
  end
end
