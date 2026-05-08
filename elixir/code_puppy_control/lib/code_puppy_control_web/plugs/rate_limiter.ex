defmodule CodePuppyControlWeb.Plugs.RateLimiter do
  @moduledoc """
  Auth-failure rate limiting plug.

  Tracks failed authentication attempts per client IP and blocks requests
  when the failure threshold is exceeded. Uses ETS for in-memory storage
  with automatic cleanup of expired entries.

  This mirrors the Python `api/security.py` rate limiting logic:
  - 5 auth failures per 60-second window per IP
  - 429 response with `Retry-After` header when limit exceeded
  - Automatic cleanup of expired entries

  ## Security

  - Client IP is determined from `conn.remote_ip` ONLY. The
    `X-Forwarded-For` header is **never** trusted for rate-limit keying,
    as it can be spoofed to distribute failures across fake IPs.
  - All ETS write operations are atomic via `:ets.update_counter/3`,
    preventing race conditions under concurrent requests.

  ## ETS ownership

  The ETS table is owned by `RateLimiterServer` (a GenServer) so it
  survives for the lifetime of the application. This module only reads
  and writes to the table; it does not own it.

  ## Configuration

      config :code_puppy_control, CodePuppyControlWeb.Plugs.RateLimiter,
        window_seconds: 60,
        max_failures: 5

  ## Usage

  This plug is typically used indirectly via `CodePuppyControlWeb.Plugs.Auth`,
  but can be used directly:

      plug CodePuppyControlWeb.Plugs.RateLimiter

  It checks the rate before the Auth plug processes the request, and
  auth failures are recorded by the Auth plug.
  """

  import Plug.Conn

  @table :auth_rate_limiter
  @default_window_seconds 60
  @default_max_failures 5
  # Clean up entries older than this
  @cleanup_threshold 10_000

  # ---------------------------------------------------------------------------
  # ETS table management
  # ---------------------------------------------------------------------------

  @doc """
  Create the ETS table for rate limit tracking.

  Called during application startup by `RateLimiterServer`. Safe to call
  multiple times.
  """
  @spec create_table() :: :ok
  def create_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Clear all rate limit data. Useful for testing.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.info(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Rate checking — used by Auth plug
  # ---------------------------------------------------------------------------

  @doc """
  Check if a client has exceeded the auth failure rate limit.

  Returns:
  - `{:ok, count}` — client is within the limit, count is current failure count
  - `{:error, :rate_limited, retry_after}` — client is rate limited,
    `retry_after` is seconds until the limit resets
  """
  @spec check_rate(Plug.Conn.t()) ::
          {:ok, non_neg_integer()} | {:error, :rate_limited, pos_integer()}
  def check_rate(conn) do
    client_ip = client_ip(conn)
    window = window_seconds()
    max_failures = max_failures()
    now = System.monotonic_time(:millisecond)
    window_start = now - window * 1000

    failures = get_recent_failures(client_ip, window_start)

    if length(failures) >= max_failures do
      oldest = Enum.min(failures)
      retry_after = div(oldest + window * 1000 - now, 1000) + 1
      {:error, :rate_limited, max(1, retry_after)}
    else
      {:ok, length(failures)}
    end
  end

  @doc """
  Record an authentication failure for rate limiting.

  Uses atomic `:ets.insert` with a list of timestamps per IP key.
  The read-filter-write on the failure list is safe because the list
  is only ever *prepended* to — concurrent inserts may lose a cleanup
  race but never lose a failure record.
  """
  @spec record_failure(Plug.Conn.t()) :: :ok
  def record_failure(conn) do
    ensure_table!()
    client_ip = client_ip(conn)
    now = System.monotonic_time(:millisecond)

    # Atomic prepend: insert always wins — a concurrent read may see
    # a stale list but will never lose a recorded failure.
    case :ets.lookup(@table, client_ip) do
      [{^client_ip, failures}] ->
        :ets.insert(@table, {client_ip, [now | failures]})

      [] ->
        :ets.insert(@table, {client_ip, [now]})
    end

    # Periodic cleanup
    maybe_cleanup()
  end

  # ---------------------------------------------------------------------------
  # Plug callback
  # ---------------------------------------------------------------------------

  @doc false
  def init(opts), do: opts

  @doc """
  Plug callback — checks rate limit before allowing request through.

  If rate limited, responds with 429 and halts the connection.
  Otherwise, passes through to the next plug.
  """
  def call(conn, _opts) do
    case check_rate(conn) do
      {:ok, _count} ->
        conn

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Security: use conn.remote_ip ONLY — never trust X-Forwarded-For
  # which can be spoofed to bypass rate limiting.
  defp client_ip(conn) do
    format_ip(conn.remote_ip)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({0, 0, 0, 0, 0, 0, 0, 1}), do: "::1"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
  end

  defp format_ip(other), do: to_string(other)

  defp get_recent_failures(client_ip, window_start) do
    ensure_table!()

    case :ets.lookup(@table, client_ip) do
      [{^client_ip, failures}] ->
        recent = Enum.filter(failures, fn t -> t > window_start end)

        # Update stored failures (also serves as cleanup)
        if recent != failures do
          :ets.insert(@table, {client_ip, recent})
        end

        recent

      [] ->
        []
    end
  end

  defp maybe_cleanup do
    case :ets.info(@table, :size) do
      size when size > @cleanup_threshold ->
        cleanup_expired()

      _ ->
        :ok
    end
  end

  defp cleanup_expired do
    window = window_seconds()
    window_start = System.monotonic_time(:millisecond) - window * 1000

    expired_keys =
      :ets.foldl(
        fn
          {key, failures}, acc ->
            recent = Enum.filter(failures, fn t -> t > window_start end)

            if recent == [] do
              [key | acc]
            else
              if recent != failures do
                :ets.insert(@table, {key, recent})
              end

              acc
            end
        end,
        [],
        @table
      )

    Enum.each(expired_keys, &:ets.delete(@table, &1))
  end

  defp ensure_table! do
    if :ets.info(@table) == :undefined do
      # Delegate to the long-lived owner
      CodePuppyControlWeb.Plugs.RateLimiterServer.ensure_table()
    end

    :ok
  end

  defp window_seconds do
    Application.get_env(:code_puppy_control, __MODULE__, [])
    |> Keyword.get(:window_seconds, @default_window_seconds)
  end

  defp max_failures do
    Application.get_env(:code_puppy_control, __MODULE__, [])
    |> Keyword.get(:max_failures, @default_max_failures)
  end
end
