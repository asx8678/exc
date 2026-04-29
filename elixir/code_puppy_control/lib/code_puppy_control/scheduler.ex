defmodule CodePuppyControl.Scheduler do
  @moduledoc """
  Public API for managing scheduled tasks in the CodePuppy Control system.

  This module provides functions for creating, updating, deleting, and
  querying scheduled tasks, as well as triggering immediate task execution.

  ## Overview

  Scheduled tasks are persisted to the database and executed via Oban jobs.
  The scheduler supports:

    * Interval-based schedules (e.g., "30m", "1h", "2d")
    * Hourly and daily schedules
    * Cron expressions (e.g., "0 9 * * *" for 9am daily)
    * One-shot execution (manual trigger only)

  ## Usage Examples

      # Create a new scheduled task
      {:ok, task} = Scheduler.create_task(%{
        name: "daily-cleanup",
        agent_name: "code-puppy",
        prompt: "Clean up old log files",
        schedule_type: "daily"
      })

      # List all tasks
      tasks = Scheduler.list_tasks()

      # Run a task immediately (outside of schedule)
      {:ok, job} = Scheduler.run_task_now(task)

      # Get task execution history
      history = Scheduler.get_task_history(task.id)

  ## Architecture

  The scheduler consists of:

    * `CodePuppyControl.Scheduler.Task` - Ecto schema for task definitions
    * `CodePuppyControl.Scheduler.Worker` - Oban worker for task execution
    * `CodePuppyControl.Scheduler.CronScheduler` - GenServer for periodic schedule checks
    * This module (`CodePuppyControl.Scheduler`) - Public API
  """

  alias CodePuppyControl.Repo
  alias CodePuppyControl.Scheduler.{CronScheduler, Task, Worker}

  import Ecto.Query

  require Logger

  @type task_attrs :: %{
          required(:name) => String.t(),
          required(:agent_name) => String.t(),
          required(:prompt) => String.t(),
          optional(:description) => String.t(),
          optional(:model) => String.t(),
          optional(:config) => map(),
          optional(:schedule) => String.t() | nil,
          optional(:schedule_type) => String.t(),
          optional(:schedule_value) => String.t(),
          optional(:enabled) => boolean(),
          optional(:working_directory) => String.t(),
          optional(:log_file) => String.t()
        }

  # Task CRUD Operations

  @doc """
  Returns a list of all scheduled tasks, ordered by insertion date.
  """
  @spec list_tasks() :: [Task.t()]
  def list_tasks do
    Task
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns a list of enabled scheduled tasks.
  """
  @spec list_enabled_tasks() :: [Task.t()]
  def list_enabled_tasks do
    Task
    |> where([t], t.enabled == true)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns a single task by ID.

  ## Returns

    * `{:ok, task}` - Task found
    * `{:error, :not_found}` - Task not found
  """
  @spec get_task(integer()) :: {:ok, Task.t()} | {:error, :not_found}
  def get_task(id) do
    case Repo.get(Task, id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @doc """
  Returns a single task by ID, raising on failure.
  """
  @spec get_task!(integer()) :: Task.t()
  def get_task!(id) do
    Repo.get!(Task, id)
  end

  @doc """
  Returns a task by its unique name.

  ## Returns

    * `{:ok, task}` - Task found
    * `{:error, :not_found}` - Task not found
  """
  @spec get_task_by_name(String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def get_task_by_name(name) do
    case Repo.get_by(Task, name: name) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @doc """
  Creates a new scheduled task.

  ## Examples

      {:ok, task} = Scheduler.create_task(%{
        name: "hourly-sync",
        agent_name: "sync-agent",
        prompt: "Sync data with remote API",
        schedule_type: "hourly"
      })

      # With cron schedule
      {:ok, task} = Scheduler.create_task(%{
        name: "daily-report",
        agent_name: "reporter",
        prompt: "Generate daily report",
        schedule_type: "cron",
        schedule: "0 9 * * *"
      })
  """
  @spec create_task(task_attrs()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing task.

  ## Examples

      Scheduler.update_task(task, %{enabled: false})
      Scheduler.update_task(task, %{schedule_value: "30m"})
  """
  @spec update_task(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a scheduled task.
  """
  @spec delete_task(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete_task(%Task{} = task) do
    Repo.delete(task)
  end

  # Task State Management

  @doc """
  Enables a disabled task.
  """
  @spec enable_task(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def enable_task(%Task{} = task) do
    update_task(task, %{enabled: true})
  end

  @doc """
  Disables an enabled task.
  """
  @spec disable_task(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def disable_task(%Task{} = task) do
    update_task(task, %{enabled: false})
  end

  @doc """
  Toggles the enabled state of a task.
  """
  @spec toggle_task(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def toggle_task(%Task{enabled: enabled} = task) do
    update_task(task, %{enabled: !enabled})
  end

  # Task Execution

  @doc """
  Runs a task immediately, outside of its normal schedule.

  This creates an Oban job that executes as soon as a worker is available.

  ## Returns

    * `{:ok, job}` - Job created successfully
    * `{:error, reason}` - Failed to create job
  """
  @spec run_task_now(Task.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def run_task_now(%Task{} = task) do
    Logger.info("Manually triggering task #{task.id} (#{task.name})")

    %{task_id: task.id}
    |> Worker.new(
      queue: :scheduled,
      scheduled_at: DateTime.utc_now(),
      meta: %{
        task_name: task.name,
        agent_name: task.agent_name,
        manual_trigger: true
      }
    )
    |> Oban.insert()
  end

  @spec run_task_now(integer()) :: {:ok, Oban.Job.t()} | {:error, :not_found | term()}
  def run_task_now(task_id) when is_integer(task_id) do
    case get_task(task_id) do
      {:ok, task} -> run_task_now(task)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # Task History

  @doc """
  Gets the execution history for a task from Oban jobs.

  Returns a list of Oban jobs associated with this task, ordered by
  most recent first.

  ## Options

    * `:limit` - Maximum number of records to return (default: 10)
    * `:include_discarded` - Include discarded/cancelled jobs (default: false)
  """
  @spec get_task_history(integer(), keyword()) :: [Oban.Job.t()]
  def get_task_history(task_id, opts \\ []) when is_integer(task_id) do
    limit = Keyword.get(opts, :limit, 10)
    include_discarded = Keyword.get(opts, :include_discarded, false)

    base_query =
      Oban.Job
      |> where([j], j.worker == "CodePuppyControl.Scheduler.Worker")
      |> where([j], fragment("?->>'task_id' = ?", j.args, ^task_id))

    query =
      if include_discarded do
        base_query
      else
        base_query |> where([j], j.state != "discarded")
      end

    query
    |> order_by([j], desc: j.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # Scheduler Control

  @doc """
  Forces an immediate schedule check.

  This causes the CronScheduler to evaluate all enabled tasks
  and enqueue any that are due. No-op when CronScheduler is not
  running (e.g. in test environment where it is excluded from
  the supervision tree to avoid Ecto-sandbox contention).
  """
  @spec force_check() :: :ok | {:error, :not_running}
  def force_check do
    if Process.whereis(CronScheduler) do
      CronScheduler.check_now()
    else
      {:error, :not_running}
    end
  end

  @doc """
  Gets the current status of the CronScheduler.

  Returns a map with `:running` set to `false` when the
  CronScheduler is not started (e.g. in test environment).
  """
  @spec scheduler_status() :: map()
  def scheduler_status do
    if Process.whereis(CronScheduler) do
      CronScheduler.get_state() |> Map.put(:running, true)
    else
      %{check_interval: 0, last_check_at: nil, tasks_enqueued: 0, running: false}
    end
  end

  # Statistics

  @doc """
  Returns statistics about scheduled tasks.

  Returns a map with counts for:
    * `:total` - Total number of tasks
    * `:enabled` - Number of enabled tasks
    * `:disabled` - Number of disabled tasks
    * `:with_schedule` - Number of tasks with recurring schedules
    * `:one_shot` - Number of one-shot tasks
    * `:last_24h_runs` - Number of runs in last 24 hours
  """
  @spec statistics() :: map()
  def statistics do
    now = DateTime.utc_now()
    twenty_four_hours_ago = DateTime.add(now, -24 * 60 * 60, :second)

    %{
      total: Repo.aggregate(Task, :count, :id),
      enabled: Repo.one(from(t in Task, where: t.enabled == true, select: count(t.id))),
      disabled: Repo.one(from(t in Task, where: t.enabled == false, select: count(t.id))),
      with_schedule:
        Repo.one(
          from(t in Task,
            where: t.enabled == true and not is_nil(t.schedule),
            select: count(t.id)
          )
        ),
      one_shot:
        Repo.one(
          from(t in Task,
            where: t.schedule_type == "one_shot",
            select: count(t.id)
          )
        ),
      last_24h_runs:
        Repo.one(
          from(j in Oban.Job,
            where: j.worker == "CodePuppyControl.Scheduler.Worker",
            where: j.state == "completed",
            where: j.completed_at >= ^twenty_four_hours_ago,
            select: count(j.id)
          )
        )
    }
  end
end
