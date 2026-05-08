defmodule CodePuppyControl.MCP.Client do
  @moduledoc """
  GenServer that manages a connection to one MCP server.

  Supports three transports:
  - `:stdio` — spawns a subprocess, communicates via stdin/stdout JSON-RPC
  - `:sse`   — connects via HTTP Server-Sent Events (SSE) stream
  - `:streamable_http` — connects via HTTP with streaming support

  ## Lifecycle

  1. Starts in `:disconnected` state
  2. Connects via the configured transport → `:connecting`
  3. Performs `initialize` / `notifications/initialized` handshake → `:handshaking`
  4. Receives initialize response → `:connected`
  5. Fetches `tools/list` → `:fetching_tools`
  6. Receives tools/list response → `:ready`
  7. If the connection drops, transitions to `:disconnected` and retries with
      exponential backoff

  ## Usage

      {:ok, pid} = MCP.Client.start_link(
        id: "my-server",
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

      {:ok, tools} = MCP.Client.list_tools("my-server")
      {:ok, result} = MCP.Client.call_tool("my-server", "read_file", %{"path" => "/tmp/test.txt"})
  """

  use GenServer, restart: :transient

  require Logger

  alias CodePuppyControl.Protocol

  @type transport :: :stdio | :sse | :streamable_http
  @type state_status ::
          :disconnected | :connecting | :handshaking | :connected | :fetching_tools | :ready

  defstruct [
    :id,
    :transport,
    # stdio config
    :command,
    :args,
    :env,
    :cwd,
    # SSE / StreamableHTTP config
    :url,
    :headers,
    # runtime state
    :port,
    :status,
    :server_info,
    :tools,
    :capabilities,
    :receive_buffer,
    :pending_requests,
    :request_counter,
    # reconnect
    :reconnect_attempts,
    :reconnect_timer,
    # HTTP streaming state (SSE / StreamableHTTP)
    :stream_ref,
    :finch_name
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          transport: transport(),
          command: String.t() | nil,
          args: [String.t()],
          env: map(),
          cwd: String.t() | nil,
          url: String.t() | nil,
          headers: [{String.t(), String.t()}],
          port: port() | nil,
          status: state_status(),
          server_info: map() | nil,
          tools: [map()],
          capabilities: map(),
          receive_buffer: String.t(),
          pending_requests: %{String.t() => GenServer.from() | :internal},
          request_counter: non_neg_integer(),
          reconnect_attempts: non_neg_integer(),
          reconnect_timer: reference() | nil,
          stream_ref: reference() | nil,
          finch_name: module() | nil
        }

  # Reconnect backoff: 1s, 2s, 4s, 8s, 16s, max 30s
  @reconnect_base_ms 1_000
  @reconnect_max_ms 30_000
  @max_reconnect_attempts 10

  @default_timeout 30_000
  @protocol_version "2024-11-05"

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Starts an MCP client linked to the calling process.

  ## Required options

    * `:id` — unique identifier for this client
    * `:transport` — `:stdio`, `:sse`, or `:streamable_http`

  ## stdio-specific options

    * `:command` — executable to run (required for stdio)
    * `:args` — command arguments (default: `[]`)
    * `:env` — environment variables map (default: `%{}`)
    * `:cwd` — working directory (default: current directory)

  ## SSE / StreamableHTTP-specific options

    * `:url` — server URL (required for SSE / StreamableHTTP)
    * `:headers` — HTTP headers as keyword list (default: `[]`)

  ## General options

    * `:finch_name` — Finch pool name for HTTP transports (default: `CodePuppyControl.Finch`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
  end

  @doc "Returns a via tuple for Registry lookup."
  @spec via_tuple(String.t()) :: {:via, Registry, {Registry, String.t()}}
  def via_tuple(id) do
    {:via, Registry, {CodePuppyControl.MCP.ClientRegistry, id}}
  end

  @doc "Lists the tools available on this MCP server."
  @spec list_tools(String.t(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(id, timeout \\ @default_timeout) do
    GenServer.call(via_tuple(id), :list_tools, timeout + 5_000)
  end

  @doc "Calls a tool on the MCP server."
  @spec call_tool(String.t(), String.t(), map(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def call_tool(id, tool_name, arguments \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(via_tuple(id), {:call_tool, tool_name, arguments}, timeout + 5_000)
  end

  @doc "Returns the current state of the client."
  @spec get_state(String.t()) :: map() | {:error, :not_found}
  def get_state(id) do
    GenServer.call(via_tuple(id), :get_state)
  rescue
    _ -> {:error, :not_found}
  end

  @doc "Initiates a graceful shutdown of the MCP client."
  @spec stop(String.t()) :: :ok
  def stop(id) do
    GenServer.stop(via_tuple(id), :normal)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    transport = Keyword.fetch!(opts, :transport)

    state = %__MODULE__{
      id: id,
      transport: transport,
      command: opts[:command],
      args: opts[:args] || [],
      env: opts[:env] || %{},
      cwd: opts[:cwd],
      url: opts[:url],
      headers: opts[:headers] || [],
      status: :disconnected,
      tools: [],
      capabilities: %{},
      receive_buffer: "",
      pending_requests: %{},
      request_counter: 0,
      reconnect_attempts: 0,
      finch_name: opts[:finch_name] || CodePuppyControl.Finch
    }

    # Validate required config
    case validate_config(state) do
      :ok ->
        send(self(), :connect)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, %{status: :ready, tools: tools} = state) do
    {:reply, {:ok, tools}, state}
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, from, %{status: :ready} = state) do
    {request_id, state} = next_request_id(state)

    message =
      Protocol.encode_request(
        "tools/call",
        %{"name" => tool_name, "arguments" => arguments},
        request_id
      )

    case send_message(state, message) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call_tool, _tool_name, _arguments}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    summary = %{
      id: state.id,
      transport: state.transport,
      status: state.status,
      server_info: state.server_info,
      tool_count: length(state.tools),
      tools: state.tools,
      capabilities: state.capabilities,
      reconnect_attempts: state.reconnect_attempts
    }

    {:reply, summary, state}
  end

  # ── Connection lifecycle (async state machine) ──────────────────────────

  @impl true
  def handle_info(:connect, %{status: :disconnected} = state) do
    case do_connect(state) do
      {:ok, new_state} ->
        # Send initialize request
        send(self(), :send_initialize)
        {:noreply, %{new_state | status: :connecting, reconnect_attempts: 0}}

      {:error, reason} ->
        Logger.warning("MCP client #{state.id} connect failed: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  @impl true
  def handle_info(:send_initialize, %{status: :connecting} = state) do
    init_request =
      Protocol.encode_request("initialize", initialize_params(), "init-1")

    case send_message(state, init_request) do
      :ok ->
        {:noreply, %{state | status: :handshaking}}

      {:error, reason} ->
        Logger.warning("MCP client #{state.id} failed to send initialize: #{inspect(reason)}")
        new_state = do_disconnect(state)
        {:noreply, schedule_reconnect(new_state)}
    end
  end

  @impl true
  def handle_info(:send_initialized, %{status: :connected} = state) do
    # Send the initialized notification (no id — fire and forget)
    initialized = Protocol.encode_notification("notifications/initialized", %{})

    case send_message(state, initialized) do
      :ok ->
        # Now fetch tools
        send(self(), :send_tools_list)
        {:noreply, %{state | status: :fetching_tools}}

      {:error, reason} ->
        Logger.warning("MCP client #{state.id} failed to send initialized: #{inspect(reason)}")
        new_state = do_disconnect(state)
        {:noreply, schedule_reconnect(new_state)}
    end
  end

  @impl true
  def handle_info(:send_tools_list, %{status: :fetching_tools} = state) do
    {request_id, state} = next_request_id(state)
    message = Protocol.encode_request("tools/list", %{}, request_id)

    # Mark this as an internal request (we handle the response ourselves)
    pending = Map.put(state.pending_requests, request_id, :internal)

    case send_message(state, message) do
      :ok ->
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        Logger.warning("MCP client #{state.id} failed to send tools/list: #{inspect(reason)}")
        new_state = do_disconnect(state)
        {:noreply, schedule_reconnect(new_state)}
    end
  end

  # stdio: Port data received
  @impl true
  def handle_info({port, {:data, data}}, %{port: port, transport: :stdio} = state) do
    new_buffer = state.receive_buffer <> data

    case Protocol.parse_newline(new_buffer) do
      {[], rest} ->
        {:noreply, %{state | receive_buffer: rest}}

      {messages, rest} ->
        new_state =
          Enum.reduce(messages, %{state | receive_buffer: rest}, fn msg, acc ->
            handle_incoming_message(msg, acc)
          end)

        {:noreply, new_state}
    end
  end

  # stdio: Port exit
  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port, transport: :stdio} = state) do
    Logger.warning("MCP client #{state.id}: server process exited (code=#{code})")
    {:noreply, schedule_reconnect(%{state | port: nil, status: :disconnected})}
  end

  # SSE / StreamableHTTP: Finch async response chunks
  @impl true
  def handle_info(
        {Finch.AsyncResponse, ref, {:status, status_code}},
        %{stream_ref: ref} = state
      ) do
    Logger.debug("MCP client #{state.id}: HTTP status #{status_code}")

    if status_code >= 200 and status_code < 300 do
      {:noreply, state}
    else
      Logger.warning("MCP client #{state.id}: HTTP error #{status_code}")
      new_state = do_disconnect(state)
      {:noreply, schedule_reconnect(new_state)}
    end
  end

  @impl true
  def handle_info(
        {Finch.AsyncResponse, ref, {:headers, headers}},
        %{stream_ref: ref} = state
      ) do
    Logger.debug("MCP client #{state.id}: SSE headers: #{inspect(headers)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {Finch.AsyncResponse, ref, {:data, data}},
        %{stream_ref: ref, transport: :sse} = state
      ) do
    # SSE data comes in "data: <json>\n\n" format
    new_buffer = state.receive_buffer <> data

    {messages, rest} = parse_sse_stream(new_buffer)

    new_state =
      Enum.reduce(messages, %{state | receive_buffer: rest}, fn msg, acc ->
        handle_incoming_message(msg, acc)
      end)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(
        {Finch.AsyncResponse, ref, {:data, data}},
        %{stream_ref: ref, transport: :streamable_http} = state
      ) do
    # StreamableHTTP uses newline-delimited JSON like stdio
    new_buffer = state.receive_buffer <> data

    case Protocol.parse_newline(new_buffer) do
      {[], rest} ->
        {:noreply, %{state | receive_buffer: rest}}

      {messages, rest} ->
        new_state =
          Enum.reduce(messages, %{state | receive_buffer: rest}, fn msg, acc ->
            handle_incoming_message(msg, acc)
          end)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({Finch.AsyncResponse, ref, :done}, %{stream_ref: ref} = state) do
    Logger.info("MCP client #{state.id}: HTTP stream closed")
    new_state = do_disconnect(%{state | stream_ref: nil})
    {:noreply, schedule_reconnect(new_state)}
  end

  @impl true
  def handle_info({Finch.AsyncResponse, ref, {:error, reason}}, %{stream_ref: ref} = state) do
    Logger.warning("MCP client #{state.id}: HTTP stream error: #{inspect(reason)}")
    new_state = do_disconnect(%{state | stream_ref: nil})
    {:noreply, schedule_reconnect(new_state)}
  end

  # Reconnect timer
  @impl true
  def handle_info(:reconnect, %{status: :disconnected} = state) do
    send(self(), :connect)
    {:noreply, %{state | reconnect_timer: nil}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    # Already connected, ignore stale timer
    {:noreply, %{state | reconnect_timer: nil}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("MCP client #{state.id}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("MCP client #{state.id} terminating: #{inspect(reason)}")
    do_disconnect(state)
    :ok
  end

  # ── Incoming message dispatch ──────────────────────────────────────────

  # Handle initialize response during handshake
  defp handle_incoming_message(
         %{"id" => "init-1", "result" => result},
         %{status: :handshaking} = state
       ) do
    server_info = Map.get(result, "serverInfo", %{})
    capabilities = Map.get(result, "capabilities", %{})

    # Transition to connected, then send initialized notification
    send(self(), :send_initialized)
    %{state | status: :connected, server_info: server_info, capabilities: capabilities}
  end

  defp handle_incoming_message(
         %{"id" => "init-1", "error" => error},
         %{status: :handshaking} = state
       ) do
    Logger.warning("MCP client #{state.id}: handshake error: #{inspect(error)}")
    new_state = do_disconnect(state)
    schedule_reconnect(new_state)
  end

  # Handle tools/list response during fetching_tools
  defp handle_incoming_message(
         %{"id" => id, "result" => %{"tools" => tools} = result},
         %{status: :fetching_tools} = state
       ) do
    case Map.pop(state.pending_requests, id) do
      {:internal, pending} ->
        Logger.info("MCP client #{state.id}: ready with #{length(tools)} tools")
        %{state | status: :ready, tools: tools, pending_requests: pending}

      _ ->
        # Not our internal request — maybe a user request
        handle_response_message(id, result, state)
    end
  end

  defp handle_incoming_message(
         %{"id" => id, "error" => error},
         %{status: :fetching_tools} = state
       ) do
    case Map.pop(state.pending_requests, id) do
      {:internal, _pending} ->
        Logger.warning("MCP client #{state.id}: tools/list error: #{inspect(error)}")
        new_state = do_disconnect(state)
        schedule_reconnect(new_state)

      _ ->
        handle_error_message(id, error, state)
    end
  end

  # General response handler (when ready)
  defp handle_incoming_message(%{"id" => id, "result" => result}, state) do
    handle_response_message(id, result, state)
  end

  defp handle_incoming_message(%{"id" => id, "error" => error}, state) do
    handle_error_message(id, error, state)
  end

  # Server notification
  defp handle_incoming_message(%{"method" => method, "params" => params}, state) do
    Logger.debug("MCP client #{state.id}: notification #{method}")

    Phoenix.PubSub.broadcast(
      CodePuppyControl.PubSub,
      "mcp:client:#{state.id}",
      {:mcp_notification, state.id, method, params}
    )

    state
  end

  defp handle_incoming_message(msg, state) do
    Logger.debug("MCP client #{state.id}: unhandled message: #{inspect(msg)}")
    state
  end

  defp handle_response_message(id, result, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        state

      {:internal, pending} ->
        # Internal request during non-standard state — just update
        %{state | pending_requests: pending}

      {from, pending} ->
        GenServer.reply(from, {:ok, result})
        %{state | pending_requests: pending}
    end
  end

  defp handle_error_message(id, error, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        state

      {:internal, pending} ->
        %{state | pending_requests: pending}

      {from, pending} ->
        GenServer.reply(from, {:error, error})
        %{state | pending_requests: pending}
    end
  end

  # ── Connection Logic ────────────────────────────────────────────────────

  defp validate_config(%{transport: :stdio, command: nil}) do
    {:error, {:config, "stdio transport requires :command"}}
  end

  defp validate_config(%{transport: transport, url: nil})
       when transport in [:sse, :streamable_http] do
    {:error, {:config, "#{transport} transport requires :url"}}
  end

  defp validate_config(_state), do: :ok

  defp do_connect(%{transport: :stdio} = state) do
    env_list =
      state.env
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      args: state.args,
      env: env_list
    ]

    port_opts =
      if state.cwd do
        Keyword.put(port_opts, :cd, to_charlist(state.cwd))
      else
        port_opts
      end

    try do
      port = Port.open({:spawn_executable, to_charlist(state.command)}, port_opts)
      Logger.info("MCP client #{state.id}: stdio process started")
      {:ok, %{state | port: port, receive_buffer: ""}}
    rescue
      e -> {:error, {:port_open, e}}
    end
  end

  defp do_connect(%{transport: :sse, url: url, finch_name: finch_name, headers: headers} = state) do
    # SSE: GET to the URL, receive streaming events via async Finch
    request = Finch.build(:get, url, sse_headers(headers))

    try do
      ref = Finch.async_request(request, finch_name, recv_timeout: @default_timeout)
      {:ok, %{state | stream_ref: ref, receive_buffer: ""}}
    rescue
      e -> {:error, {:sse_connect, e}}
    end
  end

  defp do_connect(%{transport: :streamable_http} = state) do
    # For StreamableHTTP, we'll send initialize synchronously to get the
    # session endpoint, then use async streaming for subsequent messages
    init_request =
      Protocol.encode_request("initialize", initialize_params(), "init-1")

    body = Protocol.frame_newline(init_request)

    request = Finch.build(:post, state.url, streamable_http_headers(state.headers), body)

    try do
      case Finch.request(request, state.finch_name, recv_timeout: @default_timeout) do
        {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
          case Protocol.parse_newline(resp_body) do
            {[%{"id" => "init-1", "result" => result}], _rest} ->
              server_info = Map.get(result, "serverInfo", %{})
              capabilities = Map.get(result, "capabilities", %{})

              # Send initialized notification
              initialized = Protocol.encode_notification("notifications/initialized", %{})
              init_body = Protocol.frame_newline(initialized)

              init_req =
                Finch.build(:post, state.url, streamable_http_headers(state.headers), init_body)

              _ = Finch.request(init_req, state.finch_name, recv_timeout: 5_000)

              # Skip directly to fetching_tools since we've done the handshake synchronously
              send(self(), :send_tools_list)

              {:ok,
               %{
                 state
                 | receive_buffer: "",
                   status: :fetching_tools,
                   server_info: server_info,
                   capabilities: capabilities
               }}

            _ ->
              {:error, :unexpected_handshake_response}
          end

        {:ok, %Finch.Response{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, {:http_connect, reason}}
      end
    rescue
      e -> {:error, {:http_connect, e}}
    end
  end

  defp do_disconnect(%{transport: :stdio, port: port} = state) when is_port(port) do
    Port.close(port)
    %{state | port: nil, status: :disconnected, receive_buffer: ""}
  end

  defp do_disconnect(%{transport: transport, stream_ref: ref} = state)
       when transport in [:sse, :streamable_http] and not is_nil(ref) do
    %{state | stream_ref: nil, status: :disconnected, receive_buffer: ""}
  end

  defp do_disconnect(state) do
    %{state | port: nil, stream_ref: nil, status: :disconnected, receive_buffer: ""}
  end

  # ── Sending Messages ────────────────────────────────────────────────────

  defp send_message(%{transport: :stdio, port: port}, message) when is_port(port) do
    framed = Protocol.frame_newline(message)
    Port.command(port, framed)
    :ok
  end

  defp send_message(%{transport: :stdio}, _message) do
    {:error, :not_connected}
  end

  defp send_message(
         %{transport: :sse, url: url, finch_name: finch_name, headers: headers},
         message
       ) do
    body = Jason.encode!(message)
    message_url = sse_message_url(url)
    request = Finch.build(:post, message_url, sse_post_headers(headers), body)

    case Finch.request(request, finch_name, recv_timeout: @default_timeout) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:send_error, reason}}
    end
  end

  defp send_message(
         %{transport: :streamable_http, url: url, finch_name: finch_name, headers: headers},
         message
       ) do
    body = Protocol.frame_newline(message)
    request = Finch.build(:post, url, streamable_http_headers(headers), body)

    case Finch.request(request, finch_name, recv_timeout: @default_timeout) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:send_error, reason}}
    end
  end

  # ── Reconnection ───────────────────────────────────────────────────────

  defp schedule_reconnect(%{reconnect_attempts: attempts} = state)
       when attempts >= @max_reconnect_attempts do
    Logger.error("MCP client #{state.id}: max reconnect attempts reached")
    %{state | status: :disconnected}
  end

  defp schedule_reconnect(state) do
    delay =
      min(
        (@reconnect_base_ms * :math.pow(2, state.reconnect_attempts)) |> round(),
        @reconnect_max_ms
      )

    attempts = state.reconnect_attempts + 1

    Logger.info("MCP client #{state.id}: reconnecting in #{delay}ms (attempt #{attempts})")

    timer = Process.send_after(self(), :reconnect, delay)
    %{state | reconnect_timer: timer, reconnect_attempts: attempts, status: :disconnected}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp initialize_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{
        "name" => "code_puppy_control",
        "version" => "0.1.0"
      }
    }
  end

  defp next_request_id(state) do
    counter = state.request_counter + 1
    id = "req-#{counter}"
    {id, %{state | request_counter: counter}}
  end

  defp sse_headers(base_headers) do
    [{"accept", "text/event-stream"} | base_headers]
  end

  defp sse_post_headers(base_headers) do
    [{"content-type", "application/json"} | base_headers]
  end

  defp streamable_http_headers(base_headers) do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"} | base_headers
    ]
  end

  defp sse_message_url(url) do
    URI.merge(url, "/message") |> to_string()
  end

  defp parse_sse_stream(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.reduce({[], ""}, fn chunk, {msgs, incomplete} ->
      case parse_sse_chunk(chunk) do
        {:ok, message} -> {msgs ++ [message], incomplete}
        :incomplete -> {msgs, chunk <> "\n\n"}
        :skip -> {msgs, incomplete}
      end
    end)
  end

  defp parse_sse_chunk(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, "data: ") do
        json_str = String.trim_leading(line, "data: ")

        case Jason.decode(json_str) do
          {:ok, message} when is_map(message) -> {:ok, message}
          _ -> :skip
        end
      end
    end) || :skip
  end
end
