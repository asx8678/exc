defmodule CodePuppyControl.PythonWorker.Supervisor do
  @moduledoc """
  DynamicSupervisor for Python worker processes.

  > **Bridge-mode only.** This supervisor is only meaningful under explicit
  > `PUP_RUNTIME=python` / `--bridge-mode` / legacy PyPI compatibility
  > workflows. The default native Burrito runtime (`PUP_RUNTIME=auto`
  > or `:elixir`) never starts PythonWorker children; this supervisor
  > remains idle at zero workers.

  Each run gets its own Python worker process via `start_worker/2`.
  Workers are started with `:temporary` restart strategy to avoid
  restart loops when Python scripts fail.
  """

  use DynamicSupervisor

  require Logger

  alias CodePuppyControl.PythonWorker.Port

  @doc """
  Starts the DynamicSupervisor.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a Python worker for a specific run.

  ## Options

    * `:run_id` - Required. The run identifier.
    * `:script_path` - Optional. Override the default Python script path.
    * `:parent` - Optional. PID to monitor.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec start_worker(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_worker(run_id, opts \\ []) do
    opts = Keyword.put(opts, :run_id, run_id)

    child_spec = %{
      id: {Port, run_id},
      start: {Port, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started Python worker for run #{run_id} (pid: #{inspect(pid)})")
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("Python worker for run #{run_id} already running (pid: #{inspect(pid)})")
        {:ok, pid}

      {:error, :max_children} ->
        Logger.warning(
          "Python worker supervisor at capacity (limit: " <>
            "#{CodePuppyControl.Runtime.Limits.max_python_workers()}). " <>
            "Refusing to start worker for run #{run_id}."
        )

        :telemetry.execute(
          [:code_puppy, :supervisor, :full],
          %{count: 1},
          %{supervisor: :python_worker, run_id: run_id}
        )

        {:error, :max_children}

      {:error, reason} = error ->
        Logger.error("Failed to start Python worker for run #{run_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Terminates a Python worker for a specific run.

  Sends graceful shutdown signal and terminates the process.
  """
  @spec terminate_worker(String.t()) :: :ok | {:error, :not_found}
  def terminate_worker(run_id) do
    case Registry.lookup(CodePuppyControl.Run.Registry, {:python_worker, run_id}) do
      [] ->
        {:error, :not_found}

      [{pid, _value} | _] ->
        Port.shutdown(run_id)
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc """
  Lists all active Python workers.
  """
  @spec list_workers() :: list({String.t(), pid()})
  def list_workers do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, [Port]} when is_pid(pid) ->
        # Get the run_id from the Port's via tuple lookup
        case Port.pid_to_run_id(pid) do
          {:ok, run_id} -> [{run_id, pid}]
          :error -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Returns the number of active Python workers.
  """
  @spec worker_count() :: non_neg_integer()
  def worker_count do
    case Process.whereis(__MODULE__) do
      nil -> 0
      _ -> DynamicSupervisor.count_children(__MODULE__).workers
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60,
      max_children: CodePuppyControl.Runtime.Limits.max_python_workers()
    )
  end
end
