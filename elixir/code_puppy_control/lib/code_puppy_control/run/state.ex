defmodule CodePuppyControl.Run.State do
  @moduledoc """
  GenServer for managing the state of a single run.

  Tracks:
  - Run lifecycle (:starting, :running, :completed, :failed, :cancelled)
  - Associated executor/worker PID (monitored for crashes)
  - Session and agent context
  - Tool executions and their results
  - Correlation between requests and responses
  - Run events from PubSub

  This process is started on demand and exits when the run completes
  or after a period of inactivity.

  Refs: code-puppy-96g (executor boundary refactor)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Run.Executor, as: RunExecutor

  defstruct [
    :run_id,
    :session_id,
    :agent_name,
    :worker_pid,
    :worker_ref,
    :status,
    :started_at,
    :completed_at,
    :error,
    :request_history,
    :events,
    :last_activity,
    :metadata
  ]

  @type status ::
          :starting | :running | :completed | :failed | :cancelled | :paused | :pending | :unknown

  # Valid statuses for safe atom conversion from external input
  @valid_statuses ~w(starting running completed failed cancelled paused pending)a

  @type t :: %__MODULE__{
          run_id: String.t(),
          session_id: String.t() | nil,
          agent_name: String.t() | nil,
          worker_pid: pid() | nil,
          worker_ref: reference() | nil,
          status: status(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          error: term() | nil,
          request_history: list(map()),
          events: list(map()),
          last_activity: integer(),
          metadata: map()
        }

  @inactivity_timeout :timer.minutes(30)

  @doc """
  Safely converts a status string to an atom.
  Returns the atom if valid, or :unknown for invalid statuses.
  This prevents atom table exhaustion from external input.
  """
  @spec safe_status_atom(String.t() | atom()) :: status()
  def safe_status_atom(status) when is_atom(status) do
    if status in @valid_statuses, do: status, else: :unknown
  end

  def safe_status_atom(status) when is_binary(status) do
    case status do
      "starting" -> :starting
      "running" -> :running
      "completed" -> :completed
      "failed" -> :failed
      "cancelled" -> :cancelled
      "paused" -> :paused
      "pending" -> :pending
      _ -> :unknown
    end
  end

  def safe_status_atom(_), do: :unknown

  # Client API

  @doc """
  Starts a Run.State process for the given run_id.
  """
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(run_id))
  end

  @doc """
  Returns a via tuple for Registry lookup.
  """
  def via_tuple(run_id) do
    {:via, Registry, {CodePuppyControl.Run.Registry, {:run_state, run_id}}}
  end

  @doc """
  Creates a new run state process on demand.
  """
  @spec start_run(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_run(run_id, opts \\ %{}) do
    child_spec = %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [[run_id: run_id] |> Keyword.merge(Map.to_list(opts))]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(CodePuppyControl.Run.Supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets the current state of a run.
  """
  @spec get_state(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_state(run_id) do
    case Registry.lookup(CodePuppyControl.Run.Registry, {:run_state, run_id}) do
      [] ->
        {:error, :not_found}

      [{pid, _} | _] ->
        try do
          {:ok, GenServer.call(pid, :get_state)}
        catch
          :exit, _ -> {:error, :not_found}
        end
    end
  end

  @doc """
  Records a request sent to the Python worker.
  """
  @spec record_request(String.t(), map()) :: :ok
  def record_request(run_id, request) do
    GenServer.cast(via_tuple(run_id), {:record_request, request})
  end

  @doc """
  Records a response received from the Python worker.
  """
  @spec record_response(String.t(), map()) :: :ok
  def record_response(run_id, response) do
    GenServer.cast(via_tuple(run_id), {:record_response, response})
  end

  @doc """
  Updates the run status.
  """
  @spec set_status(String.t(), status(), term() | nil) :: :ok
  def set_status(run_id, status, error \\ nil) do
    GenServer.cast(via_tuple(run_id), {:set_status, status, error})
  end

  @doc """
  Updates the run with event data.
  """
  @spec add_event(String.t(), map()) :: :ok
  def add_event(run_id, event) do
    GenServer.cast(via_tuple(run_id), {:add_event, event})
  end

  @doc """
  Completes a run with final status and data.
  """
  @spec complete(String.t(), map()) :: :ok
  def complete(run_id, data \\ %{}) do
    GenServer.cast(via_tuple(run_id), {:complete, data})
  end

  @doc """
  Cancels a run.
  """
  @spec cancel(String.t(), term() | nil) :: :ok
  def cancel(run_id, reason \\ nil) do
    GenServer.cast(via_tuple(run_id), {:cancel, reason})
  end

  @doc """
  Gets the request history for a run.
  """
  @spec get_history(String.t()) :: list(map())
  def get_history(run_id) do
    case Registry.lookup(CodePuppyControl.Run.Registry, {:run_state, run_id}) do
      [] -> []
      [{pid, _} | _] -> GenServer.call(pid, :get_history)
    end
  end

  @doc """
  Gets the state from a State process PID.
  """
  @spec get_state_from_pid(pid()) :: {:ok, t()} | {:error, :not_found}
  def get_state_from_pid(pid) do
    try do
      {:ok, GenServer.call(pid, :get_state)}
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    metadata = Keyword.get(opts, :metadata, %{})
    session_id = Keyword.get(opts, :session_id)
    agent_name = Keyword.get(opts, :agent_name)
    worker_pid = Keyword.get(opts, :worker_pid)

    # Subscribe to PubSub for Python notifications and events
    Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "run:#{run_id}")

    # Monitor the worker if provided
    worker_ref = if worker_pid, do: Process.monitor(worker_pid), else: nil

    state = %__MODULE__{
      run_id: run_id,
      session_id: session_id,
      agent_name: agent_name,
      worker_pid: worker_pid,
      worker_ref: worker_ref,
      status: :starting,
      started_at: DateTime.utc_now(),
      completed_at: nil,
      error: nil,
      request_history: [],
      events: [],
      last_activity: System.monotonic_time(:millisecond),
      metadata: metadata
    }

    # Schedule inactivity check
    schedule_inactivity_check()

    Logger.info("Started Run.State for #{run_id} (session: #{session_id}, agent: #{agent_name})")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, touch(state)}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.request_history, touch(state)}
  end

  @impl true
  def handle_cast({:record_request, request}, state) do
    entry = %{
      type: :request,
      timestamp: DateTime.utc_now(),
      data: request
    }

    new_state = %{state | request_history: [entry | state.request_history]}
    {:noreply, touch(new_state)}
  end

  @impl true
  def handle_cast({:record_response, response}, state) do
    entry = %{
      type: :response,
      timestamp: DateTime.utc_now(),
      data: response
    }

    new_state = %{state | request_history: [entry | state.request_history]}

    # Update status based on response
    new_state =
      case response do
        %{"error" => _} -> %{new_state | status: :failed}
        _ -> new_state
      end

    {:noreply, touch(new_state)}
  end

  @impl true
  def handle_cast({:set_status, status, error}, state) do
    new_state = %{
      state
      | status: status,
        error: error,
        completed_at:
          if(status in [:completed, :failed, :cancelled],
            do: DateTime.utc_now(),
            else: state.completed_at
          )
    }

    {:noreply, touch(new_state)}
  end

  @impl true
  def handle_cast({:add_event, event}, state) do
    new_state = %{state | events: [event | state.events]}
    {:noreply, touch(new_state)}
  end

  @impl true
  def handle_cast({:complete, data}, state) do
    new_state = %{
      state
      | status: :completed,
        completed_at: DateTime.utc_now(),
        error: data["error"],
        metadata: Map.merge(state.metadata, data)
    }

    Logger.info("Run #{state.run_id} completed")
    {:noreply, touch(new_state)}
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    new_state = %{
      state
      | status: :cancelled,
        completed_at: DateTime.utc_now(),
        error: reason || "cancelled"
    }

    Logger.info("Run #{state.run_id} cancelled: #{inspect(reason)}")
    {:noreply, touch(new_state)}
  end

  @impl true
  def handle_info({:python_notification, run_id, message}, state) do
    # Handle notifications from Python worker
    Logger.debug("Received notification for run #{run_id}: #{inspect(message)}")

    # Record in history
    entry = %{
      type: :notification,
      timestamp: DateTime.utc_now(),
      data: message
    }

    new_state = %{state | request_history: [entry | state.request_history]}

    # Handle specific notification types
    new_state =
      case message do
        %{"method" => "run.started", "params" => _} ->
          %{new_state | status: :running}

        %{"method" => "tool_executed", "params" => params} ->
          handle_tool_executed(new_state, params)

        %{"method" => "run.completed", "params" => params} ->
          %{
            new_state
            | status: :completed,
              error: params["error"],
              completed_at: DateTime.utc_now(),
              metadata: Map.merge(new_state.metadata, params)
          }

        %{"method" => "run.failed", "params" => params} ->
          %{
            new_state
            | status: :failed,
              error: params["error"],
              completed_at: DateTime.utc_now()
          }

        _ ->
          new_state
      end

    {:noreply, touch(new_state)}
  end

  @impl true
  def handle_info({:run_event, event}, state) do
    # Handle run events from PubSub
    Logger.debug("Received run event for #{state.run_id}: #{inspect(event)}")

    new_events = [event | state.events]

    # Update status based on event type
    new_state =
      case event do
        %{"type" => "status", "status" => status} ->
          %{state | status: safe_status_atom(status), events: new_events}

        %{"type" => "completed"} ->
          %{
            state
            | status: :completed,
              completed_at: DateTime.utc_now(),
              events: new_events
          }

        %{"type" => "failed", "error" => error} ->
          %{
            state
            | status: :failed,
              error: error,
              completed_at: DateTime.utc_now(),
              events: new_events
          }

        _ ->
          %{state | events: new_events}
      end

    {:noreply, touch(new_state)}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{worker_pid: pid, worker_ref: ref} = state
      ) do
    # Executor/worker died - mark run as failed if not already in a terminal state
    if state.status not in [:completed, :failed, :cancelled] do
      Logger.error("Executor/worker for run #{state.run_id} died: #{inspect(reason)}")

      new_state = %{
        state
        | status: :failed,
          error: "Executor/worker process terminated: #{inspect(reason)}",
          completed_at: DateTime.utc_now()
      }

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Other process down, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_inactivity, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_activity

    cond do
      state.status in [:completed, :failed, :cancelled] and elapsed > @inactivity_timeout ->
        Logger.info("Run #{state.run_id} inactive after completion, shutting down")
        {:stop, :normal, state}

      elapsed > @inactivity_timeout * 2 ->
        # Force shutdown even if still running (something is wrong).
        # Use the executor module stored in metadata at start time
        # so a mid-flight PUP_RUNTIME change does not redirect
        # termination to the wrong backend.
        executor_mod = Map.get(state.metadata, :executor_module, RunExecutor)
        executor_mod.terminate_executor(state.run_id)
        {:stop, :normal, state}

      true ->
        schedule_inactivity_check()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Run.State received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp touch(state) do
    %{state | last_activity: System.monotonic_time(:millisecond)}
  end

  defp schedule_inactivity_check do
    Process.send_after(self(), :check_inactivity, @inactivity_timeout)
  end

  defp handle_tool_executed(state, params) do
    # Update metadata with tool execution info
    tool_name = params["tool_name"]
    _tool_result = params["result"]

    tools = Map.get(state.metadata, :tools_executed, [])
    new_metadata = Map.put(state.metadata, :tools_executed, [tool_name | tools])

    %{state | metadata: new_metadata}
  end
end
