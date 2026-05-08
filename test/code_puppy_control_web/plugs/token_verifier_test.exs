defmodule CodePuppyControlWeb.Plugs.TokenVerifierTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias CodePuppyControlWeb.Plugs.TokenVerifier

  describe "is_loopback_ip?/1" do
    test "recognizes IPv4 loopback" do
      assert TokenVerifier.is_loopback_ip?({127, 0, 0, 1})
      assert TokenVerifier.is_loopback_ip?({127, 255, 255, 255})
      assert TokenVerifier.is_loopback_ip?({127, 0, 0, 42})
    end

    test "recognizes IPv6 loopback" do
      assert TokenVerifier.is_loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "rejects non-loopback IPs" do
      refute TokenVerifier.is_loopback_ip?({192, 168, 1, 1})
      refute TokenVerifier.is_loopback_ip?({10, 0, 0, 1})
      refute TokenVerifier.is_loopback_ip?({172, 16, 0, 1})
    end
  end

  describe "is_loopback_host?/1" do
    test "recognizes loopback addresses" do
      assert TokenVerifier.is_loopback_host?("127.0.0.1")
      assert TokenVerifier.is_loopback_host?("::1")
      assert TokenVerifier.is_loopback_host?("localhost")
    end

    test "rejects non-loopback addresses" do
      refute TokenVerifier.is_loopback_host?("192.168.1.1")
      refute TokenVerifier.is_loopback_host?("10.0.0.1")
      refute TokenVerifier.is_loopback_host?("example.com")
    end

    test "handles nil" do
      refute TokenVerifier.is_loopback_host?(nil)
    end
  end

  describe "verify_token/2 — loopback bypass" do
    test "allows loopback clients without token (boolean form)" do
      original_require = System.get_env("PUP_REQUIRE_TOKEN")
      original_require_legacy = System.get_env("CODE_PUPPY_REQUIRE_TOKEN")
      System.delete_env("PUP_REQUIRE_TOKEN")
      System.delete_env("CODE_PUPPY_REQUIRE_TOKEN")

      try do
        assert TokenVerifier.verify_token(nil, true) == :ok
      after
        if original_require, do: System.put_env("PUP_REQUIRE_TOKEN", original_require)

        if original_require_legacy,
          do: System.put_env("CODE_PUPPY_REQUIRE_TOKEN", original_require_legacy)
      end
    end

    test "allows loopback clients without token (string form)" do
      original_require = System.get_env("PUP_REQUIRE_TOKEN")
      original_require_legacy = System.get_env("CODE_PUPPY_REQUIRE_TOKEN")
      System.delete_env("PUP_REQUIRE_TOKEN")
      System.delete_env("CODE_PUPPY_REQUIRE_TOKEN")

      try do
        assert TokenVerifier.verify_token(nil, "127.0.0.1") == :ok
        assert TokenVerifier.verify_token(nil, "::1") == :ok
        assert TokenVerifier.verify_token(nil, "localhost") == :ok
      after
        if original_require, do: System.put_env("PUP_REQUIRE_TOKEN", original_require)

        if original_require_legacy,
          do: System.put_env("CODE_PUPPY_REQUIRE_TOKEN", original_require_legacy)
      end
    end

    test "rejects non-loopback clients without token when no token configured" do
      original = System.get_env("PUP_API_TOKEN")
      original_legacy = System.get_env("CODE_PUPPY_API_TOKEN")
      System.delete_env("PUP_API_TOKEN")
      System.delete_env("CODE_PUPPY_API_TOKEN")

      try do
        assert TokenVerifier.verify_token(nil, false) == {:error, :forbidden}
        assert TokenVerifier.verify_token(nil, "192.168.1.1") == {:error, :forbidden}
      after
        if original, do: System.put_env("PUP_API_TOKEN", original)
        if original_legacy, do: System.put_env("CODE_PUPPY_API_TOKEN", original_legacy)
      end
    end

    test "rejects non-loopback clients with missing token when token configured" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "secret-token-123")

      try do
        assert TokenVerifier.verify_token(nil, "192.168.1.1") == {:error, :unauthorized}
      after
        if original, do: System.put_env("PUP_API_TOKEN", original)
        if is_nil(original), do: System.delete_env("PUP_API_TOKEN")
      end
    end

    test "rejects non-loopback clients with wrong token" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "secret-token-123")

      try do
        assert TokenVerifier.verify_token("wrong-token", "192.168.1.1") == {:error, :unauthorized}
      after
        if original, do: System.put_env("PUP_API_TOKEN", original)
        if is_nil(original), do: System.delete_env("PUP_API_TOKEN")
      end
    end

    test "accepts non-loopback clients with correct token" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "secret-token-123")

      try do
        assert TokenVerifier.verify_token("secret-token-123", "192.168.1.1") == :ok
      after
        if original, do: System.put_env("PUP_API_TOKEN", original)
        if is_nil(original), do: System.delete_env("PUP_API_TOKEN")
      end
    end
  end

  describe "verify_token/2 — strict mode" do
    test "requires token for loopback clients in strict mode" do
      original_require = System.get_env("PUP_REQUIRE_TOKEN")
      original_token = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_REQUIRE_TOKEN", "1")
      System.put_env("PUP_API_TOKEN", "secret-token-123")

      try do
        # No token → unauthorized
        assert TokenVerifier.verify_token(nil, "127.0.0.1") == {:error, :unauthorized}

        # Wrong token → unauthorized
        assert TokenVerifier.verify_token("wrong", "127.0.0.1") == {:error, :unauthorized}

        # Correct token → ok
        assert TokenVerifier.verify_token("secret-token-123", "127.0.0.1") == :ok
      after
        if original_require,
          do: System.put_env("PUP_REQUIRE_TOKEN", original_require),
          else: System.delete_env("PUP_REQUIRE_TOKEN")

        if original_token,
          do: System.put_env("PUP_API_TOKEN", original_token),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end
  end

  describe "verify_token/2 — legacy env vars" do
    test "falls back to CODE_PUPPY_API_TOKEN" do
      original_pup = System.get_env("PUP_API_TOKEN")
      original_legacy = System.get_env("CODE_PUPPY_API_TOKEN")
      System.delete_env("PUP_API_TOKEN")
      System.put_env("CODE_PUPPY_API_TOKEN", "legacy-token-456")

      try do
        assert TokenVerifier.verify_token("legacy-token-456", "192.168.1.1") == :ok
      after
        if original_pup, do: System.put_env("PUP_API_TOKEN", original_pup)

        if original_legacy,
          do: System.put_env("CODE_PUPPY_API_TOKEN", original_legacy),
          else: System.delete_env("CODE_PUPPY_API_TOKEN")
      end
    end

    test "prefers PUP_API_TOKEN over CODE_PUPPY_API_TOKEN" do
      original_pup = System.get_env("PUP_API_TOKEN")
      original_legacy = System.get_env("CODE_PUPPY_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "preferred-token")
      System.put_env("CODE_PUPPY_API_TOKEN", "legacy-token")

      try do
        assert TokenVerifier.verify_token("preferred-token", "192.168.1.1") == :ok

        assert TokenVerifier.verify_token("legacy-token", "192.168.1.1") ==
                 {:error, :unauthorized}
      after
        if original_pup,
          do: System.put_env("PUP_API_TOKEN", original_pup),
          else: System.delete_env("PUP_API_TOKEN")

        if original_legacy,
          do: System.put_env("CODE_PUPPY_API_TOKEN", original_legacy),
          else: System.delete_env("CODE_PUPPY_API_TOKEN")
      end
    end
  end

  describe "verify/1 — from Plug.Conn" do
    test "allows loopback connection without token" do
      original = System.get_env("PUP_REQUIRE_TOKEN")
      System.delete_env("PUP_REQUIRE_TOKEN")

      try do
        conn = %{build_conn() | remote_ip: {127, 0, 0, 1}}

        assert TokenVerifier.verify(conn) == :ok
      after
        if original, do: System.put_env("PUP_REQUIRE_TOKEN", original)
      end
    end

    test "extracts and validates bearer token from Authorization header" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "my-secret-token")

      try do
        conn =
          %{build_conn() | remote_ip: {10, 0, 0, 1}}
          |> Plug.Conn.put_req_header("authorization", "Bearer my-secret-token")

        assert TokenVerifier.verify(conn) == :ok
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end

    test "returns unauthorized for invalid token" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "my-secret-token")

      try do
        conn =
          %{build_conn() | remote_ip: {10, 0, 0, 1}}
          |> Plug.Conn.put_req_header("authorization", "Bearer wrong-token")

        assert TokenVerifier.verify(conn) == {:error, :unauthorized}
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end
  end

  describe "verify/1 — X-Forwarded-For bypass prevention" do
    test "X-Forwarded-For: 127.0.0.1 from non-loopback remote_ip does NOT bypass auth" do
      original = System.get_env("PUP_REQUIRE_TOKEN")
      original_token = System.get_env("PUP_API_TOKEN")
      System.delete_env("PUP_REQUIRE_TOKEN")
      System.delete_env("PUP_API_TOKEN")

      try do
        # A remote client (10.0.0.1) spoofing X-Forwarded-For must NOT
        # be treated as loopback.
        conn =
          %{build_conn() | remote_ip: {10, 0, 0, 1}}
          |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")

        # Without a token configured, non-loopback should get :forbidden
        assert TokenVerifier.verify(conn) == {:error, :forbidden}
      after
        if original, do: System.put_env("PUP_REQUIRE_TOKEN", original)
        if original_token, do: System.put_env("PUP_API_TOKEN", original_token)
        if is_nil(original_token), do: System.delete_env("PUP_API_TOKEN")
      end
    end

    test "X-Forwarded-For spoofing does not grant loopback bypass even with token configured" do
      original = System.get_env("PUP_REQUIRE_TOKEN")
      original_token = System.get_env("PUP_API_TOKEN")
      System.delete_env("PUP_REQUIRE_TOKEN")
      System.put_env("PUP_API_TOKEN", "secret-123")

      try do
        conn =
          %{build_conn() | remote_ip: {10, 0, 0, 1}}
          |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")

        # Spoofed header should not bypass — remote IP is non-loopback
        assert TokenVerifier.verify(conn) == {:error, :unauthorized}
      after
        if original, do: System.put_env("PUP_REQUIRE_TOKEN", original)
        if original_token, do: System.put_env("PUP_API_TOKEN", original_token)
        if is_nil(original_token), do: System.delete_env("PUP_API_TOKEN")
      end
    end
  end

  describe "constant-time comparison" do
    test "correct tokens match" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "a-very-secret-token-value")

      try do
        assert TokenVerifier.verify_token("a-very-secret-token-value", "10.0.0.1") == :ok
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end

    test "different-length tokens are rejected" do
      original = System.get_env("PUP_API_TOKEN")
      System.put_env("PUP_API_TOKEN", "short")

      try do
        assert TokenVerifier.verify_token("much-longer-wrong-token", "10.0.0.1") ==
                 {:error, :unauthorized}
      after
        if original,
          do: System.put_env("PUP_API_TOKEN", original),
          else: System.delete_env("PUP_API_TOKEN")
      end
    end
  end
end
