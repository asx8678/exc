defmodule CodePuppyControl.SchedulerTest do
  @moduledoc """
  Integration tests for the Scheduler API.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Scheduler
  alias CodePuppyControl.Repo

  setup do
    # (code_puppy-i1n) Ensure Repo is available — supervised processes
    # may be dead if the application tree was killed by a prior test.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(Repo)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Clean up Oban jobs
    Repo.delete_all(Oban.Job)

    :ok
  end

  describe "create_task/1" do
    test "creates a valid task" do
      attrs = %{
        name: "test-task-#{System.unique_integer()}",
        agent_name: "code-puppy",
        prompt: "Test prompt",
        schedule_type: "hourly"
      }

      assert {:ok, task} = Scheduler.create_task(attrs)
      assert task.name == attrs.name
      assert task.agent_name == "code-puppy"
      assert task.enabled == true
    end

    test "returns error for invalid task" do
      assert {:error, changeset} = Scheduler.create_task(%{})
      refute changeset.valid?
    end

    test "enforces unique task names" do
      name = "unique-test-#{System.unique_integer()}"

      assert {:ok, _} =
               Scheduler.create_task(%{
                 name: name,
                 agent_name: "agent1",
                 prompt: "test"
               })

      assert {:error, changeset} =
               Scheduler.create_task(%{
                 name: name,
                 agent_name: "agent2",
                 prompt: "test"
               })

      assert {"has already been taken", opts} = changeset.errors[:name]
      assert opts[:constraint] == :unique
      assert opts[:constraint_name] == "scheduled_tasks_name_index"
    end
  end

  describe "get_task/1 and get_task_by_name/1" do
    test "fetches existing task by id" do
      {:ok, created} =
        Scheduler.create_task(%{
          name: "fetch-test",
          agent_name: "code-puppy",
          prompt: "test"
        })

      assert {:ok, fetched} = Scheduler.get_task(created.id)
      assert fetched.id == created.id
      assert fetched.name == "fetch-test"
    end

    test "returns error for non-existent task" do
      assert {:error, :not_found} = Scheduler.get_task(-1)
    end

    test "fetches task by name" do
      {:ok, created} =
        Scheduler.create_task(%{
          name: "name-lookup",
          agent_name: "code-puppy",
          prompt: "test"
        })

      assert {:ok, fetched} = Scheduler.get_task_by_name("name-lookup")
      assert fetched.id == created.id
    end
  end

  describe "update_task/2" do
    test "updates task attributes" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "update-test",
          agent_name: "code-puppy",
          prompt: "original"
        })

      assert {:ok, updated} = Scheduler.update_task(task, %{prompt: "updated"})
      assert updated.prompt == "updated"
    end
  end

  describe "enable_task/1 and disable_task/1" do
    test "toggles task enabled state" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "toggle-test",
          agent_name: "code-puppy",
          prompt: "test"
        })

      assert {:ok, disabled} = Scheduler.disable_task(task)
      refute disabled.enabled

      assert {:ok, enabled} = Scheduler.enable_task(disabled)
      assert enabled.enabled
    end
  end

  describe "delete_task/1" do
    test "removes a task" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "delete-test",
          agent_name: "code-puppy",
          prompt: "test"
        })

      assert {:ok, deleted} = Scheduler.delete_task(task)
      assert deleted.id == task.id

      assert {:error, :not_found} = Scheduler.get_task(task.id)
    end
  end

  describe "run_task_now/1" do
    test "enqueues a job for immediate execution" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "run-now-test",
          agent_name: "code-puppy",
          prompt: "test prompt"
        })

      assert {:ok, job} = Scheduler.run_task_now(task)
      assert job.queue == "scheduled"
      assert job.args["task_id"] == task.id
    end
  end

  describe "list_tasks/0" do
    test "returns all tasks" do
      # Create some tasks
      for i <- 1..3 do
        {:ok, _} =
          Scheduler.create_task(%{
            name: "list-test-#{i}",
            agent_name: "code-puppy",
            prompt: "test"
          })
      end

      tasks = Scheduler.list_tasks()
      assert length(tasks) >= 3
    end
  end

  describe "statistics/0" do
    test "returns task statistics" do
      # Ensure at least one task exists
      {:ok, _} =
        Scheduler.create_task(%{
          name: "stats-test-#{System.unique_integer()}",
          agent_name: "code-puppy",
          prompt: "test"
        })

      stats = Scheduler.statistics()
      assert is_integer(stats.total)
      assert is_integer(stats.enabled)
      assert is_integer(stats.disabled)
      assert stats.total >= stats.enabled
    end
  end

  describe "get_task_history/2" do
    test "returns job history for a task" do
      {:ok, task} =
        Scheduler.create_task(%{
          name: "history-test",
          agent_name: "code-puppy",
          prompt: "test"
        })

      # Insert a persisted job record directly: Oban's test :inline mode executes
      # run_task_now/1 immediately and does not leave a historical row to query.
      job =
        %{task_id: task.id}
        |> CodePuppyControl.Scheduler.Worker.new(queue: :scheduled)
        |> Ecto.Changeset.put_change(:state, "completed")
        |> Repo.insert!()

      history = Scheduler.get_task_history(task.id, limit: 10)
      assert Enum.any?(history, &(&1.id == job.id))
    end
  end
end
