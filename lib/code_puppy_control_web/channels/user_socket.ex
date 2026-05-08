defmodule CodePuppyControlWeb.UserSocket do
  @moduledoc """
  Phoenix Socket for WebSocket connections.

  This socket handles client connections to the real-time event system.
  Clients connect via WebSocket and then join channels for sessions or runs.

  ## Channels

  - `"session:*"` - SessionChannel: Events for all runs in a session
  - `"run:*"` - RunChannel: Events for a specific run only
  - `"events:*"` - EventsChannel: Real-time event streaming (replaces `/ws/events`)
  - `"terminal:*"` - TerminalChannel: Interactive PTY sessions (replaces `/ws/terminal`)
  - `"health"` - HealthChannel: Health monitoring and echo (replaces `/ws/health`)

  ## Authentication

  Token-based authentication is used to verify clients. Pass a signed token
  in the connect params:

      let socket = new Phoenix.Socket("/socket", {params: {token: signedToken}})

  ## Token Generation

  Tokens are signed using `Phoenix.Token` with the `PUP_WEBSOCKET_SECRET`
  environment variable. Generate tokens server-side:

      Phoenix.Token.sign(socket, "session", session_id)

  ## Dev Mode

  If `PUP_WEBSOCKET_SECRET` is not configured, all connections are allowed.
  The socket assigns will have `verified_session_id: nil`.

  ## Example Client Usage (JavaScript)

      let socket = new Phoenix.Socket("/socket", {params: {token: myToken}})
      socket.connect()

      let sessionChannel = socket.channel("session:session-123", {replay: true})
      sessionChannel.join()
        .receive("ok", resp => console.log("Joined session", resp))
        .receive("error", resp => console.log("Failed to join", resp))

      sessionChannel.on("event", event => console.log("Got event:", event))
      sessionChannel.on("replay", ({events, cursor}) => {
        console.log("Replayed", events.length, "events")
      })

  ## Protocol

  Messages follow Phoenix Channel protocol:
  - Heartbeat every 30s
  - Events pushed from server: `{"event", payload}`
  - Messages from client: `{"event_name", payload}` with reply
  """

  use Phoenix.Socket

  require Logger

  alias CodePuppyControl.Telemetry

  # 24 hours
  @token_max_age 86_400

  # ============================================================================
  # Channels
  # ============================================================================

  channel "session:*", CodePuppyControlWeb.SessionChannel
  channel "run:*", CodePuppyControlWeb.RunChannel
  channel "events:*", CodePuppyControlWeb.EventsChannel
  channel "terminal:*", CodePuppyControlWeb.TerminalChannel
  channel "health", CodePuppyControlWeb.HealthChannel

  # ============================================================================
  # Connection
  # ============================================================================

  @doc """
  Verify and identify the socket connection.

  If `PUP_WEBSOCKET_SECRET` is configured, validates the token parameter
  and extracts the session_id. If no secret is configured (dev mode),
  accepts all connections.

  ## Socket ID

  Returns a session-based socket ID if authenticated, or nil if in dev mode.
  """
  @impl true
  def connect(params, socket, connect_info) do
    Logger.debug("UserSocket: client connecting with params #{inspect(params)}")

    # Verify Origin header for CORS protection
    # Phoenix provides headers in connect_info[:x_headers] as [{key, value}, ...]
    origin =
      case connect_info[:x_headers] do
        headers when is_list(headers) ->
          Enum.find_value(headers, fn
            {"origin", value} -> value
            {"Origin", value} -> value
            _ -> nil
          end)

        _ ->
          nil
      end

    if origin && !CodePuppyControlWeb.Plugs.CORS.is_allowed_origin?(origin) do
      Logger.warning("UserSocket: origin not allowed - #{inspect(origin)}")
      {:error, :origin_not_allowed}
    else
      token = params["token"]

      case authenticate(token) do
        {:ok, session_id} ->
          Logger.debug("UserSocket: authenticated session #{session_id}")

          socket =
            socket
            |> assign(:connected_at, DateTime.utc_now())
            |> assign(:connect_info, connect_info)
            |> assign(:client_params, params)
            |> assign(:verified_session_id, session_id)

          # Emit WebSocket connect telemetry
          Telemetry.websocket_connect(socket.id, connect_info[:transport], params)

          {:ok, socket}

        {:error, :dev_mode} ->
          Logger.debug("UserSocket: no secret configured, accepting connection (dev mode)")

          socket =
            socket
            |> assign(:connected_at, DateTime.utc_now())
            |> assign(:connect_info, connect_info)
            |> assign(:client_params, params)
            |> assign(:verified_session_id, nil)

          # Emit WebSocket connect telemetry
          Telemetry.websocket_connect(socket.id, connect_info[:transport], params)

          {:ok, socket}

        {:error, reason} ->
          Logger.warning("UserSocket: authentication failed - #{inspect(reason)}")
          {:error, :invalid_token}
      end
    end
  end

  @doc """
  Return the socket ID for identifying the socket server side.

  Returns a session-based ID for authenticated sockets, enabling targeted
  broadcasts to specific sessions. Returns nil in dev mode.
  """
  @impl true
  def id(socket) do
    case socket.assigns.verified_session_id do
      nil -> nil
      session_id -> "session:#{session_id}"
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Dev mode: no secret configured, accept all connections
  defp authenticate(token) do
    case websocket_secret() do
      nil -> {:error, :dev_mode}
      secret -> do_authenticate(token, secret)
    end
  end

  defp do_authenticate(nil, _secret), do: {:error, :missing_token}

  defp do_authenticate(token, secret) do
    case Phoenix.Token.verify(socket_impl(), secret, token, max_age: @token_max_age) do
      {:ok, session_id} -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp websocket_secret do
    Application.get_env(:code_puppy_control, :websocket_secret) ||
      System.get_env("PUP_WEBSOCKET_SECRET")
  end

  # Socket implementation for Phoenix.Token - uses endpoint module
  defp socket_impl do
    CodePuppyControlWeb.Endpoint
  end
end
