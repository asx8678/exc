defmodule CodePuppyControl.Run.Supervisor do
  @moduledoc """
  DynamicSupervisor for run-related processes.

  This includes Run.State processes and other per-run workers.
  """

  use DynamicSupervisor

  require Logger

  alias CodePuppyControl.Run.State

  @doc """
  Starts the DynamicSupervisor.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a run state process for the given run_id.

  Options:
    * `:session_id` - The session this run belongs to
    * `:agent_name` - The agent being run
    * `:worker_pid` - The executor/worker PID to monitor (Elixir or Python)
    * `:metadata` - Additional run metadata

  Returns `{:ok, pid}` on success. If a process already exists
  for this run_id, returns `{:ok, existing_pid}`.
  """
  @spec start_run(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_run(run_id, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    child_spec = %{
      id: {State, run_id},
      start: {State, :start_link, [[run_id: run_id, metadata: metadata] |> Keyword.merge(opts)]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started Run.State for #{run_id}")
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Run.State for #{run_id} already running")
        {:ok, pid}

      {:error, :max_children} ->
        limit = CodePuppyControl.Runtime.Limits.max_runs()

        Logger.warning(
          "Run supervisor at capacity (limit: #{limit}). " <>
            "Refusing to start run #{run_id}."
        )

        :telemetry.execute(
          [:code_puppy, :supervisor, :full],
          %{count: 1},
          %{supervisor: :run, run_id: run_id}
        )

        {:error, :max_children}

      {:error, reason} = error ->
        Logger.error("Failed to start Run.State for #{run_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Terminates a run state process.
  """
  @spec terminate_run(String.t()) :: :ok | {:error, :not_found}
  def terminate_run(run_id) do
    case Registry.lookup(CodePuppyControl.Run.Registry, {:run_state, run_id}) do
      [] ->
        {:error, :not_found}

      [{pid, _value} | _] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc """
  Lists all active run state processes.
  """
  @spec list_runs() :: list({String.t(), pid()})
  def list_runs do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, [State]} when is_pid(pid) ->
        # Get the run_id from the State's via tuple lookup
        case State.get_state_from_pid(pid) do
          {:ok, state} -> [{state.run_id, pid}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Returns the count of active runs.
  """
  @spec run_count() :: non_neg_integer()
  def run_count do
    case Process.whereis(__MODULE__) do
      nil -> 0
      _ -> DynamicSupervisor.count_children(__MODULE__).workers
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 60,
      max_children: CodePuppyControl.Runtime.Limits.max_runs()
    )
  end
end
