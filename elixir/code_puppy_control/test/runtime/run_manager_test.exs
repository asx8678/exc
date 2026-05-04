defmodule CodePuppyControl.Runtime.RunManagerTest do
  @moduledoc """
  Tests for Run.Manager — run lifecycle coordination.

  With the executor boundary (code-puppy-96g), Manager.start_run/3
  no longer requires a Python worker.  Default/Elixir mode uses
  Run.Executor.Elixir which starts a lightweight GenServer.
  Python mode (PUP_RUNTIME=python) uses Run.Executor.Python.

  These tests cover:
  - Run.State safe_status_atom/1 (unit-level)
  - Run.Supervisor operations
  - Manager error paths (not_found)
  - Manager.start_run/3 with Elixir executor (no Python required)
  - Manager.start_run/3 with Python executor (fails gracefully)
  - Cancel/delete operations through the executor boundary

  Refs: code-puppy-96g
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Run.{Manager, State, Supervisor, Executor}

  # Env vars we mutate; must be async: false
  @pup_runtime "PUP_RUNTIME"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp save_env(vars) do
    for var <- vars, into: %{} do
      {var, System.get_env(var)}
    end
  end

  defp restore_env(saved) do
    for {var, val} <- saved do
      case val do
        nil -> System.delete_env(var)
        v -> System.put_env(var, v)
      end
    end
  end

  defp with_saved_env(vars, fun) do
    saved = save_env(vars)

    try do
      fun.()
    after
      restore_env(saved)
    end
  end

  defp with_app_env(key, fun) do
    original = Application.get_env(:code_puppy_control, key)

    try do
      fun.()
    after
      case original do
        nil -> Application.delete_env(:code_puppy_control, key)
        _ -> Application.put_env(:code_puppy_control, key, original)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Run.State (unit-level)
  # ---------------------------------------------------------------------------

  describe "Run.State safe_status_atom/1" do
    alias CodePuppyControl.Run.State

    test "converts valid string statuses" do
      assert State.safe_status_atom("starting") == :starting
      assert State.safe_status_atom("running") == :running
      assert State.safe_status_atom("completed") == :completed
      assert State.safe_status_atom("failed") == :failed
      assert State.safe_status_atom("cancelled") == :cancelled
      assert State.safe_status_atom("paused") == :paused
      assert State.safe_status_atom("pending") == :pending
    end

    test "returns :unknown for invalid string" do
      assert State.safe_status_atom("exploding") == :unknown
      assert State.safe_status_atom("") == :unknown
    end

    test "passes through valid atoms" do
      assert State.safe_status_atom(:running) == :running
      assert State.safe_status_atom(:completed) == :completed
    end

    test "returns :unknown for invalid atoms" do
      assert State.safe_status_atom(:exploding) == :unknown
    end

    test "handles non-string, non-atom input" do
      assert State.safe_status_atom(123) == :unknown
      assert State.safe_status_atom(nil) == :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Run.Supervisor
  # ---------------------------------------------------------------------------

  describe "Run.Supervisor.run_count/0" do
    test "returns a non-negative integer" do
      count = Supervisor.run_count()
      assert is_integer(count) and count >= 0
    end
  end

  describe "Run.Supervisor.terminate_run/1" do
    test "returns not_found for nonexistent run" do
      assert {:error, :not_found} = Supervisor.terminate_run("nonexistent-run-99999")
    end
  end

  # ---------------------------------------------------------------------------
  # Manager — error paths
  # ---------------------------------------------------------------------------

  describe "Manager.get_run/1" do
    test "returns not_found for nonexistent run" do
      assert {:error, :not_found} = Manager.get_run("nonexistent-run-99999")
    end
  end

  describe "Manager.cancel_run/2" do
    test "returns not_found for nonexistent run" do
      assert {:error, :not_found} = Manager.cancel_run("nonexistent-run-99999")
    end
  end

  describe "Manager.list_runs/1" do
    test "returns a list" do
      result = Manager.list_runs()
      assert is_list(result)
    end
  end

  describe "Manager.list_runs_with_details/1" do
    test "returns a list" do
      result = Manager.list_runs_with_details()
      assert is_list(result)
    end
  end

  describe "Manager.delete_run/1" do
    test "returns not_found for nonexistent run" do
      assert {:error, :not_found} = Manager.delete_run("nonexistent-run-99999")
    end
  end

  # ---------------------------------------------------------------------------
  # Executor module selection (code-puppy-96g)
  # ---------------------------------------------------------------------------

  describe "Executor.executor_module/0" do
    test "defaults to Elixir executor when PUP_RUNTIME is unset" do
      with_saved_env([@pup_runtime], fn ->
        System.delete_env(@pup_runtime)

        with_app_env(:run_executor_module, fn ->
          Application.delete_env(:code_puppy_control, :run_executor_module)
          assert Executor.executor_module() == CodePuppyControl.Run.Executor.Elixir
        end)
      end)
    end

    test "selects Elixir executor when PUP_RUNTIME=elixir" do
      with_saved_env([@pup_runtime], fn ->
        System.put_env(@pup_runtime, "elixir")

        with_app_env(:run_executor_module, fn ->
          Application.delete_env(:code_puppy_control, :run_executor_module)
          assert Executor.executor_module() == CodePuppyControl.Run.Executor.Elixir
        end)
      end)
    end

    test "selects Elixir executor when PUP_RUNTIME=auto" do
      with_saved_env([@pup_runtime], fn ->
        System.put_env(@pup_runtime, "auto")

        with_app_env(:run_executor_module, fn ->
          Application.delete_env(:code_puppy_control, :run_executor_module)
          assert Executor.executor_module() == CodePuppyControl.Run.Executor.Elixir
        end)
      end)
    end

    test "selects Python executor when PUP_RUNTIME=python" do
      with_saved_env([@pup_runtime], fn ->
        System.put_env(@pup_runtime, "python")

        with_app_env(:run_executor_module, fn ->
          Application.delete_env(:code_puppy_control, :run_executor_module)
          assert Executor.executor_module() == CodePuppyControl.Run.Executor.Python
        end)
      end)
    end

    test "app env :run_executor_module overrides runtime selection" do
      with_saved_env([@pup_runtime], fn ->
        System.put_env(@pup_runtime, "python")

        with_app_env(:run_executor_module, fn ->
          Application.put_env(
            :code_puppy_control,
            :run_executor_module,
            CodePuppyControl.Run.Executor.Elixir
          )

          # App env should win over PUP_RUNTIME=python
          assert Executor.executor_module() == CodePuppyControl.Run.Executor.Elixir
        end)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Manager.start_run/3 — Elixir executor (no Python required)
  # ---------------------------------------------------------------------------

  describe "Manager.start_run/3 with Elixir executor" do
    setup do
      # Ensure Elixir executor is selected
      saved_runtime = System.get_env(@pup_runtime)

      System.delete_env(@pup_runtime)

      saved_app =
        Application.get_env(:code_puppy_control, :run_executor_module)

      Application.delete_env(:code_puppy_control, :run_executor_module)

      on_exit(fn ->
        case saved_runtime do
          nil -> System.delete_env(@pup_runtime)
          v -> System.put_env(@pup_runtime, v)
        end

        case saved_app do
          nil -> Application.delete_env(:code_puppy_control, :run_executor_module)
          v -> Application.put_env(:code_puppy_control, :run_executor_module, v)
        end
      end)

      :ok
    end

    test "succeeds with no Python worker script and no python3 on PATH" do
      # Sanitize PATH to remove python3
      saved_path = System.get_env("PATH")

      empty_path =
        Path.join(System.tmp_dir!(), "no_python3_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(empty_path)

      saved_pws = System.get_env("PUP_PYTHON_WORKER_SCRIPT")
      saved_lws = System.get_env("PYTHON_WORKER_SCRIPT")

      System.put_env("PATH", empty_path)
      System.delete_env("PUP_PYTHON_WORKER_SCRIPT")
      System.delete_env("PYTHON_WORKER_SCRIPT")

      try do
        assert {:ok, run_id} = Manager.start_run("test-session", "test-agent")
        assert is_binary(run_id)
        assert run_id =~ "run-"

        # Verify run state was created
        assert {:ok, state} = Manager.get_run(run_id)
        assert state.session_id == "test-session"
        assert state.agent_name == "test-agent"

        # Cleanup
        Manager.delete_run(run_id)
      after
        System.put_env("PATH", saved_path)
        System.delete_env("PUP_PYTHON_WORKER_SCRIPT")
        System.delete_env("PYTHON_WORKER_SCRIPT")

        if saved_pws, do: System.put_env("PUP_PYTHON_WORKER_SCRIPT", saved_pws)
        if saved_lws, do: System.put_env("PYTHON_WORKER_SCRIPT", saved_lws)

        File.rm_rf(empty_path)
      end
    end

    test "creates run state with executor metadata" do
      assert {:ok, run_id} = Manager.start_run("test-session-meta", "test-agent-meta")
      assert {:ok, state} = Manager.get_run(run_id)
      assert state.metadata.executor_module == CodePuppyControl.Run.Executor.Elixir
      Manager.delete_run(run_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Manager.start_run/3 — Python executor (fails gracefully)
  # ---------------------------------------------------------------------------

  describe "Manager.start_run/3 with Python executor" do
    setup do
      saved_runtime = System.get_env(@pup_runtime)

      on_exit(fn ->
        case saved_runtime do
          nil -> System.delete_env(@pup_runtime)
          v -> System.put_env(@pup_runtime, v)
        end
      end)

      :ok
    end

    test "returns error when PUP_RUNTIME=python and no script configured" do
      with_saved_env([@pup_runtime, "PUP_PYTHON_WORKER_SCRIPT", "PYTHON_WORKER_SCRIPT"], fn ->
        System.put_env(@pup_runtime, "python")
        System.delete_env("PUP_PYTHON_WORKER_SCRIPT")
        System.delete_env("PYTHON_WORKER_SCRIPT")

        with_app_env(:python_worker_script, fn ->
          Application.delete_env(:code_puppy_control, :python_worker_script)
          Application.delete_env(:code_puppy_control, :run_executor_module)

          result = Manager.start_run("test-session-py", "test-agent-py")

          assert {:error, _reason} = result
        end)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Cancel and delete through executor boundary
  # ---------------------------------------------------------------------------

  describe "Manager.cancel_run/2 through Elixir executor" do
    setup do
      saved_runtime = System.get_env(@pup_runtime)

      System.delete_env(@pup_runtime)

      saved_app =
        Application.get_env(:code_puppy_control, :run_executor_module)

      Application.delete_env(:code_puppy_control, :run_executor_module)

      on_exit(fn ->
        case saved_runtime do
          nil -> System.delete_env(@pup_runtime)
          v -> System.put_env(@pup_runtime, v)
        end

        case saved_app do
          nil -> Application.delete_env(:code_puppy_control, :run_executor_module)
          v -> Application.put_env(:code_puppy_control, :run_executor_module, v)
        end
      end)

      :ok
    end

    test "cancels a running Elixir-executor run" do
      assert {:ok, run_id} = Manager.start_run("cancel-session", "cancel-agent")
      assert {:ok, state} = Manager.get_run(run_id)
      # The run should be starting or running (async notification)
      assert state.status in [:starting, :running]

      assert :ok = Manager.cancel_run(run_id, "test_cancel")

      # Give the async cast a moment
      Process.sleep(50)
      assert {:ok, state} = Manager.get_run(run_id)
      assert state.status == :cancelled

      Manager.delete_run(run_id)
    end

    test "returns :ok for already-completed run" do
      assert {:ok, run_id} = Manager.start_run("completed-session", "completed-agent")
      # Manually set state to completed
      State.set_status(run_id, :completed)
      Process.sleep(50)

      assert :ok = Manager.cancel_run(run_id)

      Manager.delete_run(run_id)
    end
  end

  describe "Manager.delete_run/1 through Elixir executor" do
    setup do
      saved_runtime = System.get_env(@pup_runtime)

      System.delete_env(@pup_runtime)

      saved_app =
        Application.get_env(:code_puppy_control, :run_executor_module)

      Application.delete_env(:code_puppy_control, :run_executor_module)

      on_exit(fn ->
        case saved_runtime do
          nil -> System.delete_env(@pup_runtime)
          v -> System.put_env(@pup_runtime, v)
        end

        case saved_app do
          nil -> Application.delete_env(:code_puppy_control, :run_executor_module)
          v -> Application.put_env(:code_puppy_control, :run_executor_module, v)
        end
      end)

      :ok
    end

    test "deletes a run and its executor process" do
      assert {:ok, run_id} = Manager.start_run("delete-session", "delete-agent")
      assert {:ok, _} = Manager.get_run(run_id)

      assert :ok = Manager.delete_run(run_id)
      assert {:error, :not_found} = Manager.get_run(run_id)
    end
  end
end
