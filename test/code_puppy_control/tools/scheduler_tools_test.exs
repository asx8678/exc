defmodule CodePuppyControl.Tools.SchedulerToolsTest do
  @moduledoc """
  Tests for the SchedulerTools module.

  These tests verify that the tool interface properly wraps the Scheduler API
  and returns formatted string responses.
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Tools.SchedulerTools
  alias CodePuppyControl.Scheduler
  alias CodePuppyControl.Scheduler.CronScheduler
  alias CodePuppyControl.Repo

  setup context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Clean up Oban jobs
    Repo.delete_all(Oban.Job)

    # Start CronScheduler only for describe blocks that need it.
    # The global CronScheduler is excluded from test supervision to
    # avoid Ecto-sandbox contention (code_puppy-5xd.6), so tests
    # that need it must start their own instance.
    unless context[:no_cron_scheduler] do
      {:ok, _pid} = start_supervised({CronScheduler, check_interval: 60_000})
    end

    :ok
  end

  describe "list_tasks/0" do
    test "returns status when no tasks exist" do
      result = SchedulerTools.list_tasks()

      assert result =~ "Scheduler Status"
      assert result =~ "CronScheduler"
      assert result =~ "No scheduled tasks configured yet"
      assert result =~ "scheduler_create_task"
    end

    test "lists tasks with their status" do
      {:ok, _} =
        Scheduler.create_task(%{
          name: "list-test-task",
          agent_name: "code-puppy",
          prompt: "Test prompt for listing",
          schedule_type: "hourly"
        })

      result = SchedulerTools.list_tasks()

      assert result =~ "list-test-task"
      assert result =~ "hourly"
      assert result =~ "code-puppy"
      assert result =~ "Test prompt"
    end

    test "shows enabled/disabled status" do
      {:ok, _task} =
        Scheduler.create_task(%{
          name: "disabled-task",
          agent_name: "code-puppy",
          prompt: "Disabled for testing",
          schedule_type: "daily",
          enabled: false
        })

      result = SchedulerTools.list_tasks()

      assert result =~ "disabled-task"
      # Should show the disabled icon (🔴) or count
      assert result =~ "Total Tasks:** 1"
      assert result =~ "Enabled Tasks:** 0"
    end

    test "shows last run status indicators" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "status-test-task",
          agent_name: "code-puppy",
          prompt: "Status testing",
          schedule_type: "interval",
          schedule_value: "30m"
        })

      # Manually update to simulate success (truncate microseconds for SQLite)
      task
      |> Ecto.Changeset.change(
        last_status: "success",
        last_run_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      result = SchedulerTools.list_tasks()

      assert result =~ "status-test-task"
      assert result =~ "✅"
    end
  end

  describe "create_task/1" do
    test "creates a task successfully" do
      attrs = %{
        name: "created-task",
        agent_name: "code-puppy",
        prompt: "Do something useful",
        schedule_type: "hourly"
      }

      result = SchedulerTools.create_task(attrs)

      assert result =~ "Task Created Successfully"
      assert result =~ "created-task"
      assert result =~ "hourly"
      assert result =~ "code-puppy"
      assert result =~ "Do something useful"
    end

    test "supports agent alias (Python compatibility)" do
      attrs = %{
        name: "agent-alias-task",
        agent: "security-auditor",
        prompt: "Security audit",
        schedule_type: "daily"
      }

      result = SchedulerTools.create_task(attrs)

      assert result =~ "Task Created Successfully"
      assert result =~ "security-auditor"
    end

    test "returns error for invalid task" do
      result = SchedulerTools.create_task(%{name: "", prompt: ""})

      assert result =~ "Failed to create task"
      assert result =~ "can't be blank"
    end

    test "enforces unique task names" do
      name = "unique-create-test-#{System.unique_integer()}"

      # First creation should succeed
      result1 =
        SchedulerTools.create_task(%{
          name: name,
          agent_name: "agent1",
          prompt: "test"
        })

      assert result1 =~ "Task Created Successfully"

      # Second creation with same name should fail
      result2 =
        SchedulerTools.create_task(%{
          name: name,
          agent_name: "agent2",
          prompt: "test2"
        })

      assert result2 =~ "Failed to create task"
      assert result2 =~ "has already been taken"
    end
  end

  describe "delete_task/1" do
    test "deletes task by ID" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "to-delete-by-id",
          agent_name: "code-puppy",
          prompt: "Delete me"
        })

      result = SchedulerTools.delete_task(task.id)

      assert result =~ "Deleted task"
      assert result =~ "to-delete-by-id"
      assert result =~ "#{task.id}"
    end

    test "deletes task by name" do
      {:ok, _} =
        Scheduler.create_task(%{
          name: "to-delete-by-name",
          agent_name: "code-puppy",
          prompt: "Delete me"
        })

      result = SchedulerTools.delete_task("to-delete-by-name")

      assert result =~ "Deleted task"
      assert result =~ "to-delete-by-name"
    end

    test "returns error for non-existent task" do
      result = SchedulerTools.delete_task(-1)

      assert result =~ "Task not found"
    end

    test "returns error for non-existent task by name" do
      result = SchedulerTools.delete_task("definitely-does-not-exist-12345")

      assert result =~ "Task not found"
    end
  end

  describe "toggle_task/1" do
    test "disables enabled task by ID" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "toggle-test",
          agent_name: "code-puppy",
          prompt: "Toggle me",
          enabled: true
        })

      result = SchedulerTools.toggle_task(task.id)

      assert result =~ "Disabled"
      assert result =~ "toggle-test"
    end

    test "enables disabled task by name" do
      {:ok, _task} =
        Scheduler.create_task(%{
          name: "toggle-by-name",
          agent_name: "code-puppy",
          prompt: "Toggle me",
          enabled: false
        })

      result = SchedulerTools.toggle_task("toggle-by-name")

      assert result =~ "Enabled"
      assert result =~ "toggle-by-name"
    end

    test "returns error for non-existent task" do
      result = SchedulerTools.toggle_task("nonexistent-task-99999")

      assert result =~ "Task not found"
    end
  end

  describe "scheduler_status/0" do
    test "returns running status with counts" do
      # Create some tasks for more interesting output
      for i <- 1..3 do
        {:ok, _} =
          Scheduler.create_task(%{
            name: "status-task-#{i}",
            agent_name: "code-puppy",
            prompt: "Task #{i}"
          })
      end

      result = SchedulerTools.scheduler_status()

      # CronScheduler is started by setup (via supervised instance)
      assert result =~ "Scheduler is RUNNING"
      assert result =~ "CronScheduler PID"
      assert result =~ "Total Tasks:** 3"
      assert result =~ "Enabled Tasks:** 3"
    end

    test "shows check interval configuration" do
      result = SchedulerTools.scheduler_status()

      assert result =~ "Check Interval"
      assert result =~ "seconds"
    end
  end

  describe "run_task/1" do
    # These tests require a Python worker and can cause timeouts in Oban inline mode
    # They are tested in integration tests where a full system is available
    @tag :skip
    test "queues task by ID for execution" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "run-now-test",
          agent_name: "code-puppy",
          prompt: "Run me now"
        })

      # Note: In Oban inline test mode, the job executes synchronously
      # which may result in a timeout or failure without a Python worker
      # We just verify the tool returns either a success or expected error
      result = SchedulerTools.run_task(task.id)

      # Result should contain either queued message or timeout info
      assert result =~ "run-now-test" or result =~ "Task not found"
    end

    @tag :skip
    test "queues task by name" do
      {:ok, _} =
        Scheduler.create_task(%{
          name: "run-by-name",
          agent_name: "code-puppy",
          prompt: "Run me by name"
        })

      result = SchedulerTools.run_task("run-by-name")

      # May succeed or fail depending on Oban inline execution
      assert result =~ "run-by-name" or result =~ "Task not found"
    end

    test "returns error for non-existent task" do
      result = SchedulerTools.run_task(-999)

      assert result =~ "Task not found"
    end
  end

  describe "view_log/2" do
    test "returns message when no history exists" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "no-history-task",
          agent_name: "code-puppy",
          prompt: "No runs yet"
        })

      result = SchedulerTools.view_log(task.id)

      assert result =~ "Execution history"
      assert result =~ "no-history-task"
      assert result =~ "No executions recorded yet"
    end

    test "accepts task name as identifier" do
      {:ok, _} =
        Scheduler.create_task(%{
          name: "log-by-name",
          agent_name: "code-puppy",
          prompt: "Lookup by name"
        })

      result = SchedulerTools.view_log("log-by-name", 5)

      assert result =~ "Execution history"
    end

    test "returns error for non-existent task" do
      result = SchedulerTools.view_log(-999, 5)

      assert result =~ "Task not found"
    end
  end

  describe "force_check/0" do
    test "triggers schedule check and returns status" do
      result = SchedulerTools.force_check()

      assert result =~ "Schedule check triggered"
      assert result =~ "Tasks enqueued"
    end
  end

  # Tests for graceful degradation when CronScheduler is not running.
  # These run without starting a CronScheduler, verifying that
  # SchedulerTools handles the absent-global-scheduler case.
  # (code_puppy-5xd.6)
  describe "scheduler not running" do
    @describetag :no_cron_scheduler

    test "scheduler_status returns not-running when CronScheduler is absent" do
      result = SchedulerTools.scheduler_status()

      assert result =~ "NOT RUNNING"
      assert result =~ "Total Tasks"
    end

    test "force_check returns not-running message when CronScheduler is absent" do
      result = SchedulerTools.force_check()

      assert result =~ "Schedule check skipped"
      assert result =~ "CronScheduler is not running"
    end

    test "list_tasks shows not-running status when CronScheduler is absent" do
      result = SchedulerTools.list_tasks()

      assert result =~ "Not running"
    end

    test "create_task shows scheduler-not-running note when CronScheduler is absent" do
      attrs = %{
        name: "no-scheduler-task",
        agent_name: "code-puppy",
        prompt: "Task without scheduler",
        schedule_type: "hourly"
      }

      result = SchedulerTools.create_task(attrs)

      assert result =~ "Task Created Successfully"
      assert result =~ "not running"
    end
  end

  describe "formatting helpers" do
    test "handles cron schedules in format_schedule" do
      {:ok, _task} =
        Scheduler.create_task(%{
          name: "cron-format-test",
          agent_name: "code-puppy",
          prompt: "Test cron formatting",
          schedule_type: "cron",
          schedule: "0 9 * * *"
        })

      result = SchedulerTools.list_tasks()

      assert result =~ "cron (0 9 * * *)"
    end

    test "handles interval schedules" do
      {:ok, _task} =
        Scheduler.create_task(%{
          name: "interval-format-test",
          agent_name: "code-puppy",
          prompt: "Test interval formatting",
          schedule_type: "interval",
          schedule_value: "30m"
        })

      result = SchedulerTools.list_tasks()

      assert result =~ "interval (30m)"
    end

    test "prompt preview is truncated at 100 characters" do
      long_prompt = String.duplicate("a", 150)

      {:ok, _} =
        Scheduler.create_task(%{
          name: "long-prompt-task",
          agent_name: "code-puppy",
          prompt: long_prompt
        })

      result = SchedulerTools.list_tasks()

      assert result =~ "..."
      # Should not contain the full 150 characters
      refute result =~ String.duplicate("a", 120)
    end
  end
end
