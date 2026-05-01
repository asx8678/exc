defmodule CodePuppyControl.Telemetry do
  @moduledoc """
  Telemetry instrumentation for production observability.

  This module provides helper functions for emitting telemetry events throughout
  the codebase. It uses `:telemetry` from the Erlang ecosystem for lightweight,
  efficient metrics collection.

  ## Instrumented Events

  ### Run Lifecycle

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :run, :start]` | `system_time`, `monotonic_time` | `run_id`, `session_id`, `agent_name` |
  | `[:code_puppy, :run, :complete]` | `duration_ms`, `duration_monotonic` | `run_id`, `session_id`, `agent_name` |
  | `[:code_puppy, :run, :fail]` | `duration_ms`, `duration_monotonic` | `run_id`, `session_id`, `agent_name`, `error` |

  ### Request Latency

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :request, :duration]` | `duration_ms`, `system_time` | `run_id`, `method`, `request_id` |

  ### Python Worker

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :python_worker, :start]` | `system_time`, `monotonic_time` | `run_id`, `worker_pid` |
  | `[:code_puppy, :python_worker, :stop]` | `system_time`, `monotonic_time` | `run_id`, `worker_pid`, `reason` |

  ### MCP Connections

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :mcp, :connect]` | `system_time`, `monotonic_time` | `server_id`, `name` |
  | `[:code_puppy, :mcp, :disconnect]` | `system_time`, `monotonic_time` | `server_id`, `name`, `reason` |

  ### WebSocket Connections

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :websocket, :connect]` | `system_time`, `monotonic_time` | `socket_id`, `transport`, `params` |
  | `[:code_puppy, :websocket, :disconnect]` | `duration_ms`, `system_time` | `socket_id`, `reason`, `connected_at` |

  ### Session Resume

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :session, :resume]` | `system_time`, `monotonic_time` | `session_id`, `restored`, `reason` |

  ### Distributed Pack

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:code_puppy, :distributed_pack, :node, :connected]` | `system_time`, `monotonic_time` | `node`, `capabilities` |
  | `[:code_puppy, :distributed_pack, :node, :disconnected]` | `system_time`, `monotonic_time` | `node`, `active_runs`, `reason` |
  | `[:code_puppy, :distributed_pack, :node, :reconnected]` | `system_time`, `monotonic_time` | `node`, `grace_period_ms` |
  | `[:code_puppy, :distributed_pack, :dispatch, :start]` | `system_time`, `monotonic_time` | `run_id`, `sub_agent`, `target_node` |
  | `[:code_puppy, :distributed_pack, :dispatch, :stop]` | `duration_ms`, `system_time` | `run_id`, `status`, `duration_ms` |
  | `[:code_puppy, :distributed_pack, :dispatch, :exception]` | `system_time`, `monotonic_time` | `run_id`, `error` |
  | `[:code_puppy, :distributed_pack, :capabilities, :updated]` | `system_time`, `monotonic_time` | `node`, `capabilities` |

  ## Usage

  Emit events using the helper functions:

      Telemetry.run_start(run_id, session_id, agent_name)
      Telemetry.run_complete(run_id, session_id, agent_name, start_monotonic_time)
      Telemetry.request_duration(run_id, method, request_id, duration_ms)

      Telemetry.distributed_node_connected(node, capabilities)
      Telemetry.distributed_dispatch_start(run_id, :terrier, target_node)
      Telemetry.distributed_dispatch_stop(run_id, :ok, duration_ms)

  See `CodePuppyControl.Telemetry.DistributedPack` for the submodule with
  the actual implementations.

  ## Metrics Handling

  Attach handlers to these events using `:telemetry.attach/4` or `:telemetry.attach_many/4`:

      :telemetry.attach(
        "my-handler",
        [:code_puppy, :run, :complete],
        fn event, measurements, metadata, _config ->
          Logger.info("Run completed: \#{metadata.run_id} in \#{measurements.duration_ms}ms")
        end,
        nil
      )

  Or use `TelemetryMetrics` to define metrics declaratively:

      def metrics do
        [
          Telemetry.Metrics.counter("code_puppy.run.start"),
          Telemetry.Metrics.summary("code_puppy.run.complete.duration", unit: {:millisecond, :ms}),
          Telemetry.Metrics.last_value("code_puppy.request.duration", unit: :millisecond)
        ]
      end
  """

  @typedoc "Run identifier"
  @type run_id :: String.t()

  @typedoc "Session identifier"
  @type session_id :: String.t()

  @typedoc "Agent name"
  @type agent_name :: String.t()

  @typedoc "Monotonic timestamp (millisecond precision)"
  @type monotonic_time :: integer()

  @typedoc "Distributed pack node"
  @type dist_node :: node()

  @typedoc "Run identifier (distributed dispatch)"
  @type dist_run_id :: String.t()

  @typedoc "Sub-agent atom identifier"
  @type sub_agent :: atom()

  @typedoc "Capability map"
  @type capabilities :: map()

  alias CodePuppyControl.Telemetry.DistributedPack

  # ============================================================================
  # Run Lifecycle Events
  # ============================================================================

  @doc """
  Emits a run start event.

  Should be called when a new run begins execution.

  ## Examples

      Telemetry.run_start("run-123", "session-456", "elixir-dev")
  """
  @spec run_start(run_id(), session_id(), agent_name()) :: :ok
  def run_start(run_id, session_id, agent_name) do
    :telemetry.execute(
      [:code_puppy, :run, :start],
      %{
        system_time: System.system_time(:millisecond),
        monotonic_time: System.monotonic_time(:millisecond)
      },
      %{
        run_id: run_id,
        session_id: session_id,
        agent_name: agent_name
      }
    )
  end

  @doc """
  Emits a run complete event.

  Should be called when a run finishes successfully. Include the start time
  to calculate duration.

  ## Examples

      start_time = System.monotonic_time(:millisecond)
      # ... run executes ...
      Telemetry.run_complete("run-123", "session-456", "elixir-dev", start_time)
  """
  @spec run_complete(run_id(), session_id(), agent_name(), monotonic_time()) :: :ok
  def run_complete(run_id, session_id, agent_name, start_monotonic_time) do
    now = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:code_puppy, :run, :complete],
      %{
        duration_ms: System.convert_time_unit(now - start_monotonic_time, :native, :millisecond),
        duration_monotonic: now - start_monotonic_time,
        system_time: System.system_time(:millisecond)
      },
      %{
        run_id: run_id,
        session_id: session_id,
        agent_name: agent_name
      }
    )
  end

  @doc """
  Emits a run failure event.

  Should be called when a run fails. Include the start time and error reason.

  ## Examples

      Telemetry.run_fail("run-123", "session-456", "elixir-dev", start_time, "timeout")
  """
  @spec run_fail(run_id(), session_id(), agent_name(), monotonic_time(), term()) :: :ok
  def run_fail(run_id, session_id, agent_name, start_monotonic_time, error) do
    now = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:code_puppy, :run, :fail],
      %{
        duration_ms: System.convert_time_unit(now - start_monotonic_time, :native, :millisecond),
        duration_monotonic: now - start_monotonic_time,
        system_time: System.system_time(:millisecond)
      },
      %{
        run_id: run_id,
        session_id: session_id,
        agent_name: agent_name,
        error: error
      }
    )
  end

  @doc """
  Helper to emit run_complete or run_fail based on result.

  ## Examples

      Telemetry.run_finish("run-123", "session-456", "elixir-dev", start_time, :ok)
      Telemetry.run_finish("run-123", "session-456", "elixir-dev", start_time, {:error, reason})
  """
  @spec run_finish(run_id(), session_id(), agent_name(), monotonic_time(), :ok | {:error, term()}) ::
          :ok
  def run_finish(run_id, session_id, agent_name, start_monotonic_time, :ok) do
    run_complete(run_id, session_id, agent_name, start_monotonic_time)
  end

  def run_finish(run_id, session_id, agent_name, start_monotonic_time, {:error, error}) do
    run_fail(run_id, session_id, agent_name, start_monotonic_time, error)
  end

  # ============================================================================
  # Request Duration Events
  # ============================================================================

  @doc """
  Emits a request duration event.

  Used to track the latency of individual requests to Python workers or MCP servers.

  ## Examples

      Telemetry.request_duration("run-123", "run/start", "req-456", 150)
  """
  @spec request_duration(run_id(), String.t(), String.t(), non_neg_integer()) :: :ok
  def request_duration(run_id, method, request_id, duration_ms) do
    :telemetry.execute(
      [:code_puppy, :request, :duration],
      %{
        duration_ms: duration_ms,
        system_time: System.system_time(:millisecond)
      },
      %{
        run_id: run_id,
        method: method,
        request_id: request_id
      }
    )
  end

  @doc """
  Measures and emits a request duration.

  Wraps a function, measures its execution time, and emits a duration event.

  ## Examples

      result = Telemetry.measure_request("run-123", "run/start", "req-456", fn ->
        PythonWorker.Port.call(run_id, method, params)
      end)
  """
  @spec measure_request(run_id(), String.t(), String.t(), (-> result)) :: result when result: var
  def measure_request(run_id, method, request_id, fun) do
    {duration_ms, result} = :timer.tc(fun, :millisecond)

    request_duration(run_id, method, request_id, duration_ms)

    result
  end

  # ============================================================================
  # Python Worker Events
  # ============================================================================

  @doc """
  Emits a Python worker start event.

  ## Examples

      Telemetry.python_worker_start("run-123", self())
  """
  @spec python_worker_start(run_id(), pid()) :: :ok
  def python_worker_start(run_id, worker_pid) do
    :telemetry.execute(
      [:code_puppy, :python_worker, :start],
      %{
        system_time: System.system_time(:millisecond),
        monotonic_time: System.monotonic_time(:millisecond)
      },
      %{
        run_id: run_id,
        worker_pid: worker_pid
      }
    )
  end

  @doc """
  Emits a Python worker stop event.

  ## Examples

      Telemetry.python_worker_stop("run-123", self(), :normal)
  """
  @spec python_worker_stop(run_id(), pid(), term()) :: :ok
  def python_worker_stop(run_id, worker_pid, reason) do
    :telemetry.execute(
      [:code_puppy, :python_worker, :stop],
      %{
        system_time: System.system_time(:millisecond),
        monotonic_time: System.monotonic_time(:millisecond)
      },
      %{
        run_id: run_id,
        worker_pid: worker_pid,
        reason: reason
      }
    )
  end

  # ============================================================================
  # MCP Connection Events
  # ============================================================================

  @doc """
  Emits an MCP connect event.

  ## Examples

      Telemetry.mcp_connect("server-123", "filesystem")
  """
  @spec mcp_connect(String.t(), String.t()) :: :ok
  def mcp_connect(server_id, name) do
    :telemetry.execute(
      [:code_puppy, :mcp, :connect],
      %{
        system_time: System.system_time(:millisecond),
        monotonic_time: System.monotonic_time(:millisecond)
      },
      %{
        server_id: server_id,
        name: name
      }
    )
  end

  @doc """
  Emits an MCP disconnect event.

  ## Examples

      Telemetry.mcp_disconnect("server-123", "filesystem", :normal)
  """
  @spec mcp_disconnect(String.t(), String.t(), term()) :: :ok
  def mcp_disconnect(server_id, name, reason) do
    :telemetry.execute(
      [:code_puppy, :mcp, :disconnect],
      %{
        system_time: System.system_time(:millisecond),
        monotonic_time: System.monotonic_time(:millisecond)
      },
      %{
        server_id: server_id,
        name: name,
        reason: reason
      }
    )
  end

  # ============================================================================
  # WebSocket Events
  # ============================================================================

  @doc """
  Emits a WebSocket connect event.

  ## Examples

      Telemetry.websocket_connect(socket.id, socket.transport, socket.assigns.client_params)
  """
  @spec websocket_connect(term(), term(), map()) :: :ok
  def websocket_connect(socket_id, transport, params) do
    :telemetry.execute(
      [:code_puppy, :websocket, :connect],
      %{
        system_time: System.system_time(:millisecond),
        monotonic_time: System.monotonic_time(:millisecond)
      },
      %{
        socket_id: socket_id,
        transport: transport,
        params: params
      }
    )
  end

  @doc """
  Emits a WebSocket disconnect event.

  ## Examples

      Telemetry.websocket_disconnect(socket.id, reason, socket.assigns.connected_at)
  """
  @spec websocket_disconnect(term(), term(), DateTime.t() | nil) :: :ok
  def websocket_disconnect(socket_id, reason, connected_at) do
    duration_ms =
      if connected_at do
        DateTime.utc_now()
        |> DateTime.diff(connected_at, :millisecond)
      else
        0
      end

    :telemetry.execute(
      [:code_puppy, :websocket, :disconnect],
      %{
        duration_ms: duration_ms,
        system_time: System.system_time(:millisecond)
      },
      %{
        socket_id: socket_id,
        reason: reason,
        connected_at: connected_at
      }
    )
  end

  # ============================================================================
  # Session Resume Events
  # ============================================================================

  @doc """
  Emits a session resume event for `pup --continue`.

  `reason` is `:latest` when a persisted session was restored, or a fallback
  reason such as `:no_sessions`, `:list_failed`, `:load_failed`, or
  `:agent_state_failed` when the CLI starts a fresh interactive session.
  """
  @spec session_resume(String.t() | nil, boolean(), atom()) :: :ok
  def session_resume(session_id, restored, reason) do
    :telemetry.execute(
      [:code_puppy, :session, :resume],
      %{
        system_time: System.system_time(:millisecond),
        monotonic_time: System.monotonic_time(:millisecond)
      },
      %{
        session_id: session_id,
        restored: restored,
        reason: reason
      }
    )
  end

  # ============================================================================
  # Distributed Pack Events (delegated to DistributedPack submodule)
  # ============================================================================

  # Distributed pack telemetry helpers live in CodePuppyControl.Telemetry.DistributedPack
  # to keep this module under the 600-line cap. These delegations preserve
  # backward compatibility for callers using Telemetry.distributed_*.

  @doc """
  Delegates to `DistributedPack.node_connected/2`.
  """
  defdelegate distributed_node_connected(node, capabilities),
    to: CodePuppyControl.Telemetry.DistributedPack,
    as: :node_connected

  @doc """
  Delegates to `DistributedPack.node_disconnected/3`.
  """
  defdelegate distributed_node_disconnected(node, active_runs, reason),
    to: CodePuppyControl.Telemetry.DistributedPack,
    as: :node_disconnected

  @doc """
  Delegates to `DistributedPack.node_reconnected/2`.
  """
  defdelegate distributed_node_reconnected(node, grace_period_ms),
    to: CodePuppyControl.Telemetry.DistributedPack,
    as: :node_reconnected

  @doc """
  Delegates to `DistributedPack.dispatch_start/3`.
  """
  defdelegate distributed_dispatch_start(run_id, sub_agent, target_node),
    to: CodePuppyControl.Telemetry.DistributedPack,
    as: :dispatch_start

  @doc """
  Delegates to `DistributedPack.dispatch_stop/3`.
  """
  defdelegate distributed_dispatch_stop(run_id, status, duration_ms),
    to: CodePuppyControl.Telemetry.DistributedPack,
    as: :dispatch_stop

  @doc """
  Delegates to `DistributedPack.dispatch_exception/2`.
  """
  defdelegate distributed_dispatch_exception(run_id, error),
    to: CodePuppyControl.Telemetry.DistributedPack,
    as: :dispatch_exception

  @doc """
  Delegates to `DistributedPack.capabilities_updated/2`.
  """
  defdelegate distributed_capabilities_updated(node, capabilities),
    to: CodePuppyControl.Telemetry.DistributedPack,
    as: :capabilities_updated

  # ============================================================================
  # Span Tracking
  # ============================================================================

  @doc """
  Starts a telemetry span for tracking nested operations.

  Returns a map with span context that should be passed to `span_end/2`.

  ## Examples

      span = Telemetry.span_start([:code_puppy, :run, :execution], run_id: "run-123")
      # ... do work ...
      Telemetry.span_end(span, :ok)
  """
  @spec span_start(list(atom()), keyword()) :: map()
  def span_start(event_prefix, metadata \\ []) do
    %{
      event_prefix: event_prefix,
      start_monotonic: System.monotonic_time(:millisecond),
      metadata: Map.new(metadata)
    }
  end

  @doc """
  Ends a telemetry span and emits the appropriate event.

  ## Examples

      Telemetry.span_end(span, :ok)
      Telemetry.span_end(span, {:error, reason}, %{extra: "data"})
  """
  @spec span_end(map(), :ok | {:ok, term()} | {:error, term()}, map()) :: :ok
  def span_end(span, result, extra_metadata \\ %{}) do
    now = System.monotonic_time(:millisecond)
    duration = now - span.start_monotonic

    event_name =
      case result do
        :ok -> :complete
        {:ok, _} -> :complete
        {:error, _} -> :fail
        :error -> :fail
      end

    measurements = %{
      duration_ms: System.convert_time_unit(duration, :native, :millisecond),
      duration_monotonic: duration,
      system_time: System.system_time(:millisecond)
    }

    metadata =
      Map.merge(span.metadata, extra_metadata)
      |> Map.put(:result, result)

    :telemetry.execute(span.event_prefix ++ [event_name], measurements, metadata)
  end
end
