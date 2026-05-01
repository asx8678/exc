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

  ## Dispatch Guards

  The worker validates incoming dispatch messages before processing:

  1. **Shape validation** — dispatch messages missing required keys
     (`run_id`, `sub_agent`, `params`, `leader_node`, `leader_pid`) are
     rejected with a telemetry exception and a failure result sent to
     the leader.
  2. **Duplicate run_id** — dispatches for `run_id`s already in
     `active_runs` are rejected to prevent double-execution.
  3. **Semantic validation** — sub_agent, model preference, and concurrency
     limits are checked via `validate_dispatch/4`.

  ## Message Protocol

  | Direction | Pattern | Purpose |
  |-----------|---------|---------|
  | Leader → Worker | `GenServer.call` `:request_capabilities` | Get worker capabilities |
  | Leader → Worker | `GenServer.cast` `{:dispatch, %{run_id, sub_agent, params, leader_node, leader_pid}}` | Start a sub-agent run |
  | Leader → Worker | `GenServer.cast` `{:cancel, run_id}` | Cancel a running sub-agent |
  | Leader → Worker | `GenServer.call` `:ping` | Health check |
  """

  use GenServer

  alias CodePuppyControl.Pack.NamingService
  alias CodePuppyControl.Pack.Worker.Capabilities
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

  @doc """
  Returns default capabilities (no overrides).

  Delegates to `Capabilities.detect/0`. Useful as a programmatic fallback
  when the full opts-based detection isn't needed.
  """
  @spec default_capabilities() :: map()
  def default_capabilities, do: Capabilities.detect()

  @impl true
  def init(opts) do
    capabilities =
      opts
      |> Capabilities.detect()
      |> Map.put(:features, %{
        file_ops: true,
        shell_access: true,
        git_access: true
      })

    state = %{
      leader_node: nil,
      capabilities: capabilities,
      active_runs: %{},
      max_concurrent_runs: capabilities.max_concurrent_runs
    }

    maybe_register_with_naming_service(capabilities)

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
  def handle_cast({:dispatch, dispatch_msg}, state) when is_map(dispatch_msg) do
    with :ok <- validate_dispatch_shape(dispatch_msg),
         :ok <- validate_duplicate_run_id(dispatch_msg.run_id, state),
         :ok <-
           validate_dispatch(
             dispatch_msg.run_id,
             dispatch_msg.sub_agent,
             dispatch_msg.params,
             state
           ) do
      Logger.info(
        "Dispatch accepted: run_id=#{dispatch_msg.run_id}, " <>
          "sub_agent=#{dispatch_msg.sub_agent}, " <>
          "leader=#{inspect(dispatch_msg.leader_node)}"
      )

      Telemetry.distributed_dispatch_start(
        dispatch_msg.run_id,
        dispatch_msg.sub_agent,
        Node.self()
      )

      active_runs =
        Map.put(state.active_runs, dispatch_msg.run_id, %{
          sub_agent: dispatch_msg.sub_agent,
          params: dispatch_msg.params,
          leader_node: dispatch_msg.leader_node,
          leader_pid: dispatch_msg.leader_pid,
          started_at: System.monotonic_time(:millisecond)
        })

      {:noreply, %{state | leader_node: dispatch_msg.leader_node, active_runs: active_runs}}
    else
      {:error, reason} ->
        Logger.warning(
          "Dispatch rejected: reason=#{reason}, " <>
            "dispatch=#{inspect(dispatch_msg)}"
        )

        Telemetry.distributed_dispatch_exception(dispatch_msg[:run_id] || "unknown", reason)

        if dispatch_msg[:leader_pid] do
          GenServer.cast(
            dispatch_msg.leader_pid,
            {:result, dispatch_msg[:run_id] || "unknown", %{status: :failure, error: reason}}
          )
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:dispatch, dispatch_msg}, state) do
    # Catch-all for non-map dispatch messages (malformed)
    Logger.warning("PackWorker: rejected non-map dispatch: #{inspect(dispatch_msg)}")
    {:noreply, state}
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

  defp maybe_register_with_naming_service(capabilities) do
    case NamingService.register_node(Node.self(), capabilities) do
      :ok ->
        Logger.debug("PackWorker registered with NamingService")

      {:error, reason} ->
        Logger.debug("NamingService registration skipped: #{inspect(reason)}")
    end
  catch
    :exit, _ ->
      Logger.debug("NamingService not available, skipping registration")
  end

  @doc false
  defp validate_dispatch_shape(dispatch_msg) do
    required_keys = [:run_id, :sub_agent, :params, :leader_node, :leader_pid]

    if Enum.all?(required_keys, &Map.has_key?(dispatch_msg, &1)) do
      :ok
    else
      {:error,
       "malformed_dispatch: missing required keys " <>
         "#{inspect(required_keys -- Map.keys(dispatch_msg))}"}
    end
  end

  @doc false
  defp validate_duplicate_run_id(run_id, state) do
    if Map.has_key?(state.active_runs, run_id) do
      {:error, "duplicate_run_id: #{run_id}"}
    else
      :ok
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
