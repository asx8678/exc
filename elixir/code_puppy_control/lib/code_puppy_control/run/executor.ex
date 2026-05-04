defmodule CodePuppyControl.Run.Executor do
  @moduledoc """
  Executor facade for run lifecycle operations.

  Routes run lifecycle calls to the appropriate backend based on
  `PUP_RUNTIME`:

  | PUP_RUNTIME   | Backend                      |
  |---------------|------------------------------|
  | `python`      | `Run.Executor.Python`        |
  | `elixir`      | `Run.Executor.Elixir`        |
  | `auto`/unset  | `Run.Executor.Elixir`        |

  The default is Elixir (no Python required), matching the Phase J.1
  Elixir-native default in `RuntimeSelector`.

  ## App-env override for tests

  `Application.put_env(:code_puppy_control, :run_executor_module, SomeModule)`
  overrides runtime selection.  This is intended **only** for test
  injection; production should rely on `PUP_RUNTIME`.

  Refs: code-puppy-96g
  """

  alias CodePuppyControl.RuntimeSelector

  @app_env_key :run_executor_module

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Returns the executor module selected for the current runtime mode.

  Resolution order:
    1. `:run_executor_module` app env (test override)
    2. `RuntimeSelector.select("run_executor")` → `:elixir` or `:python`
  """
  @spec executor_module() :: module()
  def executor_module do
    case Application.get_env(:code_puppy_control, @app_env_key) do
      nil ->
        case RuntimeSelector.select("run_executor") do
          :python -> CodePuppyControl.Run.Executor.Python
          :elixir -> CodePuppyControl.Run.Executor.Elixir
        end

      mod when is_atom(mod) ->
        mod
    end
  end

  # ── Runtime-selected (facade) API ───────────────────────────────────
  #
  # These functions select the executor module from PUP_RUNTIME / app env
  # at call time.  Prefer the explicit-module variants below for all
  # lifecycle operations on an *existing* run so that the executor
  # module used at start time is preserved even if the runtime mode
  # changes mid-flight.

  @doc """
  Start an executor process for the given run (runtime-selected module).

  Delegates to `executor_module().start_executor/2`.
  """
  @spec start_executor(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_executor(run_id, opts) do
    mod = executor_module()
    mod.start_executor(run_id, opts)
  end

  @doc """
  Begin execution of a previously-started run (runtime-selected module).

  Delegates to `executor_module().begin_run/2`.
  """
  @spec begin_run(String.t(), keyword()) :: :ok | {:error, term()}
  def begin_run(run_id, opts) do
    mod = executor_module()
    mod.begin_run(run_id, opts)
  end

  @doc """
  Cancel a running run (runtime-selected module).

  Delegates to `executor_module().cancel_run/1`.
  """
  @spec cancel_run(String.t()) :: :ok | {:error, term()}
  def cancel_run(run_id) do
    mod = executor_module()
    mod.cancel_run(run_id)
  end

  @doc """
  Terminate the executor process for a run (runtime-selected module).

  Delegates to `executor_module().terminate_executor/1`.
  """
  @spec terminate_executor(String.t()) :: :ok | {:error, :not_found}
  def terminate_executor(run_id) do
    mod = executor_module()
    mod.terminate_executor(run_id)
  end

  # ── Explicit-module variants ──────────────────────────────────────
  #
  # These accept an explicit executor module (typically derived from
  # the run's stored metadata) so that lifecycle operations always use
  # the same executor backend that was selected at start time, even if
  # PUP_RUNTIME or the app-env override changes mid-flight.

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
end
