defmodule CodePuppyControlWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug for API requests requiring authorization.

  This plug verifies that the client is authorized to perform mutating
  operations. It delegates to `TokenVerifier` for the actual token
  validation and to `RateLimiter` for auth failure rate limiting.

  ## Usage in a pipeline

      pipeline :authenticated_api do
        plug :accepts, ["json"]
        plug CodePuppyControlWeb.Plugs.Auth
      end

  ## Security model

  - Loopback clients (127.0.0.1, ::1, localhost) are allowed by default
  - If `PUP_REQUIRE_TOKEN` is set, even loopback clients need a token
  - Non-loopback clients always need a valid bearer token
  - Auth failures are rate-limited: 5 per minute per IP

  ## Responses

  - `200` / `201` — request passes auth
  - `401` — token required but missing or invalid
  - `403` — token not configured for non-loopback client
  - `429` — too many auth failures (rate limited)

  This plug should be applied to all endpoints that perform destructive
  or state-mutating operations (execute commands, modify config, delete
  sessions, etc.).
  """

  import Plug.Conn

  alias CodePuppyControlWeb.Plugs.TokenVerifier
  alias CodePuppyControlWeb.Plugs.RateLimiter

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    case TokenVerifier.verify(conn) do
      :ok ->
        conn

      {:error, :forbidden} ->
        # Check rate limit before responding
        RateLimiter.record_failure(conn)

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(
          403,
          Jason.encode!(%{
            error: "API token not configured. Set PUP_API_TOKEN env var."
          })
        )
        |> halt()

      {:error, :unauthorized} ->
        # Record the auth failure for rate limiting
        RateLimiter.record_failure(conn)

        # Check if rate limited
        case RateLimiter.check_rate(conn) do
          {:ok, _} ->
            conn
            |> put_resp_header("content-type", "application/json")
            |> send_resp(
              401,
              Jason.encode!(%{error: "Invalid or missing API token"})
            )
            |> halt()

          {:error, :rate_limited, retry_after} ->
            conn
            |> put_resp_header("content-type", "application/json")
            |> put_resp_header("retry-after", to_string(retry_after))
            |> send_resp(
              429,
              Jason.encode!(%{
                error: "Too many authentication failures. Please try again later.",
                retry_after: retry_after
              })
            )
            |> halt()
        end
    end
  end
end
