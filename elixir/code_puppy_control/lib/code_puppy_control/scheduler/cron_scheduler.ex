defmodule CodePuppyControl.Scheduler.CronScheduler do
  @moduledoc """
  GenServer that periodically checks for due scheduled tasks.

  This process:
  1. Runs on a configurable interval (default: every minute)
  2. Queries the database for enabled tasks with schedules
  3. Determines which tasks are due to run
  4. Enqueues Oban jobs for due tasks

  ## Configuration

    * `:check_interval` - Milliseconds between checks (default: 60_000)

  ## Supervision

  Started under the application supervisor with restart: :permanent.
  Crash recovery is handled by Oban's built-in job rescue functionality
  (Oban.Plugins.Lifeline), not by this process.
  """

  use GenServer

  alias CodePuppyControl.Repo
  alias CodePuppyControl.Scheduler.{Task, Worker}

  import Ecto.Query

  require Logger

  @default_check_interval 60_000

  # Client API

  @doc """
  Starts the CronScheduler GenServer.

  ## Options

    * `:check_interval` - Interval in milliseconds between schedule checks
    * `:name` - Process name (defaults to __MODULE__)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Triggers an immediate check of scheduled tasks.

  This can be used to force a schedule check outside the normal interval,
  useful for testing or manual task triggering.
  """
  @spec check_now(GenServer.server()) :: :ok
  def check_now(server \\ __MODULE__) do
    GenServer.cast(server, :check_now)
  end

  @doc """
  Gets the current scheduler state.
  """
  @spec get_state(GenServer.server()) :: %{
          check_interval: non_neg_integer(),
          last_check_at: DateTime.t() | nil,
          tasks_enqueued: non_neg_integer()
        }
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval, @default_check_interval)

    state = %{
      check_interval: check_interval,
      last_check_at: nil,
      tasks_enqueued: 0
    }

    Logger.info("CronScheduler started with #{check_interval}ms check interval")

    # Schedule first check
    schedule_check(check_interval)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    new_state = check_and_enqueue_tasks(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_schedules, state) do
    new_state = check_and_enqueue_tasks(state)

    # Schedule next check
    schedule_check(state.check_interval)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("CronScheduler received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  @spec schedule_check(non_neg_integer()) :: reference()
  defp schedule_check(interval) do
    Process.send_after(self(), :check_schedules, interval)
  end

  @spec check_and_enqueue_tasks(map()) :: map()
  defp check_and_enqueue_tasks(state) do
    now = DateTime.utc_now()

    # Query for enabled tasks that have a schedule
    tasks =
      Task
      |> where([t], t.enabled == true)
      |> where([t], not is_nil(t.schedule) or t.schedule_type in ["interval", "hourly", "daily"])
      |> Repo.all()

    # Filter to tasks that should run now
    due_tasks =
      Enum.filter(tasks, fn task ->
        Task.should_run?(task, now)
      end)

    enqueued_count =
      Enum.reduce(due_tasks, 0, fn task, count ->
        case enqueue_task(task) do
          {:ok, _job} ->
            count + 1

          {:error, reason} ->
            Logger.error("Failed to enqueue task #{task.id}: #{inspect(reason)}")
            count
        end
      end)

    if enqueued_count > 0 do
      Logger.info("CronScheduler enqueued #{enqueued_count} task(s) for execution")
    end

    %{
      state
      | last_check_at: now,
        tasks_enqueued: state.tasks_enqueued + enqueued_count
    }
  end

  @spec enqueue_task(Task.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  defp enqueue_task(task) do
    Logger.debug("Enqueueing task #{task.id} (#{task.name}) for execution")

    %{task_id: task.id}
    |> Worker.new(
      queue: :scheduled,
      meta: %{
        task_name: task.name,
        agent_name: task.agent_name
      }
    )
    |> Oban.insert()
  end
end
