defmodule CodePuppyControlWeb.Plugs.TokenVerifier do
  @moduledoc """
  Shared token verification logic for HTTP and WebSocket authentication.

  This module is the single source of truth for bearer-token validation,
  usable by both the Auth plug (HTTP pipeline) and the UserSocket
  `:connect` callback (WebSocket).

  ## Security model (mirrors Python `api/security.py`)

  1. Loopback clients (`127.x.x.x`, `::1`) are allowed by default,
     detected **only** from `conn.remote_ip` — the `X-Forwarded-For`
     header is NEVER trusted (it can be spoofed).
  2. If `PUP_REQUIRE_TOKEN` (or legacy `CODE_PUPPY_REQUIRE_TOKEN`) is set,
     even loopback clients must present a valid token (strict mode).
  3. Non-loopback clients always need a valid token.
  4. Tokens are validated against `PUP_API_TOKEN` (or legacy `CODE_PUPPY_API_TOKEN`)
     using constant-time comparison to prevent timing attacks.

  ## Environment variables

  | Variable                     | Purpose                                |
  |------------------------------|----------------------------------------|
  | `PUP_API_TOKEN`              | Expected bearer token (preferred)       |
  | `CODE_PUPPY_API_TOKEN`       | Expected bearer token (legacy fallback) |
  | `PUP_REQUIRE_TOKEN`          | Strict mode: require token even on loopback |
  | `CODE_PUPPY_REQUIRE_TOKEN`   | Legacy strict mode                     |

  ## Usage

      # In a plug
      case TokenVerifier.verify(conn) do
        :ok -> conn
        {:error, :unauthorized} -> send_resp(conn, 401, "Unauthorized")
        {:error, :forbidden} -> send_resp(conn, 403, "Forbidden")
      end

      # In WebSocket connect/3
      case TokenVerifier.verify_token(token, client_host) do
        :ok -> {:ok, socket}
        {:error, reason} -> {:error, reason}
      end
  """

  @local_hosts MapSet.new(["127.0.0.1", "::1", "localhost"])

  # ---------------------------------------------------------------------------
  # Public API — used by Auth plug
  # ---------------------------------------------------------------------------

  @doc """
  Verify authentication for an HTTP connection.

  Reads the `Authorization: Bearer <token>` header and checks against
  the configured API token. Loopback clients are exempt unless strict
  mode is enabled.

  **Security:** Loopback detection uses `conn.remote_ip` directly —
  the `X-Forwarded-For` header is NEVER trusted, as it can be spoofed
  by any client to bypass authentication.

  Returns:
  - `:ok` — authentication passed
  - `{:error, :unauthorized}` — token required but missing or invalid
  - `{:error, :forbidden}` — token not configured for non-loopback client
  """
  @spec verify(Plug.Conn.t()) :: :ok | {:error, :unauthorized | :forbidden}
  def verify(conn) do
    loopback = is_loopback_ip?(conn.remote_ip)
    token = extract_bearer_token(conn)

    verify_token(token, loopback)
  end

  @doc """
  Verify a token against a client host.

  This is the core verification logic, reusable by both HTTP plugs
  and WebSocket `:connect` callbacks.

  The second argument can be either:
  - A boolean (`true` if the client is loopback) — used by `verify/1`
  - A string host (e.g. `"127.0.0.1"`) — used by WebSocket `:connect`

  Returns:
  - `:ok` — authentication passed
  - `{:error, :unauthorized}` — token required but missing or invalid
  - `{:error, :forbidden}` — no token configured for non-loopback client
  """
  @spec verify_token(String.t() | nil, boolean() | String.t()) ::
          :ok | {:error, :unauthorized | :forbidden}
  def verify_token(token, loopback?) when is_boolean(loopback?) do
    strict_mode = strict_mode?()

    # Loopback access without explicit token requirement
    if loopback? and not strict_mode do
      :ok
    else
      validate_token(token)
    end
  end

  # Legacy string-based overload for WebSocket connect callbacks
  @spec verify_token(String.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :forbidden}
  def verify_token(token, client_host) when is_binary(client_host) do
    verify_token(token, is_loopback_host?(client_host))
  end

  @doc """
  Check if a `conn.remote_ip` tuple is a loopback address.

  **Security:** This uses the BEAM-assigned `remote_ip` directly,
  never the `X-Forwarded-For` header which can be spoofed.
  """
  @spec is_loopback_ip?({integer(), integer(), integer(), integer()} | tuple()) :: boolean()
  def is_loopback_ip?({127, _, _, _}), do: true
  def is_loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def is_loopback_ip?(_), do: false

  @doc """
  Check if a host string is a loopback address.

  Used by WebSocket `:connect` callbacks where only a host string
  is available (not a conn struct with `remote_ip`).
  """
  @spec is_loopback_host?(String.t() | nil) :: boolean()
  def is_loopback_host?(nil), do: false
  def is_loopback_host?(host), do: MapSet.member?(@local_hosts, host)

  @doc """
  Get the configured API token.
  Prefers PUP_API_TOKEN, falls back to CODE_PUPPY_API_TOKEN.
  """
  @spec api_token() :: String.t() | nil
  def api_token do
    System.get_env("PUP_API_TOKEN") || System.get_env("CODE_PUPPY_API_TOKEN")
  end

  @doc """
  Check if strict token mode is enabled.
  Prefers PUP_REQUIRE_TOKEN, falls back to CODE_PUPPY_REQUIRE_TOKEN.
  """
  @spec strict_mode?() :: boolean()
  def strict_mode? do
    value =
      System.get_env("PUP_REQUIRE_TOKEN") ||
        System.get_env("CODE_PUPPY_REQUIRE_TOKEN") ||
        ""

    truthy?(value)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_token(token) do
    expected_token = api_token()

    cond do
      is_nil(expected_token) ->
        {:error, :forbidden}

      is_nil(token) ->
        {:error, :unauthorized}

      not constant_time_equal?(token, expected_token) ->
        {:error, :unauthorized}

      true ->
        :ok
    end
  end

  defp extract_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      [_other] -> nil
      [] -> nil
    end
  end

  # Constant-time comparison to prevent timing attacks.
  # :crypto.hash_equals/2 requires same-length binaries and is OTP 26+.
  # We use a manual XOR-based comparison that is constant-time regardless
  # of string length, and always returns false for different lengths
  # (but does the work to avoid timing leaks).
  defp constant_time_equal?(a, b) when is_binary(a) and is_binary(b) do
    # XOR all byte pairs; if lengths differ, pad the shorter one and
    # ensure the length difference itself contributes a non-zero bit.
    len_a = byte_size(a)
    len_b = byte_size(b)
    max_len = max(len_a, len_b)

    # Pad both to the same length with null bytes
    a_padded = a <> :binary.copy(<<0>>, max_len - len_a)
    b_padded = b <> :binary.copy(<<0>>, max_len - len_b)

    # XOR all bytes; the length difference will be captured via the
    # padding bytes (if strings differ in length, the non-zero padding
    # of the shorter string vs the actual bytes of the longer one
    # will produce a non-zero XOR).
    result =
      :binary.bin_to_list(a_padded)
      |> Enum.zip(:binary.bin_to_list(b_padded))
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)

    # Length mismatch must always fail
    result == 0 and len_a == len_b
  end

  defp constant_time_equal?(_, _), do: false

  # Match Python's truthiness check for env var values
  defp truthy?(value) when is_binary(value) do
    val = String.downcase(String.trim(value))
    val in ["1", "true", "yes"]
  end

  defp truthy?(_), do: false
end
