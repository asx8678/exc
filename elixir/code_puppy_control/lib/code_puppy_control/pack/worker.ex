defmodule CodePuppyControl.Pack.Worker do
  @moduledoc """
  GenServer running on worker nodes that handles dispatch requests from the
  Pack Leader.

  Each worker node runs a single `PackWorker` GenServer that registers itself
  globally as `{:pack_worker, node()}` via Erlang's `:global` module, making
  it discoverable by the Pack Leader.

  ## Capabilities

  Workers advertise their capabilities to the leader on connect. The
  capabilities map describes which sub-agents, models, and features the
  worker supports. See `default_capabilities/0` for the shape.

  ## Message Protocol

  | Direction | Pattern | Purpose |
  |-----------|---------|---------|
  | Leader → Worker | `GenServer.call` `:request_capabilities` | Get worker capabilities |
  | Leader → Worker | `GenServer.cast` `{:dispatch, %{run_id, sub_agent, params, leader_node, leader_pid}}` | Start a sub-agent run |
  | Leader → Worker | `GenServer.cast` `{:cancel, run_id}` | Cancel a running sub-agent |
  | Leader → Worker | `GenServer.call` `:ping` | Health check |
  """

  use GenServer

  alias CodePuppyControl.Telemetry

  require Logger

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Starts the PackWorker GenServer with the host OS detection.

  ## Options

    * `:host_os` — override host OS detection (`:linux`, `:macos`, `:windows`).
      Defaults to auto-detection via `:os.type/0`.
    * `:available_models` — list of model identifiers the worker supports.
      Defaults to `[]`.

  ## Examples

      {:ok, pid} = CodePuppyControl.Pack.Worker.start_link([])
      {:ok, pid} = CodePuppyControl.Pack.Worker.start_link(host_os: :linux)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = opts[:name] || {:global, {:pack_worker, node()}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    host_os = Keyword.get(opts, :host_os, detect_host_os())
    max_concurrent_runs = Keyword.get(opts, :max_concurrent_runs, 2)
    available_models = Keyword.get(opts, :available_models, [])

    capabilities = %{
      node_name: Node.self(),
      sub_agents: [:terrier, :watchdog, :shepherd, :retriever],
      host_os: host_os,
      available_models: available_models,
      max_concurrent_runs: max_concurrent_runs,
      features: %{
        file_ops: true,
        shell_access: true,
        git_access: true
      }
    }

    state = %{
      leader_node: nil,
      capabilities: capabilities,
      active_runs: %{},
      max_concurrent_runs: max_concurrent_runs
    }

    Logger.info(
      "PackWorker started on #{Node.self()} with capabilities: #{inspect(capabilities)}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:request_capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_cast(
        {:dispatch,
         %{
           run_id: run_id,
           sub_agent: sub_agent,
           params: params,
           leader_node: leader_node,
           leader_pid: leader_pid
         }},
        state
      ) do
    case validate_dispatch(run_id, sub_agent, params, state) do
      :ok ->
        Logger.info(
          "Dispatch accepted: run_id=#{run_id}, sub_agent=#{sub_agent}, " <>
            "leader=#{inspect(leader_node)}"
        )

        Telemetry.distributed_dispatch_start(run_id, sub_agent, Node.self())

        active_runs =
          Map.put(state.active_runs, run_id, %{
            sub_agent: sub_agent,
            params: params,
            leader_node: leader_node,
            leader_pid: leader_pid,
            started_at: System.monotonic_time(:millisecond)
          })

        {:noreply, %{state | leader_node: leader_node, active_runs: active_runs}}

      {:error, reason} ->
        Logger.warning(
          "Dispatch rejected: run_id=#{run_id}, sub_agent=#{sub_agent}, reason=#{reason}"
        )

        Telemetry.distributed_dispatch_exception(run_id, reason)

        # Reply to leader about the rejection
        GenServer.cast(leader_pid, {:result, run_id, %{status: :failure, error: reason}})

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:cancel, run_id}, state) do
    case Map.fetch(state.active_runs, run_id) do
      {:ok, run_info} ->
        Logger.info("Cancelling run: run_id=#{run_id}")

        duration_ms =
          System.monotonic_time(:millisecond) - run_info.started_at

        Telemetry.distributed_dispatch_stop(run_id, :cancelled, duration_ms)

        active_runs = Map.delete(state.active_runs, run_id)
        {:noreply, %{state | active_runs: active_runs}}

      :error ->
        Logger.warning("Cancel requested for unknown run: run_id=#{run_id}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:run_completed, run_id, result}, state) do
    case Map.fetch(state.active_runs, run_id) do
      {:ok, run_info} ->
        GenServer.cast(run_info.leader_pid, {:result, run_id, result})

        duration_ms =
          System.monotonic_time(:millisecond) - run_info.started_at

        Telemetry.distributed_dispatch_stop(run_id, :ok, duration_ms)

        active_runs = Map.delete(state.active_runs, run_id)
        {:noreply, %{state | active_runs: active_runs}}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nodedown, node, _ref}, state) when node == state.leader_node do
    Logger.warning("Leader node disconnected: #{inspect(node)}")

    Telemetry.distributed_node_disconnected(node, Map.keys(state.active_runs), :nodedown)

    {:noreply, %{state | leader_node: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  @doc false
  defp detect_host_os do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :macos
      {:win32, _} -> :windows
      _ -> :linux
    end
  end

  @doc false
  defp validate_dispatch(_run_id, sub_agent, params, state) do
    capabilities = state.capabilities

    cond do
      sub_agent not in capabilities.sub_agents ->
        {:error, "unsupported_sub_agent: #{sub_agent}"}

      not is_nil(params[:model_preference]) and
          params[:model_preference] not in capabilities.available_models ->
        {:error, "unavailable_model: #{params[:model_preference]}"}

      map_size(state.active_runs) >= capabilities.max_concurrent_runs ->
        {:error, "max_concurrent_runs_exceeded"}

      true ->
        :ok
    end
  end
end
