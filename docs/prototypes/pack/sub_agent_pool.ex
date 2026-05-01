defmodule CodePuppyControl.Pack.SubAgentPool do
  @moduledoc """
  DynamicSupervisor for sub-agent processes running on a worker node.

  Each sub-agent (retriever, shepherd, terrier, watchdog) runs as a
  lightweight process under this supervisor when dispatched from a leader.

  ## Strategy

  `:one_for_one` — if a sub-agent crashes, only it is restarted, and the
  error is reported back to the leader.

  ## Lifecycle

  1. `PackWorker` receives a dispatch from the leader.
  2. `PackWorker` calls `start_sub_agent/1` to start a child.
  3. The child runs the LLM-backed agent loop.
  4. On completion, the child casts the result back to the leader.
  5. The child exits normally (`:normal`) or with an error reason.

  ## References

  - Design doc §12.2: Sub-Agent Execution Model
  """

  use DynamicSupervisor

  require Logger

  @doc """
  Starts the SubAgentPool.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a sub-agent process under this pool.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_sub_agent(map()) :: DynamicSupervisor.on_start_child()
  def start_sub_agent(dispatch_msg) when is_map(dispatch_msg) do
    child_spec = %{
      id: {:sub_agent, Map.get(dispatch_msg, :run_id, make_ref())},
      start: {Task, :start_link, [fn -> run_sub_agent(dispatch_msg) end]},
      type: :worker,
      # Don't restart — transient errors are expected
      restart: :temporary,
      shutdown: 5_000
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Returns the number of active sub-agents.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> length()
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end

  defp run_sub_agent(dispatch_msg) do
    # This is where the actual sub-agent execution happens.
    #
    # In a full implementation:
    # 1. Look up the sub-agent module by name (e.g., :terrier -> CodePuppyControl.Agents.Pack.Terrier)
    # 2. Initialize the agent context with the task description, params, and tools
    # 3. Run the LLM-backed agent loop
    # 4. Stream progress updates back to the leader
    # 5. Return the final result
    #
    # For the prototype, we just acknowledge the dispatch.
    run_id = Map.get(dispatch_msg, :run_id, "unknown")
    sub_agent = Map.get(dispatch_msg, :sub_agent, :unknown)
    leader_pid = Map.get(dispatch_msg, :leader_pid)

    Logger.info("SubAgentPool: running #{sub_agent} (run_id=#{run_id})")

    # Send progress updates to leader
    if leader_pid do
      GenServer.cast(
        leader_pid,
        {:progress, run_id,
         %{
           type: :milestone,
           message: "Sub-agent #{sub_agent} starting execution",
           timestamp: DateTime.utc_now()
         }}
      )
    end

    # TODO(code_puppy-yge.2): Replace with actual sub-agent execution.
    # See docs/distributed-packs.md §12.2 for the execution model.
    result = %{
      status: :success,
      run_id: run_id,
      output: "Completed #{sub_agent} execution",
      duration_ms: 0,
      artifacts: []
    }

    # Send result back to leader
    if leader_pid do
      GenServer.cast(leader_pid, {:result, run_id, result})
    end

    result
  end
end
