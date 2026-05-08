defmodule CodePuppyControlWeb.Plugs.CORSTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias CodePuppyControlWeb.Plugs.CORS

  describe "is_allowed_origin?/1" do
    test "rejects nil origin" do
      refute CORS.is_allowed_origin?(nil)
    end

    test "allows localhost origins on default ports" do
      assert CORS.is_allowed_origin?("http://localhost:8765")
      assert CORS.is_allowed_origin?("http://localhost:3000")
      assert CORS.is_allowed_origin?("http://localhost:5173")
      assert CORS.is_allowed_origin?("https://localhost:8080")
    end

    test "allows 127.0.0.1 origins on default ports" do
      assert CORS.is_allowed_origin?("http://127.0.0.1:8765")
      assert CORS.is_allowed_origin?("https://127.0.0.1:3000")
    end

    test "allows IPv6 loopback origins" do
      assert CORS.is_allowed_origin?("http://[::1]:8765")
      assert CORS.is_allowed_origin?("https://[::1]:3000")
    end

    test "allows localhost origins on any port via structural check" do
      # Python's `is_trusted_origin` allows any port on loopback hosts
      assert CORS.is_allowed_origin?("http://localhost:9999")
      assert CORS.is_allowed_origin?("http://127.0.0.1:4321")
      assert CORS.is_allowed_origin?("https://localhost:65535")
    end

    test "allows localhost without port" do
      assert CORS.is_allowed_origin?("http://localhost")
      assert CORS.is_allowed_origin?("https://127.0.0.1")
    end

    test "rejects non-loopback origins" do
      refute CORS.is_allowed_origin?("http://evil.example.com")
      refute CORS.is_allowed_origin?("https://192.168.1.1:8080")
    end

    test "rejects origins with non-http schemes" do
      refute CORS.is_allowed_origin?("ftp://localhost:21")
      refute CORS.is_allowed_origin?("ws://localhost:8765")
    end
  end

  describe "is_allowed_origin?/1 — env var override" do
    test "honours PUP_ALLOWED_ORIGINS" do
      original = System.get_env("PUP_ALLOWED_ORIGINS")
      System.put_env("PUP_ALLOWED_ORIGINS", "http://custom.example.com:9000, http://other.local")

      try do
        assert CORS.is_allowed_origin?("http://custom.example.com:9000")
        assert CORS.is_allowed_origin?("http://other.local")
      after
        if original,
          do: System.put_env("PUP_ALLOWED_ORIGINS", original),
          else: System.delete_env("PUP_ALLOWED_ORIGINS")
      end
    end

    test "honours CODE_PUPPY_ALLOWED_ORIGINS as fallback" do
      original_pup = System.get_env("PUP_ALLOWED_ORIGINS")
      original_legacy = System.get_env("CODE_PUPPY_ALLOWED_ORIGINS")
      System.delete_env("PUP_ALLOWED_ORIGINS")
      System.put_env("CODE_PUPPY_ALLOWED_ORIGINS", "http://legacy.example.com:7777")

      try do
        assert CORS.is_allowed_origin?("http://legacy.example.com:7777")
      after
        if original_pup,
          do: System.put_env("PUP_ALLOWED_ORIGINS", original_pup),
          else: System.delete_env("PUP_ALLOWED_ORIGINS")

        if original_legacy,
          do: System.put_env("CODE_PUPPY_ALLOWED_ORIGINS", original_legacy),
          else: System.delete_env("CODE_PUPPY_ALLOWED_ORIGINS")
      end
    end
  end

  describe "plug call/2" do
    test "passes through when no Origin header" do
      conn = build_conn(:get, "/")
      result = CORS.call(conn, CORS.init([]))
      refute result.halted
    end

    test "adds CORS headers for allowed origins" do
      conn =
        build_conn(:get, "/")
        |> Plug.Conn.put_req_header("origin", "http://localhost:8765")

      result = CORS.call(conn, CORS.init([]))
      refute result.halted

      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") ==
               ["http://localhost:8765"]

      assert Plug.Conn.get_resp_header(result, "access-control-allow-credentials") ==
               ["true"]
    end

    test "responds to preflight OPTIONS with 204" do
      conn =
        build_conn(:options, "/")
        |> Plug.Conn.put_req_header("origin", "http://localhost:8765")

      result = CORS.call(conn, CORS.init([]))
      assert result.halted
      assert result.status == 204
    end

    test "halts with 403 for disallowed origins on regular requests" do
      conn =
        build_conn(:get, "/")
        |> Plug.Conn.put_req_header("origin", "http://evil.example.com")

      result = CORS.call(conn, CORS.init([]))
      assert result.halted
      assert result.status == 403
      # No CORS headers should be set for disallowed origins
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == []
    end

    test "halts with 403 for disallowed origins on preflight OPTIONS" do
      conn =
        build_conn(:options, "/")
        |> Plug.Conn.put_req_header("origin", "http://evil.example.com")

      result = CORS.call(conn, CORS.init([]))
      assert result.halted
      assert result.status == 403
    end

    test "same-origin request (no Origin header) passes through unchecked" do
      conn = build_conn(:post, "/api/runs")
      result = CORS.call(conn, CORS.init([]))
      refute result.halted
    end
  end

  describe "get_allowed_origins/0" do
    test "returns default origins when no env var set" do
      original_pup = System.get_env("PUP_ALLOWED_ORIGINS")
      original_legacy = System.get_env("CODE_PUPPY_ALLOWED_ORIGINS")
      System.delete_env("PUP_ALLOWED_ORIGINS")
      System.delete_env("CODE_PUPPY_ALLOWED_ORIGINS")

      try do
        origins = CORS.get_allowed_origins()
        assert is_list(origins)
        assert length(origins) > 0
        # Should include default ports
        assert "http://localhost:8765" in origins
        assert "http://127.0.0.1:3000" in origins
      after
        if original_pup,
          do: System.put_env("PUP_ALLOWED_ORIGINS", original_pup),
          else: System.delete_env("PUP_ALLOWED_ORIGINS")

        if original_legacy,
          do: System.put_env("CODE_PUPPY_ALLOWED_ORIGINS", original_legacy),
          else: System.delete_env("CODE_PUPPY_ALLOWED_ORIGINS")
      end
    end
  end
end
