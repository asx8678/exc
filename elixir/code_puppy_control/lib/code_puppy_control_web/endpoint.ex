defmodule CodePuppyControlWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for CodePuppy Control Plane API.

  API-only endpoint - no HTML, assets, or sessions.
  """

  use Phoenix.Endpoint, otp_app: :code_puppy_control

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_code_puppy_control_key",
    signing_salt: "changeme",
    same_site: "Lax"
  ]

  # LiveView socket - disabled when LiveView is not available
  if Code.ensure_loaded?(Phoenix.LiveView.Socket) do
    socket "/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [:peer_data, session: @session_options]],
      longpoll: [connect_info: [:peer_data, session: @session_options]]
  end

  # WebSocket socket for real-time events (SessionChannel, RunChannel)
  socket "/socket", CodePuppyControlWeb.UserSocket,
    websocket: [connect_info: [:peer_data, :trace_context_headers, :x_headers, :uri]],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  # plug Plug.Static,
  # at: "/",
  # from: :code_puppy_control,
  # gzip: false,
  # only: ~w(assets fonts images favicon.ico robots.txt)

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :code_puppy_control
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  # Security middleware
  # Order: CORS → RateLimiter → Router → Auth (per-pipeline in router)
  plug CodePuppyControlWeb.Plugs.CORS
  plug CodePuppyControlWeb.Plugs.RateLimiter

  plug CodePuppyControlWeb.Router
end
