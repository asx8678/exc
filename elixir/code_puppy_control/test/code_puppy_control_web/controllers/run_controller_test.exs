defmodule CodePuppyControlWeb.RunControllerTest do
  @moduledoc """
  Tests for RunController — run management and tool execution API.

  Covers:
  - POST /api/runs/:id/execute — tool execution via runtime-selected executor
  - Missing tool_name => 400
  - Run not found => 404
  - Successful execution delegates through the stored executor backend
  - No direct PythonWorker.Port references in RunController

  Refs: code-puppy-zyh
  """

  use CodePuppyControlWeb.ConnCase, async: false

  alias CodePuppyControl.Run.Manager

  # Env vars we mutate; must be async: false
  @pup_runtime "PUP_RUNTIME"

  # A fake executor for controller-level testing that records calls.
  defmodule FakeExecutorForController do
    @behaviour CodePuppyControl.Run.Executor.Behaviour

    @impl true
    def start_executor(run_id, _opts) do
      send(test_process(), {:fake_executor, :start, run_id})
      CodePuppyControl.Run.Executor.Elixir.start_executor(run_id, opts: [])
    end

    @impl true
    def begin_run(run_id, _opts) do
      send(test_process(), {:fake_executor, :begin, run_id})
      :ok
    end

    @impl true
    def cancel_run(run_id) do
      send(test_process(), {:fake_executor, :cancel, run_id})
      :ok
    end

    @impl true
    def terminate_executor(run_id) do
      send(test_process(), {:fake_executor, :terminate, run_id})
      # Must also terminate the real Elixir executor process started by
      # start_executor/2, otherwise the child leaks under
      # Run.Executor.Supervisor and exhausts max_children (code-puppy-4yx,
      # code-puppy-6sj).
      CodePuppyControl.Run.Executor.Elixir.terminate_executor(run_id)
      :ok
    end

    @impl true
    def execute_tool(run_id, tool_name, arguments, opts) do
      send(test_process(), {:fake_executor, :execute_tool, run_id, tool_name, arguments, opts})

      {:ok, %{fake: true, tool_name: tool_name, arguments: arguments}}
    end

    defp test_process, do: Application.get_env(:code_puppy_control, :executor_test_pid)
  end

  # ---------------------------------------------------------------------------
  # POST /api/runs/:id/execute
  # ---------------------------------------------------------------------------

  describe "POST /api/runs/:id/execute" do
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

        Application.delete_env(:code_puppy_control, :executor_test_pid)
      end)

      :ok
    end

    test "returns 400 when tool_name is missing" do
      # Need a run to exist, but the 400 happens before executor dispatch
      Application.put_env(:code_puppy_control, :run_executor_module, FakeExecutorForController)
      Application.put_env(:code_puppy_control, :executor_test_pid, self())

      assert {:ok, run_id} = Manager.start_run("exec-400-session", "exec-agent")

      conn =
        build_conn()
        |> post_json("/api/runs/#{run_id}/execute", %{"arguments" => %{"x" => 1}})

      body = json_response(conn, 400)
      assert body["error"] =~ "Missing required field: tool_name"

      Manager.delete_run(run_id)
    end

    test "returns 400 when both tool_name and tool are missing" do
      Application.put_env(:code_puppy_control, :run_executor_module, FakeExecutorForController)
      Application.put_env(:code_puppy_control, :executor_test_pid, self())

      assert {:ok, run_id} = Manager.start_run("exec-400b-session", "exec-agent")

      conn =
        build_conn()
        |> post_json("/api/runs/#{run_id}/execute", %{"arguments" => %{}})

      body = json_response(conn, 400)
      assert body["error"] =~ "Missing required field: tool_name"

      Manager.delete_run(run_id)
    end

    test "returns 404 when run does not exist" do
      conn =
        build_conn()
        |> post_json("/api/runs/nonexistent-run-99999/execute", %{
          "tool_name" => "some_tool",
          "arguments" => %{}
        })

      body = json_response(conn, 404)
      assert body["error"] =~ "Run not found"
    end

    test "successful execute delegates through the stored executor backend" do
      Application.put_env(:code_puppy_control, :run_executor_module, FakeExecutorForController)
      Application.put_env(:code_puppy_control, :executor_test_pid, self())

      assert {:ok, run_id} = Manager.start_run("exec-ok-session", "exec-agent")

      conn =
        build_conn()
        |> post_json("/api/runs/#{run_id}/execute", %{
          "tool_name" => "my_tool",
          "arguments" => %{"key" => "value"}
        })

      body = json_response(conn, 200)
      assert body["run_id"] == run_id
      assert body["tool_name"] == "my_tool"
      assert body["executed_at"]

      # The result comes from FakeExecutorForController, not PythonWorker.Port
      assert is_map(body["result"])

      # Verify the fake executor handled the call (not Python)
      assert_received {:fake_executor, :execute_tool, ^run_id, "my_tool", %{"key" => "value"}, []}

      Manager.delete_run(run_id)
    end

    test "accepts tool alias (tool instead of tool_name)" do
      Application.put_env(:code_puppy_control, :run_executor_module, FakeExecutorForController)
      Application.put_env(:code_puppy_control, :executor_test_pid, self())

      assert {:ok, run_id} = Manager.start_run("exec-alias-session", "exec-agent")

      conn =
        build_conn()
        |> post_json("/api/runs/#{run_id}/execute", %{
          "tool" => "aliased_tool",
          "arguments" => %{}
        })

      body = json_response(conn, 200)
      assert body["tool_name"] == "aliased_tool"

      assert_received {:fake_executor, :execute_tool, ^run_id, "aliased_tool", %{}, []}

      Manager.delete_run(run_id)
    end

    test "accepts args alias for arguments" do
      Application.put_env(:code_puppy_control, :run_executor_module, FakeExecutorForController)
      Application.put_env(:code_puppy_control, :executor_test_pid, self())

      assert {:ok, run_id} = Manager.start_run("exec-args-session", "exec-agent")

      conn =
        build_conn()
        |> post_json("/api/runs/#{run_id}/execute", %{
          "tool_name" => "tool_a",
          "args" => %{"y" => 2}
        })

      body = json_response(conn, 200)
      assert body["tool_name"] == "tool_a"

      assert_received {:fake_executor, :execute_tool, ^run_id, "tool_a", %{"y" => 2}, []}

      Manager.delete_run(run_id)
    end

    test "returns 500 when executor returns error" do
      # Use a fake executor that returns an error for tool execution
      defmodule FakeExecutorWithError do
        @behaviour CodePuppyControl.Run.Executor.Behaviour

        @impl true
        def start_executor(run_id, _opts) do
          CodePuppyControl.Run.Executor.Elixir.start_executor(run_id, opts: [])
        end

        @impl true
        def begin_run(_run_id, _opts), do: :ok

        @impl true
        def cancel_run(_run_id), do: :ok

        @impl true
        def terminate_executor(run_id) do
          # Must also terminate the real Elixir executor process started by
          # start_executor/2, otherwise the child leaks under
          # Run.Executor.Supervisor and exhausts max_children (code-puppy-4yx,
          # code-puppy-6sj).
          CodePuppyControl.Run.Executor.Elixir.terminate_executor(run_id)
          :ok
        end

        @impl true
        def execute_tool(_run_id, _tool_name, _arguments, _opts) do
          {:error, :tool_execution_failed}
        end
      end

      Application.put_env(:code_puppy_control, :run_executor_module, FakeExecutorWithError)

      assert {:ok, run_id} = Manager.start_run("exec-error-session", "exec-agent")

      conn =
        build_conn()
        |> post_json("/api/runs/#{run_id}/execute", %{
          "tool_name" => "failing_tool",
          "arguments" => %{}
        })

      body = json_response(conn, 500)
      assert body["run_id"] == run_id
      assert body["tool_name"] == "failing_tool"
      assert body["error"]

      Manager.delete_run(run_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Elixir-native execute path — real Tool.Runner, no Python (code-puppy-zyh)
  # ---------------------------------------------------------------------------

  describe "POST /api/runs/:id/execute via real Elixir executor" do
    # Deterministic test tool registered directly with Tool.Registry.
    # Proves that the default/Elixir execute path dispatches through
    # Tool.Runner without any Python subprocess.

    defmodule DeterministicTestTool do
      @moduledoc """
      Minimal deterministic tool for Elixir-native execute regression.
      Registered/unregistered per-test via Tool.Registry.
      """

      use CodePuppyControl.Tool

      @impl true
      def name, do: :deterministic_test_tool

      @impl true
      def description, do: "Deterministic test tool for controller regression"

      @impl true
      def parameters do
        %{
          "type" => "object",
          "properties" => %{
            "value" => %{"type" => "string", "description" => "Value to echo"}
          },
          "required" => []
        }
      end

      @impl true
      def invoke(args, _context) do
        {:ok, %{echo: Map.get(args, "value", "default"), tool: :deterministic_test_tool}}
      end
    end

    setup do
      saved_runtime = System.get_env(@pup_runtime)
      System.delete_env(@pup_runtime)

      saved_app =
        Application.get_env(:code_puppy_control, :run_executor_module)

      Application.delete_env(:code_puppy_control, :run_executor_module)

      # Ensure no Python worker script env leaks
      saved_pws = System.get_env("PUP_PYTHON_WORKER_SCRIPT")
      saved_lws = System.get_env("PYTHON_WORKER_SCRIPT")
      System.delete_env("PUP_PYTHON_WORKER_SCRIPT")
      System.delete_env("PYTHON_WORKER_SCRIPT")

      # Register the deterministic tool
      :ok = CodePuppyControl.Tool.Registry.register(DeterministicTestTool)

      on_exit(fn ->
        case saved_runtime do
          nil -> System.delete_env(@pup_runtime)
          v -> System.put_env(@pup_runtime, v)
        end

        case saved_app do
          nil -> Application.delete_env(:code_puppy_control, :run_executor_module)
          v -> Application.put_env(:code_puppy_control, :run_executor_module, v)
        end

        if saved_pws, do: System.put_env("PUP_PYTHON_WORKER_SCRIPT", saved_pws)
        if saved_lws, do: System.put_env("PYTHON_WORKER_SCRIPT", saved_lws)

        CodePuppyControl.Tool.Registry.unregister(:deterministic_test_tool)
      end)

      :ok
    end

    test "executes a deterministic tool through Tool.Runner without Python" do
      # Default executor is Elixir — no :run_executor_module override, no PUP_RUNTIME
      assert {:ok, run_id} = Manager.start_run("elixir-native-session", "elixir-agent")

      conn =
        build_conn()
        |> post_json("/api/runs/#{run_id}/execute", %{
          "tool_name" => "deterministic_test_tool",
          "arguments" => %{"value" => "hello"}
        })

      body = json_response(conn, 200)
      assert body["run_id"] == run_id
      assert body["tool_name"] == "deterministic_test_tool"
      assert body["executed_at"]

      # Result came through Tool.Runner → DeterministicTestTool.invoke/2
      # NOT through PythonWorker.Port
      assert is_map(body["result"])
      assert body["result"]["echo"] == "hello"
      assert body["result"]["tool"] == "deterministic_test_tool"

      Manager.delete_run(run_id)
    end

    test "stores executor_module as Elixir in run metadata" do
      assert {:ok, run_id} = Manager.start_run("elixir-meta-session", "elixir-agent")
      assert {:ok, state} = Manager.get_run(run_id)
      assert state.metadata.executor_module == CodePuppyControl.Run.Executor.Elixir

      Manager.delete_run(run_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Grep-based regression: RunController must not reference PythonWorker.Port
  # ---------------------------------------------------------------------------

  describe "RunController no direct PythonWorker.Port references" do
    test "controller source does not alias or call PythonWorker.Port" do
      source =
        File.read!("lib/code_puppy_control_web/controllers/run_controller.ex")

      # Must NOT contain any direct PythonWorker.Port references
      refute source =~ "PythonWorker.Port",
             "RunController must not reference PythonWorker.Port directly (code-puppy-zyh)"

      refute source =~ "alias CodePuppyControl.PythonWorker",
             "RunController must not alias PythonWorker modules (code-puppy-zyh)"
    end
  end
end
