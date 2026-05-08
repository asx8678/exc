defmodule CodePuppyControl.Scheduler.TaskTest do
  @moduledoc """
  Tests for the Task schema and scheduling logic.
  """

  use ExUnit.Case, async: true
  alias CodePuppyControl.Scheduler.Task

  describe "changeset/2" do
    test "validates required fields" do
      changeset = Task.changeset(%Task{}, %{})
      refute changeset.valid?

      assert %{
               name: ["can't be blank"],
               agent_name: ["can't be blank"],
               prompt: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "accepts valid attributes" do
      attrs = %{
        name: "test-task",
        agent_name: "code-puppy",
        prompt: "test prompt",
        schedule_type: "interval",
        schedule_value: "1h"
      }

      changeset = Task.changeset(%Task{}, attrs)
      assert changeset.valid?
    end

    test "validates cron expressions" do
      attrs = %{
        name: "cron-task",
        agent_name: "code-puppy",
        prompt: "test",
        schedule_type: "cron",
        schedule: "invalid"
      }

      changeset = Task.changeset(%Task{}, attrs)
      refute changeset.valid?
      assert %{schedule: ["invalid cron expression: " <> _]} = errors_on(changeset)
    end

    test "accepts valid cron expression" do
      attrs = %{
        name: "daily-task",
        agent_name: "code-puppy",
        prompt: "test",
        schedule_type: "cron",
        schedule: "0 9 * * *"
      }

      changeset = Task.changeset(%Task{}, attrs)
      assert changeset.valid?
    end

    test "validates schedule_value for interval type" do
      attrs = %{
        name: "interval-task",
        agent_name: "code-puppy",
        prompt: "test",
        schedule_type: "interval",
        schedule_value: "invalid"
      }

      changeset = Task.changeset(%Task{}, attrs)
      refute changeset.valid?
      assert %{schedule_value: ["invalid interval format" <> _]} = errors_on(changeset)
    end
  end

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
      assert {:ok, 86_400} = Task.parse_interval("1d")
    end

    test "rejects invalid format" do
      assert {:error, _} = Task.parse_interval("invalid")
      assert {:error, _} = Task.parse_interval("30")
      assert {:error, _} = Task.parse_interval("")
    end
  end

  describe "should_run?/2" do
    test "never run task should run" do
      task = %Task{
        last_run_at: nil,
        enabled: true,
        schedule_type: "interval",
        schedule_value: "1h"
      }

      assert Task.should_run?(task, DateTime.utc_now())
    end

    test "disabled task should not run" do
      task = %Task{last_run_at: nil, enabled: false}
      refute Task.should_run?(task, DateTime.utc_now())
    end

    test "one-shot task that ran should not run again" do
      now = DateTime.utc_now()
      task = %Task{last_run_at: now, enabled: true, schedule_type: "one_shot"}
      refute Task.should_run?(task, now)
    end

    test "interval task respects schedule" do
      two_hours_ago = DateTime.add(DateTime.utc_now(), -7200, :second)

      task = %Task{
        last_run_at: two_hours_ago,
        enabled: true,
        schedule_type: "interval",
        schedule_value: "1h"
      }

      assert Task.should_run?(task, DateTime.utc_now())
    end

    test "hourly task respects schedule" do
      two_hours_ago = DateTime.add(DateTime.utc_now(), -7200, :second)

      task = %Task{
        last_run_at: two_hours_ago,
        enabled: true,
        schedule_type: "hourly"
      }

      assert Task.should_run?(task, DateTime.utc_now())
    end

    test "daily task respects schedule" do
      two_days_ago = DateTime.add(DateTime.utc_now(), -172_800, :second)

      task = %Task{
        last_run_at: two_days_ago,
        enabled: true,
        schedule_type: "daily"
      }

      assert Task.should_run?(task, DateTime.utc_now())
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
