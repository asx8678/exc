defmodule CodePuppyControl.Runtime.SchedulerTaskTest do
  @moduledoc """
  Tests for Scheduler.Task — Ecto schema, changeset validation, interval
  parsing, and should_run? logic.

  These are pure-data tests (no GenServer, no Oban), covering the scheduling
  invariant: should_run? is deterministic given task attrs + a fixed `now`.
  """

  use CodePuppyControl.StatefulCase

  @moduletag timeout: 30_000

  alias CodePuppyControl.Scheduler.Task
  alias CodePuppyControl.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Repo.delete_all(Oban.Job)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Changeset Validation
  # ---------------------------------------------------------------------------

  describe "changeset/2 validation" do
    test "valid task with required fields" do
      changeset =
        Task.changeset(%Task{}, %{
          name: "test-task",
          agent_name: "code-puppy",
          prompt: "Do something",
          schedule_type: "hourly"
        })

      assert changeset.valid?
    end

    test "requires name, agent_name, and prompt" do
      changeset = Task.changeset(%Task{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert :name in errors
      assert :agent_name in errors
      assert :prompt in errors
    end

    test "validates schedule_type inclusion" do
      changeset =
        Task.changeset(%Task{}, %{
          name: "bad-type",
          agent_name: "code-puppy",
          prompt: "test",
          schedule_type: "invalid_type"
        })

      refute changeset.valid?
      assert :schedule_type in errors_on(changeset)
    end

    test "accepts all valid schedule types" do
      for stype <- ["interval", "hourly", "daily", "one_shot"] do
        changeset =
          Task.changeset(%Task{}, %{
            name: "type-#{stype}",
            agent_name: "code-puppy",
            prompt: "test",
            schedule_type: stype
          })

        assert changeset.valid?, "Expected schedule_type=#{stype} to be valid"
      end

      # Cron requires a schedule value
      changeset =
        Task.changeset(%Task{}, %{
          name: "type-cron",
          agent_name: "code-puppy",
          prompt: "test",
          schedule_type: "cron",
          schedule: "0 9 * * *"
        })

      assert changeset.valid?
    end

    test "validates unique name constraint" do
      # This relies on the database — we test via Repo.insert
      name = "unique-test-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodePuppyControl.Scheduler.create_task(%{
          name: name,
          agent_name: "code-puppy",
          prompt: "first"
        })

      {:error, changeset} =
        CodePuppyControl.Scheduler.create_task(%{
          name: name,
          agent_name: "code-puppy",
          prompt: "second"
        })

      assert :name in errors_on(changeset)
    end

    test "cron schedule_type requires schedule value" do
      changeset =
        Task.changeset(%Task{}, %{
          name: "no-cron-val",
          agent_name: "code-puppy",
          prompt: "test",
          schedule_type: "cron",
          schedule: nil
        })

      refute changeset.valid?
    end

    test "valid cron expression passes validation" do
      changeset =
        Task.changeset(%Task{}, %{
          name: "valid-cron",
          agent_name: "code-puppy",
          prompt: "test",
          schedule_type: "cron",
          schedule: "0 9 * * *"
        })

      assert changeset.valid?
    end

    test "invalid cron expression fails validation" do
      changeset =
        Task.changeset(%Task{}, %{
          name: "bad-cron",
          agent_name: "code-puppy",
          prompt: "test",
          schedule_type: "cron",
          schedule: "not-a-cron"
        })

      refute changeset.valid?
    end

    test "interval schedule_type requires schedule_value" do
      changeset =
        Task.changeset(%Task{}, %{
          name: "no-interval-val",
          agent_name: "code-puppy",
          prompt: "test",
          schedule_type: "interval",
          schedule_value: nil
        })

      refute changeset.valid?
    end

    test "one_shot schedule_type requires no additional fields" do
      changeset =
        Task.changeset(%Task{}, %{
          name: "one-shot-ok",
          agent_name: "code-puppy",
          prompt: "test",
          schedule_type: "one_shot"
        })

      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Interval Parsing
  # ---------------------------------------------------------------------------

  describe "parse_interval/1" do
    test "parses seconds" do
      assert {:ok, 30} = Task.parse_interval("30s")
    end

    test "parses minutes" do
      assert {:ok, 1800} = Task.parse_interval("30m")
    end

    test "parses hours" do
      assert {:ok, 3600} = Task.parse_interval("1h")
    end

    test "parses days" do
      assert {:ok, 86400} = Task.parse_interval("1d")
    end

    test "parses multi-unit values" do
      assert {:ok, 7200} = Task.parse_interval("2h")
      assert {:ok, 172_800} = Task.parse_interval("2d")
    end

    test "rejects invalid formats" do
      assert {:error, _} = Task.parse_interval("invalid")
      assert {:error, _} = Task.parse_interval("")
      assert {:error, _} = Task.parse_interval("5x")
      assert {:error, _} = Task.parse_interval("h")
    end

    test "handles whitespace" do
      assert {:ok, 60} = Task.parse_interval(" 1m ")
    end

    test "is case-insensitive for unit" do
      assert {:ok, 60} = Task.parse_interval("1M")
      assert {:ok, 3600} = Task.parse_interval("1H")
    end
  end

  # ---------------------------------------------------------------------------
  # should_run? scheduling logic
  # ---------------------------------------------------------------------------

  describe "should_run?/2" do
    test "returns true for never-run task" do
      task = %Task{schedule_type: "hourly", last_run_at: nil, enabled: true}
      assert Task.should_run?(task, DateTime.utc_now())
    end

    test "returns false for disabled task regardless of last_run_at" do
      # Disabled tasks must never run, even when never run before
      task = %Task{schedule_type: "hourly", last_run_at: nil, enabled: false}
      refute Task.should_run?(task, DateTime.utc_now())

      last_run = DateTime.add(DateTime.utc_now(), -3600, :second)
      task_with_history = %Task{schedule_type: "hourly", last_run_at: last_run, enabled: false}
      refute Task.should_run?(task_with_history, DateTime.utc_now())
    end

    test "interval task returns true when interval has elapsed" do
      # Last ran 2 hours ago, interval is 1h
      last_run = DateTime.add(DateTime.utc_now(), -7200, :second)

      task = %Task{
        schedule_type: "interval",
        schedule_value: "1h",
        last_run_at: last_run,
        enabled: true
      }

      assert Task.should_run?(task, DateTime.utc_now())
    end

    test "interval task returns false when interval has not elapsed" do
      # Last ran 30 minutes ago, interval is 1h
      last_run = DateTime.add(DateTime.utc_now(), -1800, :second)

      task = %Task{
        schedule_type: "interval",
        schedule_value: "1h",
        last_run_at: last_run,
        enabled: true
      }

      refute Task.should_run?(task, DateTime.utc_now())
    end

    test "hourly task returns true after 1 hour" do
      last_run = DateTime.add(DateTime.utc_now(), -3601, :second)

      task = %Task{
        schedule_type: "hourly",
        last_run_at: last_run,
        enabled: true
      }

      assert Task.should_run?(task, DateTime.utc_now())
    end

    test "hourly task returns false before 1 hour" do
      last_run = DateTime.add(DateTime.utc_now(), -3500, :second)

      task = %Task{
        schedule_type: "hourly",
        last_run_at: last_run,
        enabled: true
      }

      refute Task.should_run?(task, DateTime.utc_now())
    end

    test "daily task returns true after 24 hours" do
      last_run = DateTime.add(DateTime.utc_now(), -86401, :second)

      task = %Task{
        schedule_type: "daily",
        last_run_at: last_run,
        enabled: true
      }

      assert Task.should_run?(task, DateTime.utc_now())
    end

    test "daily task returns false before 24 hours" do
      last_run = DateTime.add(DateTime.utc_now(), -86_000, :second)

      task = %Task{
        schedule_type: "daily",
        last_run_at: last_run,
        enabled: true
      }

      refute Task.should_run?(task, DateTime.utc_now())
    end

    test "one_shot task returns false after first run" do
      last_run = DateTime.utc_now() |> DateTime.add(-1, :second)

      task = %Task{
        schedule_type: "one_shot",
        last_run_at: last_run,
        enabled: true
      }

      refute Task.should_run?(task, DateTime.utc_now())
    end

    @tag :skip
    test "cron task handles evaluation without crash" do
      # Cron evaluation depends on Crontab library behavior;
      # just verify it doesn't crash and returns a boolean.
      nine_am_today =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)

      task = %Task{
        schedule_type: "cron",
        schedule: "0 9 * * *",
        last_run_at: nine_am_today,
        enabled: true
      }

      # This may or may not return true depending on time of day,
      # but should not crash
      result = Task.should_run?(task, DateTime.utc_now())
      assert is_boolean(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp errors_on(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Map.keys()
  end
end
