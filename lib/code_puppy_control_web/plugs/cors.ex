defmodule CodePuppyControlWeb.Plugs.CORS do
  @moduledoc """
  CORS plug for local API origin validation.

  Mirrors the Python `api/security.py` CORS middleware and origin
  enforcement logic. Even though the server is intended for localhost-only
  use, a browser visiting an untrusted site while the server is running
  could otherwise drive endpoints via CORS-permissive XHR or cross-origin
  WebSocket upgrades.

  ## Origin allow-list

  Origins are allowed if any of these conditions hold:

  1. The origin exactly matches an entry in the configured allow-list
     (from `PUP_ALLOWED_ORIGINS` or legacy `CODE_PUPPY_ALLOWED_ORIGINS`).
  2. The origin's host is a loopback address (`localhost`, `127.0.0.1`,
     `::1`) with an `http` or `https` scheme, regardless of port.

  ## Default origins

  When no env var is set, a set of localhost origins on common dev ports
  is generated:

  - `http(s)://localhost[:port]`
  - `http(s)://127.0.0.1[:port]`
  - `http(s)://[::1][:port]`

  Default ports: 8765, 3000, 5173, 8000, 8080

  ## Configuration

      config :code_puppy_control, CodePuppyControlWeb.Plugs.CORS,
        expose_headers: ["x-request-id"]

  ## Environment variables

  | Variable                       | Purpose                             |
  |--------------------------------|-------------------------------------|
  | `PUP_ALLOWED_ORIGINS`          | Comma-separated allowed origins (preferred) |
  | `CODE_PUPPY_ALLOWED_ORIGINS`   | Comma-separated allowed origins (legacy) |

  ## Usage in endpoint

      plug CodePuppyControlWeb.Plugs.CORS
  """

  import Plug.Conn

  @default_ports ~w(8765 3000 5173 8000 8080)
  @default_hosts ~w(localhost 127.0.0.1)
  @ipv6_hosts ~w([::1])
  @local_schemes ~w(http https)

  @doc false
  def init(opts) do
    Keyword.merge(
      [
        expose_headers: ["x-request-id"],
        allow_headers: [
          "authorization",
          "content-type",
          "accept",
          "origin",
          "x-request-id",
          "x-forwarded-for"
        ],
        allow_methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        max_age: 86400
      ],
      opts
    )
  end

  @doc """
  Plug callback — handles CORS preflight and origin validation.

  For preflight (OPTIONS) requests, responds immediately with CORS headers.
  For other requests, adds CORS headers and validates the origin.
  """
  def call(conn, opts) do
    origin = get_req_header(conn, "origin") |> List.first()

    if is_nil(origin) do
      # No Origin header — not a CORS request (same-origin or non-browser), pass through
      conn
    else
      if is_allowed_origin?(origin) do
        conn
        |> put_cors_headers(origin, opts)
        |> maybe_preflight_response()
      else
        # Origin not allowed — reject with 403 immediately
        # This prevents cross-origin attacks: a browser visiting an untrusted
        # site must NOT be able to drive our endpoints.
        conn
        |> send_resp(403, "CORS forbidden")
        |> halt()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Origin validation — shared with WebSocket origin check
  # ---------------------------------------------------------------------------

  @doc """
  Check if an origin is in the allow-list.

  This function is also usable by the UserSocket `:connect` callback
  for WebSocket origin enforcement.

  Returns `true` if the origin is trusted, `false` otherwise.
  A `nil` origin is always rejected (matching Python's `is_trusted_origin`).
  """
  @spec is_allowed_origin?(String.t() | nil) :: boolean()
  def is_allowed_origin?(nil), do: false

  def is_allowed_origin?(origin) when is_binary(origin) do
    allowed = get_allowed_origins()

    # Literal match against configured list
    if origin in allowed do
      true
    else
      # Structural check: any http(s) origin pointing at a loopback host
      # is trusted regardless of port
      structural_loopback_check?(origin)
    end
  end

  @doc """
  Get the list of allowed origins.

  Honours the `PUP_ALLOWED_ORIGINS` (or legacy `CODE_PUPPY_ALLOWED_ORIGINS`)
  environment variable. Falls back to a set of localhost origins on common
  dev ports.
  """
  @spec get_allowed_origins() :: [String.t()]
  def get_allowed_origins do
    override =
      System.get_env("PUP_ALLOWED_ORIGINS") ||
        System.get_env("CODE_PUPPY_ALLOWED_ORIGINS")

    if override do
      override
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))
    else
      build_default_origins()
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp put_cors_headers(conn, origin, opts) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header(
      "access-control-expose-headers",
      Enum.join(opts[:expose_headers], ", ")
    )
    |> put_resp_header(
      "access-control-allow-headers",
      Enum.join(opts[:allow_headers], ", ")
    )
    |> put_resp_header(
      "access-control-allow-methods",
      Enum.join(opts[:allow_methods], ", ")
    )
    |> put_resp_header("access-control-max-age", to_string(opts[:max_age]))
  end

  defp maybe_preflight_response(conn) do
    if conn.method == "OPTIONS" do
      conn
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end

  defp structural_loopback_check?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host}
      when scheme in @local_schemes ->
        loopback_host?(host)

      _ ->
        false
    end
  end

  defp loopback_host?(host) when is_binary(host) do
    # Normalize IPv6 bracket notation: [::1] -> ::1
    normalized = String.trim(host, "[]")

    normalized in @default_hosts or normalized in @ipv6_hosts or
      String.downcase(normalized) == "localhost"
  end

  defp loopback_host?(_), do: false

  defp build_default_origins do
    for scheme <- @local_schemes,
        host <- @default_hosts ++ @ipv6_hosts,
        port <- [nil | @default_ports] do
      case port do
        nil -> "#{scheme}://#{host}"
        p -> "#{scheme}://#{host}:#{p}"
      end
    end
  end
end
