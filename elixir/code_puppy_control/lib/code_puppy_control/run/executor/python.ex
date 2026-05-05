defmodule CodePuppyControl.Run.Executor.Python do
  @moduledoc """
  Python-bridge executor backend for run lifecycle.

  Delegates to `PythonWorker.Supervisor` and `PythonWorker.Port`
  for the actual Python subprocess management.  This executor
  is selected when `PUP_RUNTIME=python` (explicit bridge mode).

  Preserves the graceful error tuples from code-puppy-4ry:
  if the Python worker script is missing or `python3` is unavailable,
  `start_executor/2` returns `{:error, reason}` rather than crashing.

  Refs: code-puppy-96g
  """

  @behaviour CodePuppyControl.Run.Executor.Behaviour

  alias CodePuppyControl.PythonWorker

  @impl true
  @spec start_executor(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_executor(run_id, opts) do
    script_opts =
      case Keyword.get(opts, :script_path) do
        nil -> [run_id: run_id]
        path -> [run_id: run_id, script_path: path]
      end

    PythonWorker.Supervisor.start_worker(run_id, script_opts)
  end

  @impl true
  @spec begin_run(String.t(), keyword()) :: :ok | {:error, term()}
  def begin_run(run_id, opts) do
    config = Keyword.get(opts, :config, %{})
    session_id = Keyword.get(opts, :session_id)
    agent_name = Keyword.get(opts, :agent_name)

    PythonWorker.Port.start_run(run_id, %{
      run_id: run_id,
      session_id: session_id,
      agent_name: agent_name,
      config: config
    })

    :ok
  end

  @impl true
  @spec cancel_run(String.t()) :: :ok | {:error, term()}
  def cancel_run(run_id) do
    PythonWorker.Port.cancel_run(run_id)
  end

  @impl true
  @spec terminate_executor(String.t()) :: :ok | {:error, :not_found}
  def terminate_executor(run_id) do
    PythonWorker.Supervisor.terminate_worker(run_id)
  end

  @impl true
  @spec execute_tool(String.t(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_tool(run_id, tool_name, arguments, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    PythonWorker.Port.call(
      run_id,
      "tools/call",
      %{
        name: tool_name,
        arguments: arguments
      },
      timeout
    )
  end
end
