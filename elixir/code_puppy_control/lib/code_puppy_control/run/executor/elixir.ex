defmodule CodePuppyControl.Run.Executor.Elixir do
  @moduledoc """
  Native Elixir executor backend for run lifecycle.

  Starts a supervised lightweight GenServer for the run context,
  with no dependency on a Python worker subprocess.  Selected when
  `PUP_RUNTIME` is unset, `auto`, or `elixir`.

  The Elixir executor provides the same lifecycle interface as the
  Python executor but operates entirely within the BEAM.  It does
  **not** trigger real LLM calls just by starting a run; the run
  context is created and marked as ready/running, and actual agent
  execution is handled separately by the agent loop / REPL layer.

  ## Registry

  Executor processes register under
  `{:run_executor, run_id}` in `CodePuppyControl.Run.Registry`
  for lookup and monitoring.

  Refs: code-puppy-96g
  """

  @behaviour CodePuppyControl.Run.Executor.Behaviour

  use GenServer

  require Logger

  alias CodePuppyControl.Run.Registry, as: RunRegistry

  defstruct [:run_id, :status, :config, :started_at]

  @type t :: %__MODULE__{
          run_id: String.t(),
          status: :starting | :running | :cancelled | :completed | :failed,
          config: map(),
          started_at: DateTime.t()
        }

  # ===========================================================================
  # Executor Behaviour callbacks
  # ===========================================================================

  @impl CodePuppyControl.Run.Executor.Behaviour
  @spec start_executor(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_executor(run_id, opts) do
    child_spec = %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [Keyword.merge(opts, run_id: run_id)]},
      restart: :temporary,
      shutdown: 5000
    }

    case DynamicSupervisor.start_child(CodePuppyControl.Run.Supervisor, child_spec) do
      {:ok, pid} ->
        Logger.info("Started Elixir executor for run #{run_id} (pid: #{inspect(pid)})")
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Elixir executor for run #{run_id} already running")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start Elixir executor for run #{run_id}: #{inspect(reason)}")
        error
    end
  end

  @impl CodePuppyControl.Run.Executor.Behaviour
  @spec begin_run(String.t(), keyword()) :: :ok | {:error, term()}
  def begin_run(run_id, opts) do
    # The executor is already running; transition it to :running status
    # and publish a run.started notification on PubSub.
    GenServer.cast(via_tuple(run_id), {:begin_run, opts})

    :ok
  rescue
    _ -> {:error, :executor_not_found}
  end

  @impl CodePuppyControl.Run.Executor.Behaviour
  @spec cancel_run(String.t()) :: :ok | {:error, term()}
  def cancel_run(run_id) do
    GenServer.cast(via_tuple(run_id), :cancel)
    :ok
  rescue
    _ -> {:error, :executor_not_found}
  end

  @impl CodePuppyControl.Run.Executor.Behaviour
  @spec terminate_executor(String.t()) :: :ok | {:error, :not_found}
  def terminate_executor(run_id) do
    case RunRegistry.lookup({:run_executor, run_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(CodePuppyControl.Run.Supervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @impl CodePuppyControl.Run.Executor.Behaviour
  @spec execute_tool(String.t(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_tool(run_id, tool_name, arguments, opts) do
    timeout = Keyword.get(opts, :timeout)

    context = %{run_id: run_id}
    context = if timeout, do: Map.put(context, :timeout, timeout), else: context

    CodePuppyControl.Tool.Runner.invoke(tool_name, arguments, context)
  end

  # ===========================================================================
  # GenServer API
  # ===========================================================================

  @doc false
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(run_id))
  end

  @doc false
  def via_tuple(run_id) do
    {:via, Registry, {RunRegistry, {:run_executor, run_id}}}
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl GenServer
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    config = Keyword.get(opts, :config, %{})

    state = %__MODULE__{
      run_id: run_id,
      status: :starting,
      config: config,
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:begin_run, _opts}, state) do
    # Transition to running and publish run.started notification
    # so Run.State picks it up via PubSub (consistent with Python worker)
    new_state = %{state | status: :running}

    Phoenix.PubSub.broadcast(
      CodePuppyControl.PubSub,
      "run:#{state.run_id}",
      {:executor_notification, state.run_id, %{"method" => "run.started", "params" => %{}}}
    )

    Logger.info("Elixir executor: run #{state.run_id} started")
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast(:cancel, state) do
    new_state = %{state | status: :cancelled}

    # Do NOT broadcast a run.completed notification here;
    # Run.State.cancel/2 handles the status update directly.
    # Broadcasting would race with the :cancelled status set
    # by State.cancel and could overwrite it with :completed.

    Logger.info("Elixir executor: run #{state.run_id} cancelled")
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("Elixir executor for run #{state.run_id} received: #{inspect(msg)}")
    {:noreply, state}
  end
end
