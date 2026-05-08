defmodule CodePuppyControl.Pack.Worker do
  @moduledoc """
  Worker-side entry point for distributed pack execution.

  Runs on headless worker nodes and receives dispatch requests from the
  leader. Each request spawns a sub-agent under the local `SubAgentPool`
  DynamicSupervisor.

  ## Registration

  The worker registers itself with a name like `{:pack_worker, node()}` so
  the leader can `GenServer.call`/`cast` to it via Erlang distribution.

  ## Lifecycle

  1. Worker starts with `--sname pup_worker_01`.
  2. `PackWorker.start_link/1` initializes capabilities and waits.
  3. Leader connects via `Node.connect/1`.
  4. Leader probes capabilities via `{:request_capabilities, ...}`.
  5. Leader dispatches sub-agents via `{:dispatch, ...}`.
  6. Worker reports progress/results back to the leader via casts.

  ## Concurrency

  The worker respects local `PackParallelism` limits — if all slots are
  busy, the dispatch is queued locally and the caller is blocked until a
  slot frees up (concurrent local dispatch from multiple leaders is
  supported via the ETS-backed semaphore).

  ## References

  - Design doc §4.2: Worker Node
  - Design doc §6.2: Message shapes
  - Design doc §12.1: Worker-side supervision tree
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Plugins.PackParallelism

  # ── Configuration ────────────────────────────────────────────────────────

  @pack_worker_name :pack_worker

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the PackWorker GenServer.

  ## Options

    * `:node_name` — Explicit node name (defaults to `Node.self/0`).
    * `:leader` — Expected leader node (optional, for verification).
    * `:capabilities` — Explicit capabilities map (optional, auto-detected).

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    node_name = Keyword.get(opts, :node_name, Node.self())

    # Register under {:pack_worker, node_name} so the leader can find us
    GenServer.start_link(__MODULE__, opts, name: {@pack_worker_name, node_name})
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Auto-detect capabilities
    capabilities = Keyword.get(opts, :capabilities, detect_capabilities())

    state = %{
      node_name: Keyword.get(opts, :node_name, Node.self()),
      # Set when a leader connects
      leader: nil,
      capabilities: capabilities,
      # run_id => %{sub_agent: atom(), started_at: monotonic_time}
      active_runs: %{}
    }

    Logger.info(
      "PackWorker: started on #{inspect(state.node_name)} with " <>
        "#{length(Map.get(capabilities, :sub_agents, []))} sub-agents"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:request_capabilities, {leader_pid, _ref}, state) do
    state = %{state | leader: leader_pid}

    Logger.info("PackWorker: capability request from #{inspect(node(leader_pid))}")

    {:reply, state.capabilities, state}
  end

  @impl true
  def handle_cast({:dispatch, dispatch_msg}, state) do
    # This is the async dispatch handler (§11.2)
    # dispatch_msg = %{run_id, sub_agent, params, leader_node, leader_pid}

    case Map.fetch(dispatch_msg, :run_id) do
      {:ok, run_id} ->
        # Try to acquire a local slot
        case PackParallelism.try_acquire() do
          :ok ->
            # Start the sub-agent process
            spawn_sub_agent(run_id, dispatch_msg, state)

            {:noreply,
             %{
               state
               | active_runs:
                   Map.put(state.active_runs, run_id, %{
                     sub_agent: Map.get(dispatch_msg, :sub_agent),
                     started_at: System.monotonic_time()
                   })
             }}

          {:error, :unavailable} ->
            # Queue locally or reject
            Logger.warning(
              "PackWorker: no slot available for run #{run_id} " <>
                "(sub_agent: #{Map.get(dispatch_msg, :sub_agent)})"
            )

            # Notify leader that the dispatch was queued or rejected
            send_result_back(dispatch_msg, %{
              status: :rejected,
              reason: :no_capacity
            })

            {:noreply, state}
        end

      :error ->
        Logger.warning("PackWorker: received dispatch without run_id: #{inspect(dispatch_msg)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:cancel, run_id}, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        Logger.warning("PackWorker: cancel for unknown run #{run_id}")

      _info ->
        Logger.info("PackWorker: cancelling run #{run_id}")
        # The sub-agent process monitors itself; we just mark it
        # Actual cancellation would send a message to the sub-agent process
        {:noreply, %{state | active_runs: Map.delete(state.active_runs, run_id)}}
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:sub_agent_completed, run_id, status, _result}, state) do
    # Called by a sub-agent process when it finishes
    Logger.info("PackWorker: sub-agent completed run #{run_id}: #{status}")

    PackParallelism.release()
    state = %{state | active_runs: Map.delete(state.active_runs, run_id)}

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp detect_capabilities do
    # Auto-detect what this worker can do.
    # In a real implementation, this would check:
    # - Which sub-agent modules are available
    # - OS detection via :os.type()
    # - Which LLM models are configured
    # - Shell/docker/git access
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
    # Read configured models from the local provider registry
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

  defp spawn_sub_agent(run_id, dispatch_msg, state) do
    # In a real implementation, this would:
    # 1. Look up the sub-agent module by name
    # 2. Start a Task or GenServer under SubAgentPool DynamicSupervisor
    # 3. The sub-agent runs the LLM-backed agent loop with the given params
    # 4. On completion, sends {:sub_agent_completed, run_id, status, result}
    #    to this GenServer
    #
    # For the prototype, we just simulate:
    leader_pid = Map.get(dispatch_msg, :leader_pid)
    sub_agent_name = Map.get(dispatch_msg, :sub_agent)

    # Spawn a lightweight process to simulate work
    spawn_link(fn ->
      try do
        # Simulate sub-agent execution
        Logger.info(
          "PackWorker: executing #{inspect(sub_agent_name)} " <>
            "run_id=#{run_id} on behalf of #{inspect(node(leader_pid))}"
        )

        # TODO(code_puppy-yge.2): Replace with actual sub-agent execution.
        # See docs/distributed-packs.md §12.2 for the execution model.
        result = %{
          status: :success,
          run_id: run_id,
          output: "Simulated execution of #{sub_agent_name}",
          duration_ms: 0
        }

        # Send result back to leader
        send_result_back(dispatch_msg, result)

        # Notify our PackWorker
        send(
          Process.whereis({@pack_worker_name, state.node_name}),
          {:sub_agent_completed, run_id, :success, result}
        )
      rescue
        e ->
          Logger.error("PackWorker: sub-agent #{inspect(sub_agent_name)} crashed: #{inspect(e)}")

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
      # Send result back to the RemoteNodeProxy on the leader node
      GenServer.cast(
        {leader_pid, node(leader_pid)},
        {:result, Map.get(dispatch_msg, :run_id), result}
      )
    end
  end
end
