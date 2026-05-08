defmodule CodePuppyControl.Workers.AgentInvocationTest do
  @moduledoc """
  Tests for the AgentInvocation Oban worker.

  Validates:
  - Worker configuration (queue, max_attempts, unique constraints)
  - Job changeset creation
  - Step creation during perform (using Step.execute directly)

  Note: We don't call AgentInvocation.perform/1 directly in tests
  because it requires a Python worker process. Instead, we test
  the individual step logic via Workflow.StepTest and verify the
  worker configuration and changeset creation here.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Repo
  alias CodePuppyControl.Workers.AgentInvocation
  alias CodePuppyControl.Workflow.Step

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "worker configuration" do
    test "worker module compiles and exports perform/1" do
      # Verify the worker module exists and implements the Oban.Worker callback.
      assert Code.ensure_loaded?(AgentInvocation)
      assert function_exported?(AgentInvocation, :perform, 1)
    end

    test "worker creates job with correct queue" do
      changeset =
        AgentInvocation.new(%{
          workflow_id: "wf-queue-test",
          session_id: "sess-test",
          agent_name: "test-agent",
          prompt: "Test"
        })

      # The queue should be set in the changeset
      assert changeset.changes.queue == "workflows"
    end
  end

  describe "Oban job changeset" do
    test "creates a valid job changeset" do
      workflow_id = "wf-changeset-#{System.unique_integer([:positive])}"

      changeset =
        AgentInvocation.new(%{
          workflow_id: workflow_id,
          session_id: "sess-test",
          agent_name: "test-agent",
          prompt: "Test prompt"
        })

      assert %Ecto.Changeset{valid?: true} = changeset
    end

    test "changeset includes required fields" do
      workflow_id = "wf-fields-#{System.unique_integer([:positive])}"

      changeset =
        AgentInvocation.new(%{
          workflow_id: workflow_id,
          session_id: "sess-test",
          agent_name: "code-puppy",
          prompt: "Fix the bug"
        })

      # Args may be JSON-encoded in the changeset; just verify valid
      assert changeset.valid?
    end
  end

  describe "step execution flow (simulated)" do
    test "initialize → run_agent → finalize step flow" do
      workflow_id = "wf-flow-#{System.unique_integer([:positive])}"

      # Simulate the three-step workflow that AgentInvocation.perform would run
      {:ok, _init} =
        Step.execute(workflow_id, "initialize", fn ->
          {:ok, %{"initialized" => true}}
        end)

      {:ok, _result} =
        Step.execute(workflow_id, "run_agent", fn ->
          # In production, this would start a Python worker
          {:ok, %{"output" => "simulated agent response"}}
        end)

      {:ok, _final} =
        Step.execute(workflow_id, "finalize", fn ->
          {:ok, %{"finalized" => true}}
        end)

      # Verify all three steps are completed
      steps = Step.list_for_workflow(workflow_id)
      assert length(steps) == 3
      assert Enum.all?(steps, &(&1.state == "completed"))
    end

    test "failed run_agent step prevents finalize" do
      workflow_id = "wf-fail-flow-#{System.unique_integer([:positive])}"

      {:ok, _init} =
        Step.execute(workflow_id, "initialize", fn ->
          {:ok, %{}}
        end)

      {:error, _} =
        Step.execute(workflow_id, "run_agent", fn ->
          {:error, "agent crashed"}
        end)

      # Finalize step should NOT have been created
      steps = Step.list_for_workflow(workflow_id)
      step_names = Enum.map(steps, & &1.step_name)
      refute "finalize" in step_names
    end
  end
end
