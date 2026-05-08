defmodule CodePuppyControlWeb.Plugs.AuthTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias CodePuppyControlWeb.Plugs.Auth
  alias CodePuppyControlWeb.Plugs.RateLimiter

  setup do
    RateLimiter.create_table()
    RateLimiter.reset()

    on_exit(fn ->
      RateLimiter.reset()
    end)

    :ok
  end

  describe "plug call/2 — loopback bypass" do
    test "allows loopback connections without token" do
      original_require = System.get_env("PUP_REQUIRE_TOKEN")
      System.delete_env("PUP_REQUIRE_TOKEN")

      try do
        conn = conn_for_ip({127, 0, 0, 1})

        result = Auth.call(conn, [])
        refute result.halted
      after
        if original_require, do: System.put_env("PUP_REQUIRE_TOKEN", original_require)
      end
    end
  end

  describe "plug call/2 — token required" do
    test "rejects non-loopback without token when token configured" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "secret-123")

      try do
        conn = conn_for_ip({10, 0, 0, 1})

        result = Auth.call(conn, [])
        assert result.halted
        assert result.status == 401
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end

    test "allows non-loopback with valid token" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "secret-123")

      try do
        conn =
          conn_for_ip({10, 0, 0, 1})
          |> Plug.Conn.put_req_header("authorization", "Bearer secret-123")

        result = Auth.call(conn, [])
        refute result.halted
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end

    test "returns 403 when token not configured for non-loopback" do
      original = System.get_env("PUP_API_TOKEN")
      original_legacy = System.get_env("CODE_PUPPY_API_TOKEN")
      System.delete_env("PUP_API_TOKEN")
      System.delete_env("CODE_PUPPY_API_TOKEN")

      try do
        conn = conn_for_ip({10, 0, 0, 1})

        result = Auth.call(conn, [])
        assert result.halted
        assert result.status == 403
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")

        if original_legacy,
          do: System.put_env("CODE_PUPPY_API_TOKEN", original_legacy),
          else: System.delete_env("CODE_PUPPY_API_TOKEN")
      end
    end

    test "returns 401 for invalid token" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "secret-123")

      try do
        conn =
          conn_for_ip({10, 0, 0, 1})
          |> Plug.Conn.put_req_header("authorization", "Bearer wrong-token")

        result = Auth.call(conn, [])
        assert result.halted
        assert result.status == 401
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end
  end

  describe "plug call/2 — strict mode" do
    test "requires token even for loopback in strict mode" do
      original_require = System.get_env("PUP_REQUIRE_TOKEN")
      original_require_legacy = System.get_env("CODE_PUPPY_REQUIRE_TOKEN")
      original_token = System.get_env("PUP_API_TOKEN")
      System.delete_env("CODE_PUPPY_REQUIRE_TOKEN")
      System.put_env("PUP_REQUIRE_TOKEN", "1")
      System.put_env("PUP_API_TOKEN", "strict-token")

      try do
        conn = conn_for_ip({127, 0, 0, 1})

        result = Auth.call(conn, [])
        assert result.halted
        assert result.status == 401

        # With correct token
        conn_with_token =
          conn_for_ip({127, 0, 0, 1})
          |> Plug.Conn.put_req_header("authorization", "Bearer strict-token")

        result_ok = Auth.call(conn_with_token, [])
        refute result_ok.halted
      after
        if original_require,
          do: System.put_env("PUP_REQUIRE_TOKEN", original_require),
          else: System.delete_env("PUP_REQUIRE_TOKEN")

        if original_require_legacy,
          do: System.put_env("CODE_PUPPY_REQUIRE_TOKEN", original_require_legacy),
          else: System.delete_env("CODE_PUPPY_REQUIRE_TOKEN")

        if original_token,
          do: System.put_env("PUP_API_TOKEN", original_token),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end
  end

  describe "plug call/2 — rate limiting integration" do
    test "returns 429 after too many auth failures" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "secret-123")

      try do
        conn_fn = fn ->
          conn_for_ip({10, 0, 0, 1})
          |> Plug.Conn.put_req_header("authorization", "Bearer wrong")
        end

        # First 5 attempts should return 401
        for _ <- 1..5 do
          result = Auth.call(conn_fn.(), [])
          assert result.halted
          # Could be 401 or 429 depending on timing
          assert result.status in [401, 429]
        end

        # Next attempt should be rate limited (429)
        result = Auth.call(conn_fn.(), [])
        assert result.halted
        assert result.status == 429
        assert Plug.Conn.get_resp_header(result, "retry-after") != []
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp conn_for_ip(ip) when is_tuple(ip) do
    %{build_conn(:post, "/api/runs") | remote_ip: ip}
  end
end
