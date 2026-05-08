defmodule CodePuppyControl.Runtime.SchedulerAPITest do
  @moduledoc """
  Tests for the Scheduler public API (CRUD operations + run management).

  Uses StatefulCase for Ecto sandbox + Oban cleanup.
  """

  use CodePuppyControl.StatefulCase

  @moduletag timeout: 30_000

  alias CodePuppyControl.Scheduler
  alias CodePuppyControl.Scheduler.Task
  alias CodePuppyControl.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Repo.delete_all(Oban.Job)
    :ok
  end

  # ---------------------------------------------------------------------------
  # CRUD
  # ---------------------------------------------------------------------------

  describe "create_task/1" do
    test "creates an interval task" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "api-interval-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "Run every hour",
          schedule_type: "interval",
          schedule_value: "1h"
        })

      assert %Task{} = task
      assert task.schedule_type == "interval"
      assert task.schedule_value == "1h"
      assert task.enabled == true
    end

    test "creates a cron task" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "api-cron-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "9am daily",
          schedule_type: "cron",
          schedule: "0 9 * * *"
        })

      assert task.schedule == "0 9 * * *"
    end

    test "creates a one_shot task" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "api-oneshot-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "Run once",
          schedule_type: "one_shot"
        })

      assert task.schedule_type == "one_shot"
    end

    test "returns error for missing required fields" do
      assert {:error, %Ecto.Changeset{}} = Scheduler.create_task(%{name: "no-prompt"})
    end

    test "default values are applied" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "defaults-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "test"
        })

      assert task.enabled == true
      assert task.run_count == 0
      assert task.working_directory == "."
      assert task.config == %{}
    end
  end

  describe "list_tasks/0" do
    test "returns tasks ordered by insertion date" do
      prefix = System.unique_integer([:positive])

      for i <- 1..3 do
        Scheduler.create_task(%{
          name: "list-#{prefix}-#{i}",
          agent_name: "code-puppy",
          prompt: "Task #{i}"
        })
      end

      tasks = Scheduler.list_tasks()
      names = Enum.map(tasks, & &1.name)

      # Our tasks should be in insertion order
      our_tasks = Enum.filter(names, &String.starts_with?(&1, "list-#{prefix}"))
      assert our_tasks == ["list-#{prefix}-1", "list-#{prefix}-2", "list-#{prefix}-3"]
    end
  end

  describe "list_enabled_tasks/0" do
    test "returns only enabled tasks" do
      prefix = System.unique_integer([:positive])

      Scheduler.create_task(%{
        name: "enabled-#{prefix}-1",
        agent_name: "code-puppy",
        prompt: "on",
        enabled: true
      })

      Scheduler.create_task(%{
        name: "enabled-#{prefix}-2",
        agent_name: "code-puppy",
        prompt: "off",
        enabled: false
      })

      enabled = Scheduler.list_enabled_tasks()
      enabled_names = Enum.map(enabled, & &1.name)

      assert "enabled-#{prefix}-1" in enabled_names
      refute "enabled-#{prefix}-2" in enabled_names
    end
  end

  describe "get_task/1 and get_task_by_name/1" do
    test "get_task returns task by ID" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "get-by-id-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "test"
        })

      assert {:ok, found} = Scheduler.get_task(task.id)
      assert found.id == task.id
    end

    test "get_task returns not_found for invalid ID" do
      assert {:error, :not_found} = Scheduler.get_task(-999_999)
    end

    test "get_task_by_name returns task by name" do
      name = "get-by-name-#{System.unique_integer([:positive])}"

      {:ok, task} =
        Scheduler.create_task(%{
          name: name,
          agent_name: "code-puppy",
          prompt: "test"
        })

      assert {:ok, found} = Scheduler.get_task_by_name(name)
      assert found.id == task.id
    end

    test "get_task_by_name returns not_found for unknown name" do
      assert {:error, :not_found} = Scheduler.get_task_by_name("does-not-exist-xyz")
    end
  end

  describe "update_task/2" do
    test "updates task fields" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "update-test-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "original"
        })

      {:ok, updated} = Scheduler.update_task(task, %{prompt: "updated prompt"})
      assert updated.prompt == "updated prompt"
    end
  end

  describe "delete_task/1" do
    test "deletes a task" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "delete-test-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "delete me"
        })

      assert {:ok, _} = Scheduler.delete_task(task)
      assert {:error, :not_found} = Scheduler.get_task(task.id)
    end
  end

  describe "enable_task/1, disable_task/1, toggle_task/1" do
    setup do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "toggle-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "toggle me",
          enabled: true
        })

      %{task: task}
    end

    test "disable_task disables an enabled task", %{task: task} do
      {:ok, disabled} = Scheduler.disable_task(task)
      refute disabled.enabled
    end

    test "enable_task enables a disabled task", %{task: task} do
      {:ok, disabled} = Scheduler.disable_task(task)
      {:ok, enabled} = Scheduler.enable_task(disabled)
      assert enabled.enabled
    end

    test "toggle_task flips enabled state", %{task: task} do
      {:ok, toggled} = Scheduler.toggle_task(task)
      refute toggled.enabled

      {:ok, toggled_back} = Scheduler.toggle_task(toggled)
      assert toggled_back.enabled
    end
  end

  # ---------------------------------------------------------------------------
  # Statistics
  # ---------------------------------------------------------------------------

  describe "statistics/0" do
    test "returns stats map with expected keys" do
      stats = Scheduler.statistics()

      assert Map.has_key?(stats, :total)
      assert Map.has_key?(stats, :enabled)
      assert Map.has_key?(stats, :disabled)
      assert Map.has_key?(stats, :with_schedule)
      assert Map.has_key?(stats, :one_shot)
      assert Map.has_key?(stats, :last_24h_runs)
    end
  end
end
