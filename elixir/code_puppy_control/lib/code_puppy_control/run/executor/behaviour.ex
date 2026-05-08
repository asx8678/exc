defmodule CodePuppyControl.Run.Executor.Behaviour do
  @moduledoc """
  Behaviour for run executors.

  Each executor backend implements the run lifecycle operations:
  starting, cancelling, and terminating a run's execution context.

  The executor abstraction allows `Run.Manager` to route run lifecycle
  through a consistent interface. The native Elixir executor is the
  default and only runtime.

  Refs: code-puppy-96g, code-puppy-3o7.6
  """

  @type run_id :: String.t()
  @type start_opts :: keyword()
  @type executor_pid :: pid()

  @doc """
  Start an executor process for the given run.

  Returns `{:ok, executor_pid}` on success or `{:error, reason}` on failure.
  The executor_pid is stored in `Run.State` (as `worker_pid` for compatibility).
  """
  @callback start_executor(run_id(), start_opts()) ::
              {:ok, executor_pid()} | {:error, term()}

  @doc """
  Begin execution of a previously-started run.

  Called after `Run.State` is initialised.  The executor should
  transition the run context to an active/ready state.
  """
  @callback begin_run(run_id(), start_opts()) :: :ok | {:error, term()}

  @doc """
  Cancel a running run.

  Sends a cancel signal to the executor and returns immediately.
  The executor should transition the run to a cancelled state.
  """
  @callback cancel_run(run_id()) :: :ok | {:error, term()}

  @doc """
  Terminate the executor process for a run.

  Called during cleanup/deletion.  Should gracefully shut down
  the executor process and release resources.
  """
  @callback terminate_executor(run_id()) :: :ok | {:error, :not_found}

  @doc """
  Execute a tool within the context of a run.

  The executor backend dispatches the tool invocation to the
  appropriate runtime — either the Python worker bridge or the
  native Elixir `Tool.Runner`.  Returns `{:ok, result}` on success
  or `{:error, reason}` on failure.

  ## Options

    * `:timeout` — Execution timeout in milliseconds (default: 30 000)

  Refs: code-puppy-zyh
  """
  @callback execute_tool(run_id(), String.t(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
end
