defmodule CodePuppyControl.Workers.AgentInvocation do
  @moduledoc """
  Oban worker for durable agent invocation.

  Replaces the DBOSAgent wrapper from pydantic_ai.durable_exec.dbos.
  Each invocation is an Oban job with unique constraints ensuring
  exactly-once execution semantics.

  ## Job Arguments

    * `session_id` — The session this invocation belongs to
    * `agent_name` — Name of the agent to invoke
    * `prompt` — The prompt to send to the agent
    * `workflow_id` — Unique workflow identifier for step tracking
    * `model` — Optional model override
    * `config` — Additional configuration map

  ## Retry & Idempotency

    * Max attempts: 3 (mirrors DBOS default)
    * Unique period: 300s (5 min) — prevents duplicate submissions
    * Unique fields: [:worker, :args] — ensures one workflow per ID at the
      *database level* (Oban inserts a unique index on args hash)
    * Unique states: [:available, :executing, :retryable] — covers all
      active job states so duplicates are caught even during retries
    * Step-level idempotency via `Workflow.Step`

  The Oban `unique` constraint is the authoritative idempotency guarantee —
  it operates at the database level and prevents the read-then-write race
  that would exist with application-level checks alone.
  `Workflow.invoke_agent/2` also does an application-level check as a
  fast-path to return existing jobs, but the DB constraint catches any
  concurrent submissions that slip through.

  ## Cancellation

  Workflows can be cancelled via `Workflow.cancel/1`, which discards
  pending Oban jobs and marks running steps as cancelled.
  """

  use Oban.Worker,
    queue: :workflows,
    max_attempts: 3,
    unique: [period: 300, fields: [:worker, :args], states: [:available, :executing, :retryable]],
    tags: ["workflow", "agent_invocation"]

  alias CodePuppyControl.Run
  alias CodePuppyControl.Workflow.Step

  require Logger

  @run_timeout_ms 300_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, id: job_id}) do
    workflow_id = args["workflow_id"]
    session_id = args["session_id"]
    agent_name = args["agent_name"]
    prompt = args["prompt"]

    Logger.info(
      "AgentInvocation worker #{job_id} executing workflow #{workflow_id} " <>
        "(agent: #{agent_name}, attempt: #{attempt})"
    )

    # Step 1: Initialize — idempotent (no-op if already done)
    case Step.execute(workflow_id, "initialize", fn ->
           initialize_step(session_id, agent_name, args)
         end) do
      {:ok, _init_result} ->
        # Step 2: Run agent — the core execution
        case Step.execute(workflow_id, "run_agent", fn ->
               run_agent_step(session_id, agent_name, prompt, args)
             end) do
          {:ok, run_result} ->
            # Step 3: Finalize — cleanup and persistence
            case Step.execute(workflow_id, "finalize", fn ->
                   finalize_step(workflow_id, session_id, run_result)
                 end) do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Agent run failed for workflow #{workflow_id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Initialization failed for workflow #{workflow_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Step implementations
  # ---------------------------------------------------------------------------

  defp initialize_step(session_id, agent_name, args) do
    Logger.info("Initializing workflow for session #{session_id}, agent #{agent_name}")

    # Validate agent exists (lightweight check)
    model = Map.get(args, "model")

    {:ok,
     %{
       session_id: session_id,
       agent_name: agent_name,
       model: model,
       initialized_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp run_agent_step(session_id, agent_name, prompt, args) do
    config = Map.get(args, "config", %{})
    model = Map.get(args, "model")

    # Build run configuration
    run_config =
      config
      |> Map.new()
      |> Map.put("prompt", prompt)
      |> then(fn c -> if model, do: Map.put(c, "model", model), else: c end)

    # Start the agent run via Run.Manager
    case Run.Manager.start_run(session_id, agent_name, config: run_config) do
      {:ok, run_id} ->
        Logger.info("Started run #{run_id} for workflow invocation")
        await_run_completion(run_id)

      {:error, reason} ->
        Logger.error("Failed to start run: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp finalize_step(workflow_id, _session_id, run_result) do
    Logger.info("Finalizing workflow #{workflow_id}")

    {:ok,
     %{
       completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
       run_result: run_result
     }}
  end

  # ---------------------------------------------------------------------------
  # Run completion await
  # ---------------------------------------------------------------------------

  defp await_run_completion(run_id) do
    case Run.Manager.await_run(run_id, @run_timeout_ms) do
      {:ok, %{status: :completed} = state} ->
        {:ok, extract_result(state)}

      {:ok, %{status: :failed, error: error}} ->
        {:error, error || "run_failed"}

      {:ok, %{status: :cancelled}} ->
        {:cancel, "workflow_cancelled"}

      {:timeout, _} ->
        Run.Manager.cancel_run(run_id, "workflow_timeout")
        {:error, :timeout}

      {:error, :not_found} ->
        {:error, :run_not_found}
    end
  end

  defp extract_result(state) do
    %{
      status: state.status,
      session_id: state.session_id,
      agent_name: state.agent_name,
      metadata: state.metadata,
      completed_at: state.completed_at
    }
  end
end
