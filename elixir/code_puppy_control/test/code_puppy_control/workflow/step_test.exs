defmodule CodePuppyControl.Workflow.StepTest do
  @moduledoc """
  Tests for Workflow.Step — the core idempotency primitive.

  Validates:
  - Step creation with unique constraint
  - State machine transitions (pending → running → completed/failed)
  - Exactly-once execution via execute/4
  - Retry semantics (failed steps with remaining attempts)
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Repo
  alias CodePuppyControl.Workflow.Step

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # Helper to extract error keys from a changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  describe "changeset/2" do
    test "creates a valid step with required fields" do
      changeset =
        Step.changeset(%Step{}, %{
          workflow_id: "wf-1",
          step_name: "initialize"
        })

      assert changeset.valid?
    end

    test "requires workflow_id and step_name" do
      changeset = Step.changeset(%Step{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :workflow_id)
      assert Map.has_key?(errors, :step_name)
    end

    test "validates state is in allowed set" do
      valid_changeset =
        Step.changeset(%Step{}, %{
          workflow_id: "wf-1",
          step_name: "init",
          state: "completed"
        })

      assert valid_changeset.valid?

      invalid_changeset =
        Step.changeset(%Step{}, %{
          workflow_id: "wf-1",
          step_name: "init",
          state: "exploding"
        })

      refute invalid_changeset.valid?
    end

    test "validates max_attempts is positive" do
      changeset =
        Step.changeset(%Step{}, %{
          workflow_id: "wf-1",
          step_name: "init",
          max_attempts: 0
        })

      refute changeset.valid?
    end
  end

  describe "state machine transitions" do
    setup do
      step =
        %Step{}
        |> Step.changeset(%{
          workflow_id: "wf-sm-#{System.unique_integer([:positive])}",
          step_name: "test_step"
        })
        |> Repo.insert!()

      %{step: step}
    end

    test "pending → running", %{step: step} do
      {:ok, updated} = Step.start(step)
      assert updated.state == "running"
      assert updated.attempt == 1
      assert updated.started_at != nil
    end

    test "running → completed with result", %{step: step} do
      {:ok, running} = Step.start(step)
      {:ok, completed} = Step.complete(running, %{"output" => "hello"})
      assert completed.state == "completed"
      assert completed.result == %{"output" => "hello"}
      assert completed.completed_at != nil
    end

    test "running → failed with error", %{step: step} do
      {:ok, running} = Step.start(step)
      {:ok, failed} = Step.fail(running, "something went wrong")
      assert failed.state == "failed"
      assert failed.error == "something went wrong"
    end

    test "failed → running (retry)", %{step: step} do
      {:ok, running} = Step.start(step)
      {:ok, failed} = Step.fail(running, "transient error")
      {:ok, retried} = Step.start(failed)
      assert retried.state == "running"
      assert retried.attempt == 2
    end

    test "start is idempotent for running step", %{step: step} do
      {:ok, running} = Step.start(step)
      {:ok, same} = Step.start(running)
      assert same.id == running.id
      assert same.state == "running"
    end

    test "start is idempotent for completed step", %{step: step} do
      {:ok, running} = Step.start(step)
      {:ok, completed} = Step.complete(running, %{"ok" => true})
      {:ok, same} = Step.start(completed)
      assert same.id == completed.id
      assert same.state == "completed"
    end

    test "start fails when max_attempts exceeded", %{step: step} do
      step =
        step
        |> Step.changeset(%{max_attempts: 1})
        |> Repo.update!()

      {:ok, running} = Step.start(step)
      {:ok, failed} = Step.fail(running, "exhausted")
      {:error, :max_attempts_exceeded} = Step.start(failed)
    end

    test "pending → cancelled via cancel/1", %{step: step} do
      {:ok, cancelled} = Step.cancel(step)
      assert cancelled.state == "cancelled"
      assert cancelled.completed_at != nil
    end

    test "running → cancelled via cancel/1", %{step: step} do
      {:ok, running} = Step.start(step)
      {:ok, cancelled} = Step.cancel(running)
      assert cancelled.state == "cancelled"
      assert cancelled.completed_at != nil
    end

    test "cancel on terminal state is a no-op", %{step: step} do
      {:ok, running} = Step.start(step)
      {:ok, completed} = Step.complete(running, %{"done" => true})
      {:ok, same} = Step.cancel(completed)
      assert same.state == "completed"
    end

    test "execute returns {:error, :cancelled} for cancelled step" do
      workflow_id = "wf-cancel-exec-#{System.unique_integer([:positive])}"

      # Create and cancel a step directly
      step =
        %Step{}
        |> Step.changeset(%{workflow_id: workflow_id, step_name: "cancelled_step"})
        |> Repo.insert!()

      {:ok, _} = Step.cancel(step)

      # Attempting to execute should return cancelled error
      result =
        Step.execute(workflow_id, "cancelled_step", fn -> {:ok, %{"should_not_run" => true}} end)

      assert result == {:error, :cancelled}
    end
  end

  describe "retriable?/1" do
    test "failed step with remaining attempts is retriable" do
      step =
        %Step{}
        |> Step.changeset(%{
          workflow_id: "wf-retry",
          step_name: "retry_step",
          state: "failed",
          attempt: 1,
          max_attempts: 3
        })
        |> Repo.insert!()

      assert Step.retriable?(step)
    end

    test "failed step with no remaining attempts is not retriable" do
      step =
        %Step{}
        |> Step.changeset(%{
          workflow_id: "wf-max",
          step_name: "max_step",
          state: "failed",
          attempt: 3,
          max_attempts: 3
        })
        |> Repo.insert!()

      refute Step.retriable?(step)
    end

    test "completed step is not retriable" do
      step =
        %Step{}
        |> Step.changeset(%{
          workflow_id: "wf-done",
          step_name: "done_step",
          state: "completed"
        })
        |> Repo.insert!()

      refute Step.retriable?(step)
    end
  end

  describe "execute/4 — idempotent execution" do
    test "executes function and stores result" do
      {:ok, result} =
        Step.execute("wf-exec-1", "my_step", fn ->
          {:ok, %{"computed" => 42}}
        end)

      assert result == %{"computed" => 42}

      step = Step.find("wf-exec-1", "my_step")
      assert step != nil
      assert step.state == "completed"
      assert step.result == %{"computed" => 42}
    end

    test "returns cached result on re-execution (exactly-once)" do
      call_count = :counters.new(1, [:atomics])

      {:ok, _} =
        Step.execute("wf-idempotent", "my_step", fn ->
          :counters.add(call_count, 1, 1)
          {:ok, %{"value" => "first"}}
        end)

      {:ok, result} =
        Step.execute("wf-idempotent", "my_step", fn ->
          :counters.add(call_count, 1, 1)
          {:ok, %{"value" => "second"}}
        end)

      assert result == %{"value" => "first"}
      assert :counters.get(call_count, 1) == 1
    end

    test "handles function errors" do
      result =
        Step.execute("wf-fail", "failing_step", fn ->
          {:error, "boom"}
        end)

      assert result == {:error, "boom"}

      step = Step.find("wf-fail", "failing_step")
      assert step.state == "failed"
    end
  end

  describe "find/2 and list_for_workflow/1" do
    test "find returns nil for non-existent step" do
      assert Step.find("nonexistent", "step") == nil
    end

    test "find returns existing step" do
      %Step{}
      |> Step.changeset(%{workflow_id: "wf-find", step_name: "found"})
      |> Repo.insert!()

      step = Step.find("wf-find", "found")
      assert step != nil
      assert step.step_name == "found"
    end

    test "list_for_workflow returns steps in insertion order" do
      workflow_id = "wf-list-#{System.unique_integer([:positive])}"

      %Step{}
      |> Step.changeset(%{workflow_id: workflow_id, step_name: "step_a"})
      |> Repo.insert!()

      %Step{}
      |> Step.changeset(%{workflow_id: workflow_id, step_name: "step_b"})
      |> Repo.insert!()

      steps = Step.list_for_workflow(workflow_id)
      assert length(steps) == 2
      assert Enum.map(steps, & &1.step_name) == ["step_a", "step_b"]
    end
  end
end
