defmodule CodePuppyControl.Run.Executor.Behaviour do
  @moduledoc """
  Behaviour for run executors.

  Each executor backend implements the run lifecycle operations:
  starting, cancelling, and terminating a run's execution context.

  The executor abstraction allows `Run.Manager` to route run lifecycle
  through either a Python worker (bridge mode) or a native Elixir
  executor, depending on `PUP_RUNTIME`.

  Refs: code-puppy-96g
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
end
