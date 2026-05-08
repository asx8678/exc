defmodule CodePuppyControl.Scheduler.Worker do
  @moduledoc """
  Oban worker for executing scheduled tasks.

  This worker is responsible for:
  1. Fetching the task configuration from the database
  2. Validating the task is still enabled
  3. Starting a run via Run.Manager
  4. Waiting for completion and updating task status
  5. Handling timeouts and retries

  ## Job Arguments

    * `task_id` - The ID of the scheduled task to execute

  ## Configuration

  * Queue: `:scheduled`
  * Max attempts: 3
  * Unique period: 60 seconds (prevents duplicate runs)
  """

  use Oban.Worker,
    queue: :scheduled,
    max_attempts: 3,
    unique: [period: 60, keys: [:task_id]],
    tags: ["scheduler"]

  alias CodePuppyControl.Repo
  alias CodePuppyControl.Scheduler.Task
  alias CodePuppyControl.Run.Manager

  require Logger

  @run_timeout_ms 300_000

  @impl Oban.Worker
  @doc """
  Executes the scheduled task.

  ## Parameters

    * `job` - The Oban job containing the task_id in args

  ## Returns

    * `:ok` - Task executed successfully
    * `{:error, reason}` - Task failed and may be retried
    * `{:cancel, reason}` - Task should be cancelled and not retried
  """
  def perform(%Oban.Job{args: %{"task_id" => task_id}, attempt: attempt}) do
    Logger.info("Scheduler worker executing task #{task_id} (attempt #{attempt})")

    # Fetch task with lock to prevent race conditions during updates
    case Repo.get(Task, task_id) do
      nil ->
        Logger.warning("Scheduled task #{task_id} not found, cancelling job")
        {:cancel, "task_not_found"}

      task ->
        execute_task(task)
    end
  end

  @spec execute_task(Task.t()) :: Oban.Worker.result()
  defp execute_task(task) do
    if task.enabled do
      Logger.info("Executing scheduled task: #{task.name} (#{task.id})")

      # Mark as running and update last_run_at
      # Truncate microseconds for SQLite compatibility
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(
          last_status: "running",
          last_run_at: now,
          last_error: nil,
          last_exit_code: nil
        )
        |> Repo.update()

      # Build run configuration
      run_config =
        task.config
        |> Map.new()
        |> Map.put("prompt", task.prompt)
        |> Map.put("working_directory", task.working_directory)

      # Add model if specified
      run_config =
        if task.model do
          Map.put(run_config, "model", task.model)
        else
          run_config
        end

      # Log file path for reference
      if task.log_file do
        Logger.info("Task #{task.id} log file: #{task.log_file}")
      end

      # Start the agent run
      case Manager.start_run("scheduler", task.agent_name, config: run_config) do
        {:ok, run_id} ->
          Logger.info("Started run #{run_id} for task #{task.id}")
          await_run_completion(task, run_id)

        {:error, reason} ->
          Logger.error("Failed to start run for task #{task.id}: #{inspect(reason)}")
          mark_failed(task, "Failed to start run: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.info("Skipping disabled task: #{task.name}")
      {:ok, :skipped}
    end
  end

  @spec await_run_completion(Task.t(), String.t()) :: Oban.Worker.result()
  defp await_run_completion(task, run_id) do
    case Manager.await_run(run_id, @run_timeout_ms) do
      {:ok, %{status: :completed} = state} ->
        Logger.info("Task #{task.id} completed successfully")
        mark_success(task, state)
        :ok

      {:ok, %{status: :failed, error: error} = state} ->
        Logger.error("Task #{task.id} failed: #{inspect(error)}")
        mark_failed(task, error, state)
        {:error, error}

      {:ok, %{status: :cancelled} = state} ->
        Logger.warning("Task #{task.id} was cancelled")
        mark_cancelled(task, state)
        {:cancel, "cancelled"}

      {:timeout, _} ->
        Logger.error("Task #{task.id} timed out after #{@run_timeout_ms}ms")
        Manager.cancel_run(run_id, "scheduler_timeout")
        mark_failed(task, "timeout")
        {:error, :timeout}

      {:error, :not_found} ->
        # Run process died unexpectedly
        Logger.error("Run #{run_id} not found during execution of task #{task.id}")
        mark_failed(task, "run process terminated unexpectedly")
        {:error, :run_not_found}
    end
  end

  @spec mark_success(Task.t(), map()) :: {:ok, Task.t()}
  defp mark_success(task, _state) do
    {:ok, updated_task} =
      task
      |> Ecto.Changeset.change(
        last_status: "success",
        last_error: nil,
        run_count: task.run_count + 1
      )
      |> Repo.update()

    Logger.debug("Marked task #{task.id} as successful, run_count: #{updated_task.run_count}")
    {:ok, updated_task}
  end

  @spec mark_failed(Task.t(), term(), map() | nil) :: {:ok, Task.t()}
  defp mark_failed(task, error, state \\ nil) do
    error_string =
      if is_binary(error) do
        error
      else
        inspect(error)
      end

    error_string =
      if String.length(error_string) > 1000 do
        String.slice(error_string, 0, 1000) <> "..."
      else
        error_string
      end

    # Extract exit code from state if available
    exit_code =
      case state do
        %{metadata: %{"exit_code" => code}} -> code
        _ -> nil
      end

    {:ok, updated_task} =
      task
      |> Ecto.Changeset.change(
        last_status: "failed",
        last_error: error_string,
        last_exit_code: exit_code,
        run_count: task.run_count + 1
      )
      |> Repo.update()

    Logger.debug("Marked task #{task.id} as failed, run_count: #{updated_task.run_count}")
    {:ok, updated_task}
  end

  @spec mark_cancelled(Task.t(), map()) :: {:ok, Task.t()}
  defp mark_cancelled(task, _state) do
    {:ok, updated_task} =
      task
      |> Ecto.Changeset.change(
        last_status: "cancelled",
        run_count: task.run_count + 1
      )
      |> Repo.update()

    Logger.debug("Marked task #{task.id} as cancelled, run_count: #{updated_task.run_count}")
    {:ok, updated_task}
  end
end
