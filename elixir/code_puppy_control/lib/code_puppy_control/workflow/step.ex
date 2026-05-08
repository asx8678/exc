defmodule CodePuppyControl.Workflow.Step do
  @moduledoc """
  Ecto schema for tracking workflow steps with idempotency guarantees.

  Replaces DBOS step-level durability. Each step is keyed by
  {workflow_id, step_name} and can only be completed once — retrying
  a completed step returns the stored result (exactly-once semantics).

  ## Lifecycle

      1. `pending`   — step created, not yet started
      2. `running`   — step is executing
      3. `completed` — step finished successfully (result stored)
      4. `failed`    — step failed (retriable if attempts < max_attempts)
      5. `cancelled` — step was cancelled by workflow cancellation

  ## Idempotency

  The `{workflow_id, step_name}` unique constraint ensures that
  completing the same step twice is a no-op. The `result` column
  stores the step output so re-execution can return the cached value.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodePuppyControl.Repo

  @valid_states ~w(pending running completed failed cancelled)

  schema "workflow_steps" do
    field(:workflow_id, :string)
    field(:step_name, :string)
    field(:state, :string, default: "pending")
    field(:attempt, :integer, default: 0)
    field(:max_attempts, :integer, default: 3)
    field(:result, :map)
    field(:error, :string)
    field(:started_at, :utc_datetime)
    field(:completed_at, :utc_datetime)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          workflow_id: String.t(),
          step_name: String.t(),
          state: String.t(),
          attempt: non_neg_integer(),
          max_attempts: pos_integer(),
          result: map() | nil,
          error: String.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Creates a changeset for a workflow step.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :workflow_id,
      :step_name,
      :state,
      :attempt,
      :max_attempts,
      :result,
      :error,
      :started_at,
      :completed_at
    ])
    |> validate_required([:workflow_id, :step_name])
    |> validate_inclusion(:state, @valid_states)
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> unique_constraint([:workflow_id, :step_name],
      name: :workflow_steps_workflow_id_step_name_index
    )
  end

  # ---------------------------------------------------------------------------
  # Query helpers
  # ---------------------------------------------------------------------------

  @doc """
  Finds a step by workflow_id and step_name.
  """
  @spec find(String.t(), String.t()) :: t() | nil
  def find(workflow_id, step_name) do
    Repo.get_by(__MODULE__, workflow_id: workflow_id, step_name: step_name)
  end

  @doc """
  Returns all steps for a workflow, ordered by insertion.
  """
  @spec list_for_workflow(String.t()) :: [t()]
  def list_for_workflow(workflow_id) do
    import Ecto.Query

    __MODULE__
    |> where([s], s.workflow_id == ^workflow_id)
    |> order_by([s], asc: s.inserted_at)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # State machine transitions
  # ---------------------------------------------------------------------------

  @doc """
  Starts a step: `pending` → `running`.

  Returns `{:ok, step}` on success, `{:error, reason}` on failure.
  Idempotent: starting an already-running step returns `{:ok, step}`.
  """
  @spec start(t()) :: {:ok, t()} | {:error, term()}
  def start(%__MODULE__{state: "running"} = step), do: {:ok, step}
  def start(%__MODULE__{state: "completed"} = step), do: {:ok, step}

  def start(%__MODULE__{state: "pending"} = step) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    step
    |> changeset(%{state: "running", started_at: now, attempt: step.attempt + 1})
    |> Repo.update()
  end

  def start(%__MODULE__{state: "cancelled"} = _step), do: {:error, :cancelled}

  def start(%__MODULE__{state: "failed"} = step) do
    if step.attempt < step.max_attempts do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      step
      |> changeset(%{state: "running", started_at: now, attempt: step.attempt + 1})
      |> Repo.update()
    else
      {:error, :max_attempts_exceeded}
    end
  end

  @doc """
  Completes a step: `running` → `completed`.

  Stores the result for idempotent re-execution.
  """
  @spec complete(t(), map()) :: {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{state: "completed"} = step), do: {:ok, step}

  def complete(%__MODULE__{state: "running"} = step, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    step
    |> changeset(%{state: "completed", result: result, completed_at: now})
    |> Repo.update()
  end

  @doc """
  Fails a step: `running` → `failed`.

  If attempt < max_attempts, the step is retriable.
  """
  @spec fail(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{state: "running"} = step, error) do
    step
    |> changeset(%{state: "failed", error: truncate_error(error)})
    |> Repo.update()
  end

  def fail(%__MODULE__{state: "pending"} = step, error) do
    step
    |> changeset(%{state: "failed", error: truncate_error(error), attempt: step.attempt + 1})
    |> Repo.update()
  end

  def fail(step, _error), do: {:ok, step}

  @doc """
  Cancels a step: `pending` → `cancelled` or `running` → `cancelled`.

  Used by `Workflow.cancel/1` to mark steps as cancelled during workflow
  cancellation. Terminal states (completed, failed, cancelled) are no-ops.
  """
  @spec cancel(t()) :: {:ok, t()} | {:error, term()}
  def cancel(%__MODULE__{state: "pending"} = step) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    step
    |> changeset(%{state: "cancelled", completed_at: now})
    |> Repo.update()
  end

  def cancel(%__MODULE__{state: "running"} = step) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    step
    |> changeset(%{state: "cancelled", completed_at: now})
    |> Repo.update()
  end

  # Terminal states — no-op (already completed, failed, or cancelled)
  def cancel(%__MODULE__{state: state} = step)
      when state in ["completed", "failed", "cancelled"] do
    {:ok, step}
  end

  @doc """
  Returns `true` if the step can be retried.
  """
  @spec retriable?(t()) :: boolean()
  def retriable?(%__MODULE__{state: "failed", attempt: attempt, max_attempts: max}),
    do: attempt < max

  def retriable?(_), do: false

  # ---------------------------------------------------------------------------
  # Idempotent step execution
  # ---------------------------------------------------------------------------

  @doc """
  Executes a step with idempotency guarantees.

  - If the step is already `completed`, returns `{:ok, result}` immediately.
  - If the step is `pending` or `failed` (retriable), starts it and runs `fun.()`.
  - On success, marks the step complete and stores the result.
  - On failure, marks the step failed.

  This mirrors DBOS's step-level idempotency: the same step always
  returns the same result, even if the workflow is re-executed.
  """
  @spec execute(String.t(), String.t(), keyword(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def execute(workflow_id, step_name, opts \\ [], fun) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    # Find or create step (idempotent creation)
    step =
      case find(workflow_id, step_name) do
        nil ->
          attrs = %{
            workflow_id: workflow_id,
            step_name: step_name,
            max_attempts: max_attempts
          }

          %__MODULE__{}
          |> changeset(attrs)
          |> Repo.insert!()

        existing ->
          existing
      end

    # Already completed? Return cached result (exactly-once)
    case step.state do
      "completed" ->
        {:ok, step.result || %{}}

      "cancelled" ->
        {:error, :cancelled}

      state when state in ["pending", "failed"] ->
        do_execute_step(step, fun)

      "running" ->
        # Another process is running this step — wait and poll
        # In practice, Oban's unique constraints prevent concurrent execution
        {:error, :step_in_progress}
    end
  end

  defp do_execute_step(step, fun) do
    case start(step) do
      {:ok, step} ->
        case fun.() do
          {:ok, result} ->
            case complete(step, result) do
              {:ok, _completed_step} -> {:ok, result}
              error -> error
            end

          {:error, reason} ->
            fail(step, inspect(reason))
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp truncate_error(error) when is_binary(error) do
    if String.length(error) > 1000, do: String.slice(error, 0, 1000) <> "...", else: error
  end

  defp truncate_error(error), do: truncate_error(inspect(error))
end
