defmodule CodePuppyControl.Run.Executor do
  @moduledoc """
  Executor facade for run lifecycle operations.

  All runs use the native Elixir executor (`Run.Executor.Elixir`).
  The executor abstraction is preserved so that `Run.Manager` can
  route lifecycle operations through a consistent interface and so
  that the executor module stored in run metadata can be used for
  mid-run consistency.

  ## App-env override for tests

  `Application.put_env(:code_puppy_control, :run_executor_module, SomeModule)`
  overrides the default executor.  This is intended **only** for test
  injection; production always uses `Run.Executor.Elixir`.

  Refs: code-puppy-96g, code-puppy-3o7.6
  """

  @app_env_key :run_executor_module
  @default_executor CodePuppyControl.Run.Executor.Elixir

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Returns the executor module for the current configuration.

  Resolution order:
    1. `:run_executor_module` app env (test override)
    2. `Run.Executor.Elixir` (default, native-only)
  """
  @spec executor_module() :: module()
  def executor_module do
    case Application.get_env(:code_puppy_control, @app_env_key) do
      nil -> @default_executor
      mod when is_atom(mod) -> mod
    end
  end

  # ── Runtime-selected (facade) API ───────────────────────────────────
  #
  # These functions select the executor module at call time.
  # Prefer the explicit-module variants below for all lifecycle
  # operations on an *existing* run so that the executor module
  # used at start time is preserved.

  @doc """
  Start an executor process for the given run.

  Delegates to `executor_module().start_executor/2`.
  """
  @spec start_executor(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_executor(run_id, opts) do
    mod = executor_module()
    mod.start_executor(run_id, opts)
  end

  @doc """
  Begin execution of a previously-started run.

  Delegates to `executor_module().begin_run/2`.
  """
  @spec begin_run(String.t(), keyword()) :: :ok | {:error, term()}
  def begin_run(run_id, opts) do
    mod = executor_module()
    mod.begin_run(run_id, opts)
  end

  @doc """
  Cancel a running run.

  Delegates to `executor_module().cancel_run/1`.
  """
  @spec cancel_run(String.t()) :: :ok | {:error, term()}
  def cancel_run(run_id) do
    mod = executor_module()
    mod.cancel_run(run_id)
  end

  @doc """
  Terminate the executor process for a run.

  Delegates to `executor_module().terminate_executor/1`.
  """
  @spec terminate_executor(String.t()) :: :ok | {:error, :not_found}
  def terminate_executor(run_id) do
    mod = executor_module()
    mod.terminate_executor(run_id)
  end

  @doc """
  Execute a tool within a run.

  Delegates to `executor_module().execute_tool/4`.

  Refs: code-puppy-zyh
  """
  @spec execute_tool(String.t(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_tool(run_id, tool_name, arguments, opts \\ []) do
    mod = executor_module()
    mod.execute_tool(run_id, tool_name, arguments, opts)
  end

  # ── Explicit-module variants ──────────────────────────────────────
  #
  # These accept an explicit executor module (typically derived from
  # the run's stored metadata) so that lifecycle operations always use
  # the same executor backend that was selected at start time.

  @doc """
  Start an executor process for the given run using an explicit module.
  """
  @spec start_executor(String.t(), keyword(), module()) ::
          {:ok, pid()} | {:error, term()}
  def start_executor(run_id, opts, mod) do
    mod.start_executor(run_id, opts)
  end

  @doc """
  Begin execution of a previously-started run using an explicit module.
  """
  @spec begin_run(String.t(), keyword(), module()) :: :ok | {:error, term()}
  def begin_run(run_id, opts, mod) do
    mod.begin_run(run_id, opts)
  end

  @doc """
  Cancel a running run using an explicit module.
  """
  @spec cancel_run(String.t(), module()) :: :ok | {:error, term()}
  def cancel_run(run_id, mod) do
    mod.cancel_run(run_id)
  end

  @doc """
  Terminate the executor process for a run using an explicit module.
  """
  @spec terminate_executor(String.t(), module()) :: :ok | {:error, :not_found}
  def terminate_executor(run_id, mod) do
    mod.terminate_executor(run_id)
  end

  @doc """
  Execute a tool within a run using an explicit module.

  Uses the executor module stored in the run's metadata at start time
  so that mid-run runtime changes do not redirect tool execution.

  Refs: code-puppy-zyh
  """
  @spec execute_tool(String.t(), String.t(), map(), keyword(), module()) ::
          {:ok, term()} | {:error, term()}
  def execute_tool(run_id, tool_name, arguments, opts, mod) do
    mod.execute_tool(run_id, tool_name, arguments, opts)
  end
end
