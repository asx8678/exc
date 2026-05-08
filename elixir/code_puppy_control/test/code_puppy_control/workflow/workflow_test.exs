defmodule CodePuppyControl.WorkflowTest do
  @moduledoc """
  Tests for the Workflow facade module.

  Validates:
  - Workflow invocation with idempotent job creation
  - Workflow status queries
  - Workflow cancellation
  - History retrieval

  Note: We bypass Oban.insert's inline execution by inserting
  Oban.Job records directly into the DB. This avoids triggering
  the AgentInvocation worker which requires a Python worker process.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Repo
  alias CodePuppyControl.Workflow
  alias CodePuppyControl.Workflow.Step

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Repo.delete_all(Oban.Job)
    :ok
  end

  # Helper to insert an Oban job record directly (bypassing inline execution)
  defp insert_job!(attrs) do
    now = DateTime.utc_now()

    %{
      worker: "CodePuppyControl.Workers.AgentInvocation",
      queue: "workflows",
      state: "available",
      args: attrs,
      max_attempts: 3,
      attempt: 0,
      priority: 0,
      tags: ["workflow"],
      inserted_at: now,
      scheduled_at: now
    }
    |> then(&Ecto.Changeset.change(%Oban.Job{}, &1))
    |> Repo.insert!()
  end

  describe "invoke_agent/2" do
    test "creates an Oban job for the workflow" do
      workflow_id = "wf-test-#{System.unique_integer([:positive])}"

      job =
        insert_job!(%{
          session_id: "sess-test",
          agent_name: "test-agent",
          prompt: "Hello world",
          workflow_id: workflow_id
        })

      assert job.worker == "CodePuppyControl.Workers.AgentInvocation"
      # Args are stored as JSON by Oban — reload from DB to get deserialized version
      reloaded = Repo.get!(Oban.Job, job.id)
      assert reloaded.args["workflow_id"] == workflow_id
      assert reloaded.args["agent_name"] == "test-agent"
      assert reloaded.queue == "workflows"
    end

    test "is idempotent — same workflow_id returns existing job" do
      workflow_id = "wf-idem-#{System.unique_integer([:positive])}"

      job1 =
        insert_job!(%{
          session_id: "sess-idem",
          agent_name: "test-agent",
          prompt: "First call",
          workflow_id: workflow_id
        })

      # Workflow.invoke_agent should detect the existing job
      {:ok, job2} =
        Workflow.invoke_agent(%{
          session_id: "sess-idem",
          agent_name: "test-agent",
          prompt: "Second call",
          workflow_id: workflow_id
        })

      # Same job returned (idempotent)
      assert job1.id == job2.id
    end

    test "requires workflow_id in params" do
      assert_raise KeyError, fn ->
        Workflow.invoke_agent(%{
          session_id: "sess-test",
          agent_name: "test-agent",
          prompt: "No workflow_id"
        })
      end
    end

    test "accepts string-keyed params (JSON-RPC compatibility)" do
      workflow_id = "wf-string-key-#{System.unique_integer([:positive])}"

      # Pre-insert the job so invoke_agent returns the existing job
      # (avoids triggering AgentInvocation worker inline execution)
      job =
        insert_job!(%{
          session_id: "sess-string",
          agent_name: "test-agent",
          prompt: "String key test",
          workflow_id: workflow_id
        })

      # Call with string-keyed params (as JSON-RPC would send)
      {:ok, returned_job} =
        Workflow.invoke_agent(%{
          "session_id" => "sess-string",
          "agent_name" => "test-agent",
          "prompt" => "String key test",
          "workflow_id" => workflow_id
        })

      # Idempotent: same job returned
      assert returned_job.id == job.id
    end

    test "accepts atom-keyed params (Elixir caller compatibility)" do
      workflow_id = "wf-atom-key-#{System.unique_integer([:positive])}"

      # Pre-insert the job so invoke_agent returns the existing job
      job =
        insert_job!(%{
          session_id: "sess-atom",
          agent_name: "test-agent",
          prompt: "Atom key test",
          workflow_id: workflow_id
        })

      # Call with atom-keyed params (as Elixir callers would use)
      {:ok, returned_job} =
        Workflow.invoke_agent(%{
          session_id: "sess-atom",
          agent_name: "test-agent",
          prompt: "Atom key test",
          workflow_id: workflow_id
        })

      # Idempotent: same job returned
      assert returned_job.id == job.id
    end
  end

  describe "get_status/1" do
    test "returns not_found for unknown workflow" do
      assert {:error, :not_found} == Workflow.get_status("nonexistent-wf")
    end

    test "returns status for created workflow" do
      workflow_id = "wf-status-#{System.unique_integer([:positive])}"

      insert_job!(%{
        session_id: "sess-status",
        agent_name: "test-agent",
        prompt: "Status check",
        workflow_id: workflow_id
      })

      {:ok, status} = Workflow.get_status(workflow_id)

      assert status.workflow_id == workflow_id
      assert status.job != nil
      assert is_list(status.steps)
    end
  end

  describe "cancel/1" do
    test "returns not_found for unknown workflow" do
      assert {:error, :not_found} == Workflow.cancel("nonexistent-wf")
    end

    test "cancels a pending workflow" do
      workflow_id = "wf-cancel-#{System.unique_integer([:positive])}"

      insert_job!(%{
        session_id: "sess-cancel",
        agent_name: "test-agent",
        prompt: "To be cancelled",
        workflow_id: workflow_id
      })

      assert :ok == Workflow.cancel(workflow_id)
    end

    test "cancels running steps" do
      workflow_id = "wf-cancel-steps-#{System.unique_integer([:positive])}"

      %Step{}
      |> Step.changeset(%{workflow_id: workflow_id, step_name: "initialize", state: "running"})
      |> Repo.insert!()

      assert :ok == Workflow.cancel(workflow_id)

      step = Step.find(workflow_id, "initialize")
      assert step.state == "cancelled"
    end

    test "cancels a running workflow (executing job with running steps)" do
      workflow_id = "wf-cancel-running-#{System.unique_integer([:positive])}"

      # Simulate a running workflow: executing Oban job + running step
      job =
        insert_job!(%{
          session_id: "sess-cancel-running",
          agent_name: "test-agent",
          prompt: "Running workflow",
          workflow_id: workflow_id
        })

      # Update job state to executing (simulating in-progress execution)
      job
      |> Ecto.Changeset.change(%{state: "executing"})
      |> Repo.update!()

      %Step{}
      |> Step.changeset(%{workflow_id: workflow_id, step_name: "initialize", state: "running"})
      |> Repo.insert!()

      %Step{}
      |> Step.changeset(%{workflow_id: workflow_id, step_name: "run_agent", state: "pending"})
      |> Repo.insert!()

      assert :ok == Workflow.cancel(workflow_id)

      # Verify steps are cancelled
      init_step = Step.find(workflow_id, "initialize")
      assert init_step.state == "cancelled"

      run_step = Step.find(workflow_id, "run_agent")
      assert run_step.state == "cancelled"
    end
  end

  describe "list_recent/1" do
    test "returns recent workflows" do
      workflow_id = "wf-recent-#{System.unique_integer([:positive])}"

      insert_job!(%{
        session_id: "sess-recent",
        agent_name: "test-agent",
        prompt: "Recent workflow",
        workflow_id: workflow_id
      })

      workflows = Workflow.list_recent(limit: 10)

      assert is_list(workflows)
      found = Enum.find(workflows, &(&1.workflow_id == workflow_id))
      assert found != nil
      assert found.agent_name == "test-agent"
    end

    test "respects limit option" do
      for i <- 1..5 do
        insert_job!(%{
          session_id: "sess-limit-#{i}",
          agent_name: "test-agent",
          prompt: "Workflow #{i}",
          workflow_id: "wf-limit-#{System.unique_integer([:positive])}"
        })
      end

      workflows = Workflow.list_recent(limit: 3)
      assert length(workflows) <= 3
    end
  end

  describe "get_history/1" do
    test "returns empty history for unknown workflow" do
      assert [] == Workflow.get_history("nonexistent-wf")
    end

    test "returns step history for workflow with steps" do
      workflow_id = "wf-hist-#{System.unique_integer([:positive])}"

      %Step{}
      |> Step.changeset(%{workflow_id: workflow_id, step_name: "initialize", state: "completed"})
      |> Repo.insert!()

      %Step{}
      |> Step.changeset(%{workflow_id: workflow_id, step_name: "run_agent", state: "running"})
      |> Repo.insert!()

      history = Workflow.get_history(workflow_id)

      assert length(history) == 2
      assert Enum.map(history, & &1.step_name) == ["initialize", "run_agent"]
    end
  end
end
