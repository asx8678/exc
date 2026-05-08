defmodule CodePuppyControl.MCP.Server do
  @moduledoc """
  GenServer managing a single MCP server via direct Elixir Port.

  This process:
  1. Spawns an MCP server directly via Elixir Port
  2. Communicates using JSON-RPC with newline-delimited JSON framing
  3. Handles health monitoring and circuit breakers
  4. Implements quarantine with exponential backoff for failing servers
  5. Manages pending requests for async response handling

  ## Health States

  - `:healthy` - Server is operational
  - `:degraded` - Server has experienced some errors but still operational
  - `:unhealthy` - Server has too many errors and is quarantined

  ## Quarantine

  After `@max_errors_before_quarantine` consecutive errors, the server is
  quarantined with exponential backoff durations: 30s, 60s, 120s, 240s.
  During quarantine, tool calls are rejected with `{:error, :quarantined}`.
  """

  use GenServer, restart: :transient

  require Logger

  alias CodePuppyControl.{Protocol, Telemetry}

  defstruct [
    :server_id,
    :name,
    :command,
    :args,
    :env,
    :port,
    :status,
    :health,
    :last_health_check,
    :error_count,
    :quarantine_until,
    pending_requests: %{},
    receive_buffer: ""
  ]

  @type t :: %__MODULE__{
          server_id: String.t(),
          name: String.t(),
          command: String.t(),
          args: list(String.t()),
          env: map(),
          port: port() | nil,
          status: :starting | :running | :stopped | :crashed,
          health: :healthy | :degraded | :unhealthy | :unknown,
          last_health_check: DateTime.t() | nil,
          error_count: non_neg_integer(),
          quarantine_until: DateTime.t() | nil,
          pending_requests: map(),
          receive_buffer: String.t()
        }

  @health_check_interval 30_000
  @max_errors_before_quarantine 3
  @quarantine_durations [30_000, 60_000, 120_000, 240_000]

  # Client API

  @doc """
  Starts an MCP server process linked to the caller.

  ## Options

    * `:server_id` - Required. Unique identifier for this server.
    * `:name` - Required. Human-readable server name.
    * `:command` - Required. The MCP server executable command.
    * `:args` - Optional. Command line arguments (list of strings).
    * `:env` - Optional. Environment variables as a map.

  ## Examples

      {:ok, pid} = MCP.Server.start_link(
        server_id: "files-abc123",
        name: "filesystem",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )
  """
  def start_link(opts) do
    server_id = Keyword.fetch!(opts, :server_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(server_id))
  end

  @doc """
  Returns a `via_tuple` for Registry lookup.
  """
  @spec via_tuple(String.t()) :: {:via, atom(), {atom(), String.t()}}
  def via_tuple(server_id) do
    {:via, Registry, {CodePuppyControl.MCP.Registry, server_id}}
  end

  @doc """
  Calls a tool on the MCP server.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  If the server is quarantined, returns `{:error, :quarantined}`.

  ## Examples

      {:ok, result} = MCP.Server.call_tool(server_id, "read_file", %{"path" => "/tmp/test.txt"})
  """
  @spec call_tool(String.t(), String.t(), map(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def call_tool(server_id, method, params, timeout \\ 30_000) do
    GenServer.call(via_tuple(server_id), {:call_tool, method, params}, timeout + 5000)
  end

  @doc """
  Gets the current status of an MCP server.

  Returns a map with server_id, name, status, health, error_count,
  quarantine status, and timestamps.
  """
  @spec get_status(String.t()) :: map() | {:error, :not_found}
  def get_status(server_id) do
    GenServer.call(via_tuple(server_id), :get_status)
  rescue
    _ -> {:error, :not_found}
  end

  @doc """
  Performs a synchronous health check on the MCP server.

  Returns `:healthy` or `{:unhealthy, reason}`.
  """
  @spec health_check(String.t()) :: :healthy | {:unhealthy, term()}
  def health_check(server_id) do
    GenServer.call(via_tuple(server_id), :health_check)
  end

  @doc """
  Gracefully stops the MCP server.
  """
  @spec stop(String.t()) :: :ok
  def stop(server_id) do
    GenServer.stop(via_tuple(server_id), :normal)
  end

  @doc """
  Looks up the server_id for a given Port PID.
  """
  @spec pid_to_server_id(pid()) :: {:ok, String.t()} | :error
  def pid_to_server_id(pid) do
    case Registry.keys(CodePuppyControl.MCP.Registry, pid) do
      [server_id | _] -> {:ok, server_id}
      _ -> :error
    end
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    server_id = Keyword.fetch!(opts, :server_id)
    name = Keyword.fetch!(opts, :name)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})

    Logger.info("Initializing MCP server #{name} (#{server_id})")

    state = %__MODULE__{
      server_id: server_id,
      name: name,
      command: command,
      args: args,
      env: env,
      status: :starting,
      health: :unknown,
      error_count: 0
    }

    # Start MCP server directly via Port
    case start_mcp_server(state) do
      {:ok, port} ->
        schedule_health_check()
        Logger.info("MCP server #{name} started successfully")
        # Emit MCP connect telemetry
        Telemetry.mcp_connect(server_id, name)
        {:ok, %{state | port: port, status: :running, health: :healthy}}

      {:error, reason} ->
        Logger.error("Failed to start MCP server #{name}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call_tool, method, params}, from, state) do
    if quarantined?(state) do
      Logger.warning("Tool call rejected for quarantined server #{state.name}")
      {:reply, {:error, :quarantined}, state}
    else
      request_id = generate_request_id()
      start_time = System.monotonic_time(:millisecond)

      message =
        Protocol.encode_request(
          "tools/call",
          %{
            "name" => method,
            "arguments" => params
          },
          request_id
        )

      Port.command(state.port, Protocol.frame_newline(message))

      # Track pending request with timing info for telemetry
      pending =
        Map.put(state.pending_requests, request_id, %{
          from: from,
          start_time: start_time,
          method: method
        })

      {:noreply, %{state | pending_requests: pending}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      server_id: state.server_id,
      name: state.name,
      status: state.status,
      health: state.health,
      error_count: state.error_count,
      quarantined: quarantined?(state),
      quarantine_until: state.quarantine_until,
      last_health_check: format_datetime(state.last_health_check)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    case do_health_check(state) do
      :ok ->
        new_state = %{
          state
          | health: :healthy,
            last_health_check: DateTime.utc_now(),
            error_count: 0
        }

        {:reply, :healthy, new_state}

      {:error, reason} ->
        new_state = handle_error(state, reason)
        {:reply, {:unhealthy, reason}, new_state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, receive_buffer: buffer} = state) do
    # newline-delimited JSON — just accumulate and split on newlines
    new_buffer = buffer <> data

    case Protocol.parse_newline(new_buffer) do
      {[], rest} ->
        # Incomplete message, need more data
        {:noreply, %{state | receive_buffer: rest}}

      {messages, rest} when is_list(messages) ->
        # Process all complete messages
        new_state =
          Enum.reduce(messages, %{state | receive_buffer: rest}, fn message, acc_state ->
            {:noreply, new_s} = handle_port_message(message, acc_state)
            new_s
          end)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if status != 0 do
      Logger.error("MCP server #{state.name} exited with status #{status}")
    else
      Logger.info("MCP server #{state.name} exited normally")
    end

    {:stop, {:mcp_exit, status}, %{state | port: nil, status: :crashed}}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state =
      case do_health_check(state) do
        :ok ->
          %{state | health: :healthy, last_health_check: DateTime.utc_now()}

        {:error, reason} ->
          handle_error(state, reason)
      end

    schedule_health_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message in MCP.Server #{state.name}: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Terminating MCP server #{state.name}")

    if state.port do
      Port.close(state.port)
    end

    # Emit MCP disconnect telemetry
    Telemetry.mcp_disconnect(state.server_id, state.name, reason)

    :ok
  end

  # ── Executable resolution ────────────────────────────────────────────

  @doc """
  Resolves a bare command name to an absolute executable path.

  For bare names (npx, docker, uvx, etc.), uses `System.find_executable/1`
  to locate the binary on `$PATH`. Absolute or relative paths are
  returned unchanged so users can explicitly point at a binary.

  Returns `{:ok, path}` on success, `{:error, {:not_found, command}}`
  when the executable cannot be located.
  """
  @spec resolve_command(String.t()) :: {:ok, String.t()} | {:error, {:not_found, String.t()}}
  def resolve_command(command) when is_binary(command) do
    cond do
      # Absolute path — trust the user
      String.starts_with?(command, "/") ->
        {:ok, command}

      # Relative path (contains /) — trust the user
      String.contains?(command, "/") ->
        {:ok, command}

      # Bare command name — resolve via PATH
      true ->
        case System.find_executable(command) do
          nil -> {:error, {:not_found, command}}
          path -> {:ok, path}
        end
    end
  end

  # ── Private functions ──────────────────────────────────────────────────

  defp start_mcp_server(state) do
    # Resolve bare executable names (npx, docker, etc.) via PATH
    # before spawning a Port. This prevents silent failures when
    # the executable is missing and provides a clear error message.
    case resolve_command(state.command) do
      {:error, {:not_found, cmd}} ->
        {:error, {:command_not_found, cmd}}

      {:ok, resolved_command} ->
        spawn_mcp_port(state, resolved_command)
    end
  end

  defp spawn_mcp_port(state, resolved_command) do
    # Convert env map to list of tuples for Port
    env_list =
      state.env
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, to_charlist(resolved_command)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: state.args,
        env: env_list
      ])

    # MCP initialize handshake
    init_request =
      Protocol.encode_request(
        "initialize",
        %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => "code_puppy_control",
            "version" => "0.1.0"
          }
        },
        1
      )

    # Use newline-delimited JSON for MCP stdio transport
    Port.command(port, Protocol.frame_newline(init_request))

    # Wait for initialize response
    receive do
      {^port, {:data, data}} ->
        case Protocol.parse_newline(data) do
          {[], _rest} ->
            Port.close(port)
            {:error, :incomplete_response}

          {[message | _], _rest} ->
            case message do
              %{"result" => %{"serverInfo" => _server_info}} ->
                # Send notifications/initialized to complete handshake
                initialized_notification =
                  Protocol.encode_notification("notifications/initialized", %{})

                # Use newline-delimited JSON for MCP stdio transport
                Port.command(port, Protocol.frame_newline(initialized_notification))
                {:ok, port}

              %{"error" => error} ->
                Port.close(port)
                {:error, error}

              other ->
                Port.close(port)
                {:error, {:unexpected_response, other}}
            end
        end
    after
      10_000 ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp do_health_check(state) do
    # Check port is alive
    case Port.info(state.port) do
      nil ->
        {:error, :port_dead}

      _info ->
        # Send tools/list as a lightweight health probe
        message = Protocol.encode_request("tools/list", %{}, nil)
        # Use newline-delimited JSON for MCP stdio transport
        Port.command(state.port, Protocol.frame_newline(message))

        receive do
          {port, {:data, data}} when port == state.port ->
            case Protocol.parse_newline(data) do
              {[], _rest} ->
                {:error, :incomplete_response}

              {[msg | _], _rest} ->
                case msg do
                  %{"result" => _} -> :ok
                  %{"error" => _} -> {:error, :mcp_error}
                  _ -> {:error, :invalid_response}
                end
            end
        after
          5_000 -> {:error, :timeout}
        end
    end
  end

  defp handle_port_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending_requests, to_string(id)) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, start_time: start_time, method: method} = _pending_data, pending} ->
        # Emit request duration telemetry
        duration_ms =
          System.convert_time_unit(
            System.monotonic_time(:millisecond) - start_time,
            :native,
            :millisecond
          )

        Telemetry.request_duration("mcp:#{state.server_id}", method, id, duration_ms)

        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending_requests: pending, error_count: 0}}
    end
  end

  defp handle_port_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending_requests, to_string(id)) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, start_time: start_time, method: method} = _pending_data, pending} ->
        # Emit request duration telemetry even on error
        duration_ms =
          System.convert_time_unit(
            System.monotonic_time(:millisecond) - start_time,
            :native,
            :millisecond
          )

        Telemetry.request_duration("mcp:#{state.server_id}", method, id, duration_ms)

        GenServer.reply(from, {:error, error})
        {:noreply, handle_error(%{state | pending_requests: pending}, error)}
    end
  end

  defp handle_port_message(%{"method" => "mcp_notification", "params" => params}, state) do
    # Forward MCP server notifications
    Phoenix.PubSub.broadcast(
      CodePuppyControl.PubSub,
      "mcp:#{state.server_id}",
      {:mcp_notification, state.server_id, params}
    )

    {:noreply, state}
  end

  defp handle_port_message(message, state) do
    Logger.debug("Unhandled message from MCP server #{state.name}: #{inspect(message)}")
    {:noreply, state}
  end

  defp handle_error(state, reason) do
    new_count = state.error_count + 1

    if new_count >= @max_errors_before_quarantine do
      quarantine_index =
        min(new_count - @max_errors_before_quarantine, length(@quarantine_durations) - 1)

      duration = Enum.at(@quarantine_durations, quarantine_index)
      quarantine_until = DateTime.add(DateTime.utc_now(), duration, :millisecond)

      Logger.warning(
        "MCP server #{state.name} quarantined for #{div(duration, 1000)}s due to #{new_count} errors. Reason: #{inspect(reason)}"
      )

      Phoenix.PubSub.broadcast(
        CodePuppyControl.PubSub,
        "mcp:#{state.server_id}",
        {:mcp_quarantined, state.server_id, quarantine_until}
      )

      %{
        state
        | error_count: new_count,
          health: :unhealthy,
          quarantine_until: quarantine_until
      }
    else
      Logger.warning(
        "MCP server #{state.name} error count: #{new_count}. Reason: #{inspect(reason)}"
      )

      %{
        state
        | error_count: new_count,
          health: :degraded
      }
    end
  end

  defp quarantined?(%{quarantine_until: nil}), do: false

  defp quarantined?(%{quarantine_until: until}) do
    DateTime.compare(DateTime.utc_now(), until) == :lt
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(dt), do: DateTime.to_iso8601(dt)
end
