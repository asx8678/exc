defmodule CodePuppyControl.Agent.State.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-{session,agent} Agent.State processes.

  Each Agent.State GenServer is keyed by `{session_id, agent_name}` and
  manages message history with dedup semantics.
  """

  use DynamicSupervisor

  require Logger

  alias CodePuppyControl.Agent.State

  @doc """
  Starts the DynamicSupervisor.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts an Agent.State process for the given session_id and agent_name.

  Options are forwarded to `Agent.State.start_link/1`.
  Returns `{:ok, pid}` on success. If a process already exists for
  this key, returns `{:ok, existing_pid}` (idempotent).
  """
  @spec start_agent_state(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent_state(session_id, agent_name, opts \\ []) do
    opts = Keyword.merge(opts, session_id: session_id, agent_name: agent_name)

    child_spec = %{
      id: {State, session_id, agent_name},
      start: {State, :start_link, [opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, :max_children} ->
        limit = CodePuppyControl.Runtime.Limits.max_agent_states()

        Logger.warning(
          "Agent.State supervisor at capacity (limit: #{limit}). " <>
            "Refusing to start #{session_id}/#{agent_name}."
        )

        :telemetry.execute(
          [:code_puppy, :supervisor, :full],
          %{count: 1},
          %{supervisor: :agent_state, session_id: session_id, agent_name: agent_name}
        )

        {:error, :max_children}

      {:error, reason} = error ->
        Logger.error(
          "Failed to start Agent.State for #{session_id}/#{agent_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Terminates an Agent.State process for the given session_id and agent_name.
  """
  @spec terminate_agent_state(String.t(), String.t()) :: :ok | {:error, :not_found}
  def terminate_agent_state(session_id, agent_name) do
    key = {session_id, agent_name}

    case Registry.lookup(CodePuppyControl.Agent.State.Registry, key) do
      [] ->
        {:error, :not_found}

      [{pid, _value} | _] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc """
  Lists all active Agent.State processes with their keys and PIDs.
  """
  @spec list_agent_states() :: list({{String.t(), String.t()}, pid()})
  def list_agent_states do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, [State]} when is_pid(pid) ->
        case Registry.keys(CodePuppyControl.Agent.State.Registry, pid) do
          [key] -> [{key, pid}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Returns the count of active Agent.State processes.
  """
  @spec agent_state_count() :: non_neg_integer()
  def agent_state_count do
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
      max_children: CodePuppyControl.Runtime.Limits.max_agent_states()
    )
  end
end
