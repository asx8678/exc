defmodule CodePuppyControl.PythonWorkerIntegrationTest do
  @moduledoc """
  Integration tests for Python worker communication.

  These tests verify actual worker process lifecycle management,
  including startup, supervision, and message handling.

  NOTE: Full integration tests with a real Python process require
  the Python worker script to be available. Tests are marked with
  @moduletag :integration and can be run separately.

  Note (ADR-005): These tests exercise the explicit bridge-mode
  compatibility path (PUP_RUNTIME=python), not the default daily-driver
  runtime. The Python-free runtime guarantee is validated separately.
  """

  use ExUnit.Case

  alias CodePuppyControl.PythonWorker.Supervisor, as: WorkerSupervisor
  alias CodePuppyControl.PythonWorker.Port
  alias CodePuppyControl.MockPythonWorker
  alias CodePuppyControl.Run.Registry

  # Integration tests are excluded by default
  @moduletag :integration

  # Set up the supervision tree for each test
  setup do
    # Ensure required processes are started (only if not already running from application)
    unless Process.whereis(CodePuppyControl.Run.Registry) do
      start_link_supervised!({Registry, keys: :unique, name: CodePuppyControl.Run.Registry})
    end

    unless Process.whereis(WorkerSupervisor) do
      start_link_supervised!(WorkerSupervisor)
    end

    # Generate unique run IDs to avoid collisions
    run_id = "test-run-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Clean up any workers started during the test (only if supervisor is running)
      if Process.whereis(WorkerSupervisor) do
        WorkerSupervisor.list_workers()
        |> Enum.each(fn {id, _pid} ->
          WorkerSupervisor.terminate_worker(id)
        end)
      end
    end)

    %{run_id: run_id}
  end

  describe "worker lifecycle" do
    test "starts Python worker and can be looked up in registry", %{run_id: run_id} do
      # Start a worker
      assert {:ok, pid} = WorkerSupervisor.start_worker(run_id)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Should be findable via registry
      assert [{^pid, _}] = Registry.lookup({:python_worker, run_id})

      # Should appear in worker list
      workers = WorkerSupervisor.list_workers()
      assert {run_id, pid} in workers
    end

    test "idempotent start returns existing worker", %{run_id: run_id} do
      # Start first worker
      assert {:ok, pid1} = WorkerSupervisor.start_worker(run_id)

      # Try to start again - should return same worker
      assert {:ok, ^pid1} = WorkerSupervisor.start_worker(run_id)

      # Should only be one worker
      assert WorkerSupervisor.worker_count() == 1
    end

    test "terminates worker gracefully", %{run_id: run_id} do
      # Start a worker
      assert {:ok, pid} = WorkerSupervisor.start_worker(run_id)
      assert Process.alive?(pid)

      # Terminate it
      assert :ok = WorkerSupervisor.terminate_worker(run_id)

      # Give time for termination
      Process.sleep(100)

      # Should no longer be alive
      refute Process.alive?(pid)

      # Should not appear in list
      workers = WorkerSupervisor.list_workers()
      refute run_id in Enum.map(workers, &elem(&1, 0))
    end

    test "terminate_worker returns not_found for non-existent run", %{run_id: run_id} do
      assert {:error, :not_found} = WorkerSupervisor.terminate_worker("nonexistent-#{run_id}")
    end

    test "handles worker crash gracefully via supervisor", %{run_id: run_id} do
      # Start a worker
      assert {:ok, pid} = WorkerSupervisor.start_worker(run_id)
      _original_pid = pid

      # Verify it exists
      assert WorkerSupervisor.worker_count() >= 1

      # Kill the worker process (simulating crash)
      Process.exit(pid, :kill)

      # Wait for supervisor to clean up
      Process.sleep(200)

      # The worker should not exist anymore (temporary restart strategy)
      # Since it's :temporary, it won't be restarted
      workers = WorkerSupervisor.list_workers()
      run_ids = Enum.map(workers, &elem(&1, 0))
      refute run_id in run_ids
    end
  end

  describe "worker statistics" do
    test "worker_count returns correct number of workers" do
      # Start with clean slate (after setup)
      initial_count = WorkerSupervisor.worker_count()

      # Start multiple workers
      run_ids =
        for i <- 1..5 do
          id = "count-test-#{i}-#{System.unique_integer([:positive])}"
          {:ok, _pid} = WorkerSupervisor.start_worker(id)
          id
        end

      # Should have 5 more workers
      assert WorkerSupervisor.worker_count() == initial_count + 5

      # Terminate them
      Enum.each(run_ids, &WorkerSupervisor.terminate_worker/1)

      Process.sleep(100)

      # Back to initial count
      assert WorkerSupervisor.worker_count() == initial_count
    end

    test "list_workers returns all active workers" do
      # Start some workers
      run_ids =
        for i <- 1..3 do
          id = "list-test-#{i}-#{System.unique_integer([:positive])}"
          {:ok, _pid} = WorkerSupervisor.start_worker(id)
          id
        end

      workers = WorkerSupervisor.list_workers()

      # Should have our run_ids
      returned_ids = Enum.map(workers, &elem(&1, 0))

      for run_id <- run_ids do
        assert run_id in returned_ids
      end

      # Each should be a valid PID
      for {_, pid} <- workers do
        assert is_pid(pid)
      end
    end
  end

  describe "mock worker communication" do
    test "mock worker can be started and responds to requests", %{run_id: _run_id} do
      # Start a mock worker instead of real Python process
      {:ok, mock_pid} = MockPythonWorker.start_link([])

      # It should respond to ping
      assert {:ok, response} = MockPythonWorker.handle_request(mock_pid, "ping", {})
      assert response["pong"] == true
      assert is_integer(response["timestamp"])

      # And echo
      assert {:ok, response} =
               MockPythonWorker.handle_request(mock_pid, "echo", %{"test" => "data"})

      assert response["echo"]["test"] == "data"
    end

    test "mock worker sends notifications", %{run_id: _run_id} do
      {:ok, mock_pid} = MockPythonWorker.start_link(parent: self())

      # Send a notification
      MockPythonWorker.send_notification(mock_pid, "run.status", %{"progress" => 0.5})

      # Should receive it
      assert_receive {:mock_notification, notification}, 500
      assert notification["method"] == "run.status"
      assert notification["params"]["progress"] == 0.5
    end

    test "mock worker exits when parent exits", %{run_id: _run_id} do
      parent = self()

      # Spawn a process that starts a mock worker
      child =
        spawn(fn ->
          {:ok, mock_pid} = MockPythonWorker.start_link(parent: parent)
          send(parent, {:worker_started, mock_pid})

          # Keep alive until told to exit
          receive do
            :exit_now -> :ok
          after
            5000 -> :timeout
          end
        end)

      # Wait for mock worker to start
      assert_receive {:worker_started, mock_pid}, 1000
      assert Process.alive?(mock_pid)

      # Exit the child process
      send(child, :exit_now)
      Process.sleep(100)

      # Mock worker should also be dead (it monitors parent)
      refute Process.alive?(mock_pid)
    end

    test "mock worker supports custom handlers", %{run_id: _run_id} do
      {:ok, mock_pid} = MockPythonWorker.start_link([])

      # Set a custom handler
      MockPythonWorker.set_handler(mock_pid, "custom", fn _method, params ->
        {:ok, %{"received" => params, "handled_by" => "custom"}}
      end)

      # Use the custom handler
      assert {:ok, response} =
               MockPythonWorker.handle_request(mock_pid, "custom", %{"foo" => "bar"})

      assert response["received"]["foo"] == "bar"
      assert response["handled_by"] == "custom"

      # Unknown methods still fail
      assert {:error, {:method_not_found, _}} =
               MockPythonWorker.handle_request(mock_pid, "unknown", {})
    end
  end

  describe "Port module via tuple" do
    test "via_tuple returns via tuple format", %{run_id: run_id} do
      via = Port.via_tuple(run_id)
      # Verify it's a via tuple: {:via, module, key}
      assert is_tuple(via)
      assert tuple_size(via) == 3
      assert elem(via, 0) == :via
      # The third element should contain our registry key
      {_, _, {_, {:python_worker, ^run_id}}} = via
    end

    test "pid_to_run_id returns correct run_id", %{run_id: run_id} do
      # Start a worker
      {:ok, pid} = WorkerSupervisor.start_worker(run_id)

      # Lookup should return our run_id
      assert {:ok, ^run_id} = Port.pid_to_run_id(pid)
    end

    test "pid_to_run_id returns error for unknown pid", %{run_id: _run_id} do
      random_pid = spawn(fn -> :timer.sleep(1000) end)
      assert :error = Port.pid_to_run_id(random_pid)

      Process.exit(random_pid, :kill)
    end
  end

  describe "multiple concurrent workers" do
    test "can start multiple workers concurrently", %{run_id: _run_id} do
      # Start 10 workers concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            run_id = "concurrent-#{i}-#{System.unique_integer([:positive])}"
            WorkerSupervisor.start_worker(run_id)
          end)
        end

      # All should succeed
      results = Task.await_many(tasks)

      for {:ok, pid} <- results do
        assert is_pid(pid)
        assert Process.alive?(pid)
      end

      # Should have 10 workers
      assert WorkerSupervisor.worker_count() >= 10
    end

    test "workers are isolated - terminating one doesn't affect others", %{run_id: run_id} do
      # Start three workers
      run_ids = [run_id <> "-a", run_id <> "-b", run_id <> "-c"]

      pids =
        Enum.map(run_ids, fn id ->
          {:ok, pid} = WorkerSupervisor.start_worker(id)
          {id, pid}
        end)

      [_, {id_b, pid_b}, _] = pids

      # Verify all are alive
      Enum.each(pids, fn {_, pid} ->
        assert Process.alive?(pid)
      end)

      # Terminate the middle one
      WorkerSupervisor.terminate_worker(id_b)
      Process.sleep(100)

      # It should be dead
      refute Process.alive?(pid_b)

      # Others should still be alive
      [{_, pid_a}, _, {_, pid_c}] = pids
      assert Process.alive?(pid_a)
      assert Process.alive?(pid_c)
    end
  end

  describe "error handling" do
    test "handles missing script_path gracefully" do
      # Temporarily clear the application config and env vars
      original_config = Application.get_env(:code_puppy_control, :python_worker_script)
      Application.delete_env(:code_puppy_control, :python_worker_script)

      original_env = System.get_env("PUP_PYTHON_WORKER_SCRIPT")
      original_legacy = System.get_env("PYTHON_WORKER_SCRIPT")
      System.delete_env("PUP_PYTHON_WORKER_SCRIPT")
      System.delete_env("PYTHON_WORKER_SCRIPT")

      on_exit(fn ->
        if original_config do
          Application.put_env(:code_puppy_control, :python_worker_script, original_config)
        end

        if original_env, do: System.put_env("PUP_PYTHON_WORKER_SCRIPT", original_env)
        if original_legacy, do: System.put_env("PYTHON_WORKER_SCRIPT", original_legacy)
      end)

      # Trying to start without script path should return a clear error tuple
      # (previously raised; now returns {:error, {:python_worker_script_not_configured, _}})
      assert {:error, {:python_worker_script_not_configured, msg}} =
               WorkerSupervisor.start_worker("no-config-test")

      assert is_binary(msg)
      assert msg =~ "not configured" or msg =~ "not found"
    end

    test "shutdown is idempotent", %{run_id: run_id} do
      # Start and terminate
      {:ok, _pid} = WorkerSupervisor.start_worker(run_id)
      assert :ok = WorkerSupervisor.terminate_worker(run_id)

      # Second terminate should return not_found
      assert {:error, :not_found} = WorkerSupervisor.terminate_worker(run_id)
    end
  end
end
