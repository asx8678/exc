defmodule CodePuppyControl.Tools.SchedulerTools do
  @moduledoc """
  Tool interface for scheduler operations.

  This module provides agent-facing functions for managing scheduled tasks.
  It wraps the `CodePuppyControl.Scheduler` API with formatted string
  responses suitable for agent consumption.

  The tools follow the patterns established by the Python scheduler_tools.py,
  adapted for the Elixir Oban-based scheduler architecture.

  ## Available Tools

  - `list_tasks/0` - List all tasks with status and scheduler info
  - `create_task/1` - Create a new scheduled task
  - `delete_task/1` - Delete a task by ID or name
  - `toggle_task/1` - Toggle a task's enabled state
  - `scheduler_status/0` - Check the scheduler status
  - `run_task/1` - Run a task immediately
  - `view_log/2` - View execution history for a task
  - `force_check/0` - Force immediate schedule evaluation

  ## Architecture Notes

  Unlike the Python scheduler which used a daemon process with PID files,
  the Elixir scheduler runs as a supervised GenServer (`CronScheduler`) that
  is always active when the application is running. There is no "start/stop daemon"
  equivalent - instead, tasks are enabled/disabled individually.
  """

  alias CodePuppyControl.Scheduler
  alias CodePuppyControl.Scheduler.Task
  alias CodePuppyControl.Scheduler.CronScheduler

  @doc """
  Lists all scheduled tasks with their status and scheduler information.

  Returns a formatted markdown string suitable for agent consumption.

  ## Examples

      iex> SchedulerTools.list_tasks()
      "## Scheduler Status\\n**Daemon:** 🟢 Running\\n..."

  """
  @spec list_tasks() :: String.t()
  def list_tasks do
    tasks = Scheduler.list_tasks()
    enabled_count = Enum.count(tasks, & &1.enabled)

    # Get CronScheduler state (may be :not_running in test env)
    scheduler_state = safe_scheduler_state()
    last_check = scheduler_state[:last_check_at]
    scheduler_line = scheduler_status_line(scheduler_state)

    lines = [
      "## Scheduler Status",
      scheduler_line,
      if(last_check,
        do: "**Last Check:** #{format_datetime(last_check)}",
        else: "**Last Check:** Never"
      ),
      "**Total Tasks:** #{length(tasks)}",
      "**Enabled Tasks:** #{enabled_count}",
      ""
    ]

    if tasks == [] do
      lines =
        lines ++
          [
            "No scheduled tasks configured yet.",
            "",
            "Use `scheduler_create_task` to create one!"
          ]

      Enum.join(lines, "\n")
    else
      lines =
        lines ++
          [
            "## Tasks",
            ""
          ]

      task_lines =
        Enum.map(tasks, fn task ->
          run_status =
            case task.last_status do
              "success" -> " ✅"
              "failed" -> " ❌"
              "running" -> " ⏳"
              "cancelled" -> " 🚫"
              _ -> ""
            end

          status_icon = if task.enabled, do: "🟢", else: "🔴"
          schedule_display = format_schedule(task)

          prompt_preview =
            if String.length(task.prompt) > 100 do
              String.slice(task.prompt, 0, 100) <> "..."
            else
              task.prompt
            end

          [
            "### #{status_icon} #{task.name} (`#{task.id}`)#{run_status}",
            "- **Schedule:** #{schedule_display}",
            "- **Agent:** #{task.agent_name}",
            if(task.model, do: "- **Model:** #{task.model}", else: "- **Model:** (default)"),
            "- **Prompt:** #{prompt_preview}",
            "- **Directory:** #{task.working_directory}",
            if(task.last_run_at,
              do:
                "- **Last Run:** #{format_datetime(task.last_run_at)} (runs: #{task.run_count}, exit: #{task.last_exit_code || "N/A"})",
              else: "- **Last Run:** Never"
            ),
            ""
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")
        end)

      Enum.join(lines ++ task_lines, "\n")
    end
  end

  @doc """
  Creates a new scheduled task.

  ## Parameters

    * `:name` - Human-readable name for the task (required)
    * `:prompt` - The prompt to execute (required)
    * `:agent_name` - Agent to use, defaults to "code-puppy"
    * `:model` - Model override, empty/nil for default
    * `:schedule_type` - "interval", "hourly", "daily", or "cron"
    * `:schedule_value` - For intervals: "30m", "1h", etc. For cron: the expression
    * `:working_directory` - Working directory, defaults to "."

  ## Examples

      iex> SchedulerTools.create_task(%{name: "daily-backup", prompt: "Run backup", agent_name: "code-puppy", schedule_type: "daily"})
      "✅ **Task Created Successfully!**\\n..."

  """
  @spec create_task(map()) :: String.t()
  def create_task(attrs) do
    attrs =
      attrs
      |> Map.put_new(:agent_name, attrs[:agent] || "code-puppy")
      |> Map.delete(:agent)
      |> Map.put_new(:schedule, attrs[:schedule_value])
      |> maybe_put_log_file()

    case Scheduler.create_task(attrs) do
      {:ok, task} ->
        scheduler_state = safe_scheduler_state()
        schedule_note = scheduler_schedule_note(scheduler_state)

        result = """
        ✅ **Task Created Successfully!**

        **ID:** `#{task.id}`
        **Name:** #{task.name}
        **Schedule:** #{format_schedule(task)}
        **Agent:** #{task.agent_name}
        **Model:** #{task.model || "(default)"}
        **Directory:** #{task.working_directory}
        **Log File:** `#{task.log_file || "(none)"}`

        **Prompt:**
        ```
        #{task.prompt}
        ```
        """

        result <> "\n" <> schedule_note

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        "❌ **Failed to create task**\n\nErrors:\n#{errors}"
    end
  end

  @doc """
  Deletes a scheduled task by ID or name.

  ## Examples

      iex> SchedulerTools.delete_task("123")
      "✅ Deleted task: **My Task** (`123`)"

      iex> SchedulerTools.delete_task("task-name")
      "✅ Deleted task: **Task Name** (`456`)"

  """
  @spec delete_task(String.t() | integer()) :: String.t()
  def delete_task(task_id) when is_binary(task_id) do
    # Try to parse as integer first
    case Integer.parse(task_id) do
      {id, ""} ->
        delete_task(id)

      _ ->
        # Try to find by name
        case Scheduler.get_task_by_name(task_id) do
          {:ok, task} -> do_delete_task(task)
          {:error, :not_found} -> "❌ Task not found: `#{task_id}`"
        end
    end
  end

  def delete_task(task_id) when is_integer(task_id) do
    case Scheduler.get_task(task_id) do
      {:ok, task} -> do_delete_task(task)
      {:error, :not_found} -> "❌ Task not found: `#{task_id}`"
    end
  end

  defp do_delete_task(%Task{} = task) do
    task_name = task.name

    case Scheduler.delete_task(task) do
      {:ok, _} -> "✅ Deleted task: **#{task_name}** (`#{task.id}`)"
      {:error, _} -> "❌ Failed to delete task: `#{task.id}`"
    end
  end

  @doc """
  Toggles a task's enabled/disabled state by ID or name.

  ## Examples

      iex> SchedulerTools.toggle_task("123")
      "Task **My Task** (`123`) is now 🟢 **Enabled**"

  """
  @spec toggle_task(String.t() | integer()) :: String.t()
  def toggle_task(task_id) when is_binary(task_id) do
    case Integer.parse(task_id) do
      {id, ""} ->
        toggle_task(id)

      _ ->
        case Scheduler.get_task_by_name(task_id) do
          {:ok, task} -> do_toggle_task(task)
          {:error, :not_found} -> "❌ Task not found: `#{task_id}`"
        end
    end
  end

  def toggle_task(task_id) when is_integer(task_id) do
    case Scheduler.get_task(task_id) do
      {:ok, task} -> do_toggle_task(task)
      {:error, :not_found} -> "❌ Task not found: `#{task_id}`"
    end
  end

  defp do_toggle_task(%Task{} = task) do
    task_name = task.name

    case Scheduler.toggle_task(task) do
      {:ok, updated} ->
        status = if updated.enabled, do: "🟢 **Enabled**", else: "🔴 **Disabled**"
        "Task **#{task_name}** (`#{task.id}`) is now #{status}"

      {:error, _} ->
        "❌ Failed to toggle task: `#{task.id}`"
    end
  end

  @doc """
  Gets the scheduler daemon/process status.

  Returns information about the CronScheduler GenServer and task counts.

  ## Examples

      iex> SchedulerTools.scheduler_status()
      "🟢 **Scheduler is RUNNING**\\n..."

  """
  @spec scheduler_status() :: String.t()
  def scheduler_status do
    tasks = Scheduler.list_tasks()
    enabled_count = Enum.count(tasks, & &1.enabled)
    scheduler_state = safe_scheduler_state()

    if scheduler_state[:running] do
      last_check_str =
        if scheduler_state[:last_check_at] do
          format_datetime(scheduler_state[:last_check_at])
        else
          "Never"
        end

      """
      🟢 **Scheduler is RUNNING**

      **CronScheduler PID:** #{inspect(Process.whereis(CronScheduler))}
      **Check Interval:** #{div(scheduler_state[:check_interval], 1000)} seconds
      **Last Check:** #{last_check_str}
      **Tasks Enqueued (lifetime):** #{scheduler_state[:tasks_enqueued]}

      **Total Tasks:** #{length(tasks)}
      **Enabled Tasks:** #{enabled_count}
      **Disabled Tasks:** #{length(tasks) - enabled_count}

      The scheduler is actively monitoring and running tasks according to their schedules.
      """
    else
      """
      ⏸️ **Scheduler is NOT RUNNING**

      The CronScheduler process is not started. Scheduled tasks are persisted
      but will not execute automatically. This is normal in test environments.

      **Total Tasks:** #{length(tasks)}
      **Enabled Tasks:** #{enabled_count}
      """
    end
  end

  @doc """
  Runs a scheduled task immediately, regardless of its schedule.

  ## Examples

      iex> SchedulerTools.run_task("123")
      "✅ **Task completed successfully!**\\n..."

  """
  @spec run_task(String.t() | integer()) :: String.t()
  def run_task(task_id) when is_binary(task_id) do
    case Integer.parse(task_id) do
      {id, ""} ->
        run_task(id)

      _ ->
        case Scheduler.get_task_by_name(task_id) do
          {:ok, task} -> do_run_task(task)
          {:error, :not_found} -> "❌ Task not found: `#{task_id}`"
        end
    end
  end

  def run_task(task_id) when is_integer(task_id) do
    case Scheduler.get_task(task_id) do
      {:ok, task} -> do_run_task(task)
      {:error, :not_found} -> "❌ Task not found: `#{task_id}`"
    end
  end

  defp do_run_task(%Task{} = task) do
    result_header = "⏳ Running task **#{task.name}** (`#{task.id}`)...\n\n"

    # Use task.config or empty map, never nil
    _config = task.config || %{}

    # Insert the job using Oban - in production this queues, in test with inline
    # mode it executes synchronously
    case Scheduler.run_task_now(task) do
      {:ok, job} ->
        # In Oban inline mode, the job may have already executed or timed out
        # We just report what we know about the job
        status_info =
          if job.state == "completed" do
            "\n🎉 Job completed immediately (inline execution)"
          else
            "\nThe task will execute as soon as a worker is available."
          end

        result_header <>
          """
          ✅ **Task queued for execution!**

          **Job ID:** #{job.id}
          **Queue:** #{job.queue}
          **State:** #{job.state}
          **Scheduled At:** #{format_datetime(job.scheduled_at || DateTime.utc_now())}
          #{status_info}

          View execution history with `view_log`.
          """

      {:error, reason} ->
        result_header <>
          "❌ **Failed to queue task.**\n\nError: #{inspect(reason)}"
    end
  end

  @doc """
  Views the execution history (log) for a scheduled task.

  ## Parameters

    * `task_id` - ID or name of the task
    * `lines` - Maximum number of history entries to show (default: 10)

  ## Examples

      iex> SchedulerTools.view_log("123", 5)
      "📄 **Execution history for task:** My Task\\n..."

  """
  @spec view_log(String.t() | integer(), non_neg_integer()) :: String.t()
  def view_log(task_id, lines \\ 10) do
    # Resolve task first
    task_result =
      if is_binary(task_id) do
        case Integer.parse(task_id) do
          {id, ""} -> Scheduler.get_task(id)
          _ -> Scheduler.get_task_by_name(task_id)
        end
      else
        Scheduler.get_task(task_id)
      end

    case task_result do
      {:ok, task} ->
        history = Scheduler.get_task_history(task.id, limit: lines)

        if history == [] do
          """
          📄 **Execution history for task:** #{task.name} (`#{task.id}`)

          No executions recorded yet.

          The history will be populated when the task runs.
          """
        else
          history_lines =
            Enum.map(history, fn job ->
              status_icon =
                case job.state do
                  "completed" -> "✅"
                  "executing" -> "⏳"
                  "retryable" -> "🔄"
                  "discarded" -> "🗑️"
                  _ -> "❓"
                end

              meta = job.meta || %{}
              error = meta["error"] || job.error

              attempt_info =
                if job.attempt > 1 do
                  " (attempt #{job.attempt}/#{job.max_attempts})"
                else
                  ""
                end

              error_info =
                if error do
                  "\n  Error: #{String.slice(inspect(error), 0, 100)}"
                else
                  ""
                end

              "#{status_icon} #{format_datetime(job.inserted_at)}#{attempt_info} [#{job.state}]#{error_info}"
            end)
            |> Enum.join("\n")

          """
          📄 **Execution history for task:** #{task.name} (`#{task.id}`)
          **Showing:** last #{min(length(history), lines)} of #{Scheduler.get_task_history(task.id, limit: 1000) |> length()} total executions

          ```
          #{history_lines}
          ```
          """
        end

      {:error, :not_found} ->
        "❌ Task not found: `#{task_id}`"
    end
  end

  @doc """
  Forces an immediate check of scheduled tasks.

  This causes the CronScheduler to evaluate all enabled tasks
  and enqueue any that are due.

  ## Examples

      iex> SchedulerTools.force_check()
      "🔄 **Schedule check triggered**\\n..."

  """
  @spec force_check() :: String.t()
  def force_check do
    case Scheduler.force_check() do
      :ok ->
        scheduler_state = safe_scheduler_state()
        last_check = scheduler_state[:last_check_at]

        last_check_str =
          if last_check do
            "Last check: #{format_datetime(last_check)}"
          else
            "Check in progress..."
          end

        """
        🔄 **Schedule check triggered**

        #{last_check_str}
        Tasks enqueued (lifetime): #{scheduler_state[:tasks_enqueued]}

        The scheduler will evaluate all enabled tasks and enqueue any that are due.
        """

      {:error, :not_running} ->
        "⚠️ **Schedule check skipped** — CronScheduler is not running. " <>
          "This is normal in test environments."
    end
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  # Safe access to global CronScheduler state — returns a default map
  # when CronScheduler is not running (e.g. test env excluded from
  # supervision tree). (code_puppy-5xd.6)
  defp safe_scheduler_state do
    if Process.whereis(CronScheduler) do
      CronScheduler.get_state() |> Map.put(:running, true)
    else
      %{check_interval: 0, last_check_at: nil, tasks_enqueued: 0, running: false}
    end
  end

  defp scheduler_status_line(%{running: true, check_interval: interval}) do
    "**CronScheduler:** 🟢 Running (checks every #{div(interval, 1000)}s)"
  end

  defp scheduler_status_line(%{running: false}) do
    "**CronScheduler:** ⏸️ Not running (test mode)"
  end

  defp scheduler_schedule_note(%{running: true, check_interval: interval}) do
    "🟢 Scheduler is running (checks every #{div(interval, 1000)}s). Task will execute according to schedule."
  end

  defp scheduler_schedule_note(%{running: false}) do
    "⏸️ Scheduler is not running. Task is persisted but will not execute automatically until the scheduler starts."
  end

  defp format_schedule(%Task{schedule_type: "cron", schedule: schedule})
       when not is_nil(schedule) do
    "cron (#{schedule})"
  end

  defp format_schedule(%Task{schedule_type: type, schedule_value: value}) do
    "#{type} (#{value})"
  end

  defp format_schedule(%Task{schedule_type: type}) do
    type
  end

  defp format_datetime(%DateTime{} = dt) do
    case DateTime.to_iso8601(dt) do
      {:ok, str} -> String.slice(str, 0, 19)
      str when is_binary(str) -> String.slice(str, 0, 19)
      _ -> inspect(dt)
    end
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    NaiveDateTime.to_iso8601(ndt)
    |> String.slice(0, 19)
  end

  defp format_datetime(nil), do: "N/A"

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} ->
      "- #{field}: #{Enum.join(errors, ", ")}"
    end)
    |> Enum.join("\n")
  end

  defp maybe_put_log_file(attrs) do
    if attrs[:log_file] do
      attrs
    else
      # Generate a default log file path based on task name
      sanitized_name =
        attrs[:name]
        |> to_string()
        |> String.replace(~r/[^\w\-]/, "_")

      log_dir = Path.join(System.tmp_dir!(), "code_puppy_scheduler_logs")
      File.mkdir_p!(log_dir)

      log_file = Path.join(log_dir, "#{sanitized_name}.log")
      Map.put(attrs, :log_file, log_file)
    end
  end
end
