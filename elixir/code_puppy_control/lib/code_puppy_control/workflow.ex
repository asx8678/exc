defmodule CodePuppyControl.Workflow do
  @moduledoc """
  Public API for durable workflow execution.

  Replaces Python DBOS workflows with Oban-backed durable execution.
  Provides:

    * **Workflow persistence** — Oban jobs are persisted to SQLite;
      workflows survive process crashes and restarts.
    * **Retry semantics** — Configurable max_attempts per workflow;
      Oban automatically retries failed jobs with backoff.
    * **Step-level idempotency** — Each workflow is decomposed into
      named steps tracked in `workflow_steps`; re-executing a completed
      step returns the cached result (exactly-once semantics).
    * **Cancellation** — Workflows can be cancelled, which discards
      pending Oban jobs and marks in-progress steps as cancelled.

  ## Usage

      # Start a durable workflow
      {:ok, job} = Workflow.invoke_agent(%{
        session_id: "sess-123",
        agent_name: "code-puppy",
        prompt: "Fix the bug",
        workflow_id: "wf-abc-0"
      })

      # Check workflow status
      {:ok, status} = Workflow.get_status("wf-abc-0")

      # Cancel a workflow
      :ok = Workflow.cancel("wf-abc-0")

  ## Architecture

      ┌─────────────────┐
      │ Workflow API    │  ← This module (facade)
      └────────┬────────┘
               │
      ┌────────▼────────┐
      │ Oban Job        │  ← Workers.AgentInvocation
      │ (persistent)    │
      └────────┬────────┘
               │
      ┌────────▼────────┐
      │ Workflow.Step   │  ← Step-level idempotency
      │ (Ecto schema)   │
      └─────────────────┘

  ## Migration from DBOS

  | DBOS Concept          | Oban Equivalent                  |
  |-----------------------|---------------------------------|
  | `DBOS()`              | `Oban` (already in app tree)    |
  | `DBOSAgent`           | `Workers.AgentInvocation`       |
  | `SetWorkflowID(id)`   | `unique: [keys: [:workflow_id]]`|
  | `DBOS.cancel_workflow`| `Workflow.cancel/1`             |
  | Step durability       | `Workflow.Step` (Ecto)          |
  | System DB (Postgres)  | `oban_jobs` (SQLite)             |
  """

  alias CodePuppyControl.Repo
  alias CodePuppyControl.Workers.AgentInvocation
  alias CodePuppyControl.Workflow.Step

  import Ecto.Query

  require Logger

  # -------------------------------------------------------------------------
  # Workflow invocation
  # -------------------------------------------------------------------------

  @type invoke_opts :: [
          {:max_attempts, pos_integer()},
          {:queue, atom()},
          {:priority, non_neg_integer()},
          {:scheduled_at, DateTime.t()},
          {:meta, map()},
          {:tags, [String.t()]}
        ]

  @doc """
  Starts a durable agent invocation workflow.

  Creates an Oban job that will execute the agent invocation with
  step-level idempotency. The workflow_id ensures exactly-once
  execution: calling this function twice with the same workflow_id
  returns the existing job instead of creating a duplicate.

  ## Options

    * `:max_attempts` — Max retry attempts (default: 3)
    * `:queue` — Oban queue (default: `:workflows`)
    * `:priority` — Job priority, 0 = highest (default: 0)
    * `:scheduled_at` — Schedule for future execution
    * `:meta` — Additional metadata for the job
    * `:tags` — Tags for job categorization

  ## Returns

    * `{:ok, job}` — Job created (or existing job returned if duplicate)
    * `{:error, changeset}` — Validation error

  ## Examples

      {:ok, job} = Workflow.invoke_agent(%{
        session_id: "sess-123",
        agent_name: "code-puppy",
        prompt: "Refactor the module",
        workflow_id: "wf-unique-42"
      })
  """
  @spec invoke_agent(map(), invoke_opts()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def invoke_agent(params, opts \\ []) when is_map(params) do
    # JSON-RPC params arrive string-keyed; Elixir callers may use atom keys.
    # Normalize to support both without mutating the caller's map.
    workflow_id =
      Map.get(params, :workflow_id) || Map.get(params, "workflow_id") ||
        raise KeyError, key: :workflow_id, term: params

    # Idempotency: Oban's unique constraint (period: 300, fields: [:worker, :args])
    # provides DB-level dedup — Oban.insert/1 will return {:ok, job} even on
    # duplicate, so we rely on the database constraint rather than a
    # read-then-write race. The application-level check below is a fast-path
    # to return the existing job without hitting the insert path, but it is
    # NOT the sole idempotency guarantee.
    case find_job_by_workflow_id(workflow_id) do
      %Oban.Job{} = job ->
        Logger.info("Workflow #{workflow_id} already exists as job #{job.id}, returning existing")
        {:ok, job}

      nil ->
        # Create the Oban job
        max_attempts = Keyword.get(opts, :max_attempts, 3)
        queue = Keyword.get(opts, :queue, :workflows)
        priority = Keyword.get(opts, :priority, 0)
        meta = Keyword.get(opts, :meta, %{})
        tags = Keyword.get(opts, :tags, ["workflow"])

        job_opts = [
          queue: queue,
          max_attempts: max_attempts,
          priority: priority,
          tags: tags,
          meta: Map.merge(meta, %{workflow_id: workflow_id})
        ]

        job_opts =
          case Keyword.get(opts, :scheduled_at) do
            nil -> job_opts
            scheduled_at -> Keyword.put(job_opts, :scheduled_at, scheduled_at)
          end

        # Ensure args are string-keyed for consistent JSON serialization
        # and Oban unique constraint matching.
        normalized_params = normalize_keys(params)

        normalized_params
        |> AgentInvocation.new(job_opts)
        |> Oban.insert()
    end
  end

  # -------------------------------------------------------------------------
  # Workflow status
  # -------------------------------------------------------------------------

  @doc """
  Gets the status of a workflow by its workflow_id.

  Returns a map with:
    * `:workflow_id` — The workflow identifier
    * `:job` — The Oban job (if found)
    * `:steps` — List of step states
    * `:state` — Overall workflow state (`:pending`, `:running`, `:completed`, `:failed`, `:cancelled`)
  """
  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(workflow_id) do
    job = find_job_by_workflow_id(workflow_id)
    steps = Step.list_for_workflow(workflow_id)

    case {job, steps} do
      {nil, []} ->
        {:error, :not_found}

      {_job, steps} ->
        state = compute_workflow_state(job, steps)

        {:ok,
         %{
           workflow_id: workflow_id,
           job: job,
           steps: steps,
           state: state
         }}
    end
  end

  @doc """
  Gets the Oban job for a workflow.
  """
  @spec get_job(String.t()) :: Oban.Job.t() | nil
  def get_job(workflow_id), do: find_job_by_workflow_id(workflow_id)

  @doc """
  Lists all steps for a workflow.
  """
  @spec list_steps(String.t()) :: [Step.t()]
  def list_steps(workflow_id), do: Step.list_for_workflow(workflow_id)

  # -------------------------------------------------------------------------
  # Workflow cancellation
  # -------------------------------------------------------------------------

  @doc """
  Cancels a running workflow.

  1. Cancels the Oban job (prevents future execution)
  2. Marks any running steps as cancelled
  3. If a Python worker is running, sends a cancel signal

  ## Returns

    * `:ok` — Workflow cancelled (or was already terminal)
    * `{:error, :not_found}` — No workflow found with this ID
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(workflow_id) do
    Logger.info("Cancelling workflow #{workflow_id}")

    case find_job_by_workflow_id(workflow_id) do
      nil ->
        # No job — check if steps exist
        steps = Step.list_for_workflow(workflow_id)

        if steps == [] do
          {:error, :not_found}
        else
          cancel_steps(steps)
          :ok
        end

      job ->
        # Cancel the Oban job
        Oban.cancel_job(job)

        # Cancel any running steps
        steps = Step.list_for_workflow(workflow_id)
        cancel_steps(steps)

        :ok
    end
  end

  # -------------------------------------------------------------------------
  # Workflow history
  # -------------------------------------------------------------------------

  @doc """
  Gets execution history for a workflow.

  Returns a chronological list of step transitions.
  """
  @spec get_history(String.t(), keyword()) :: [map()]
  def get_history(workflow_id, _opts \\ []) do
    steps = Step.list_for_workflow(workflow_id)

    Enum.map(steps, fn step ->
      %{
        step_name: step.step_name,
        state: step.state,
        attempt: step.attempt,
        started_at: step.started_at,
        completed_at: step.completed_at,
        error: step.error
      }
    end)
  end

  @doc """
  Lists recent workflows with optional filtering.

  ## Options

    * `:limit` — Max results (default: 20)
    * `:state` — Filter by job state ("completed", "failed", etc.)
  """
  @spec list_recent(keyword()) :: [map()]
  def list_recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    state_filter = Keyword.get(opts, :state)

    query =
      Oban.Job
      |> where([j], j.worker == "CodePuppyControl.Workers.AgentInvocation")
      |> then(fn q ->
        if state_filter, do: where(q, [j], j.state == ^state_filter), else: q
      end)
      |> order_by([j], desc: j.inserted_at)
      |> limit(^limit)

    Repo.all(query)
    |> Enum.map(fn job ->
      %{
        workflow_id: job.args["workflow_id"],
        job_id: job.id,
        state: job.state,
        agent_name: job.args["agent_name"],
        session_id: job.args["session_id"],
        attempt: job.attempt,
        inserted_at: job.inserted_at,
        completed_at: job.completed_at
      }
    end)
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp find_job_by_workflow_id(workflow_id) do
    Oban.Job
    |> where([j], j.worker == "CodePuppyControl.Workers.AgentInvocation")
    |> where([j], fragment("?->>'workflow_id' = ?", j.args, ^workflow_id))
    |> order_by([j], desc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp compute_workflow_state(nil, []), do: :not_found
  defp compute_workflow_state(nil, steps), do: compute_state_from_steps(steps)

  defp compute_workflow_state(%Oban.Job{state: "completed"}, _steps), do: :completed
  defp compute_workflow_state(%Oban.Job{state: "discarded"}, _steps), do: :failed
  defp compute_workflow_state(%Oban.Job{state: "cancelled"}, _steps), do: :cancelled
  defp compute_workflow_state(%Oban.Job{state: "retryable"}, _steps), do: :running

  defp compute_workflow_state(%Oban.Job{state: "available"}, steps) do
    if Enum.any?(steps, &(&1.state == "running")), do: :running, else: :pending
  end

  defp compute_workflow_state(%Oban.Job{state: "executing"}, _steps), do: :running

  defp compute_state_from_steps(steps) do
    cond do
      Enum.any?(steps, &(&1.state == "running")) -> :running
      Enum.all?(steps, &(&1.state == "completed")) -> :completed
      Enum.any?(steps, &(&1.state == "failed")) -> :failed
      true -> :pending
    end
  end

  defp cancel_steps(steps) do
    Enum.each(steps, fn step ->
      if step.state in ["pending", "running"] do
        Step.cancel(step)
      end
    end)
  end

  # Normalizes map keys to strings for consistent JSON serialization.
  # JSON-RPC params arrive string-keyed from the wire, but Elixir callers
  # may pass atom-keyed maps. Oban stores args as JSON (string keys), so
  # normalizing ensures the unique constraint matches reliably.
  defp normalize_keys(params) when is_map(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
