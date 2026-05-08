defmodule CodePuppyControl.Auth.ChatGptOAuthTest do
  use ExUnit.Case, async: false
  alias CodePuppyControl.Auth.ChatGptOAuth

  describe "prepare_oauth_context/0" do
    test "generates valid PKCE context" do
      ctx = ChatGptOAuth.prepare_oauth_context()
      assert byte_size(ctx.state) == 64
      assert byte_size(ctx.code_verifier) == 128
      assert byte_size(ctx.code_challenge) > 0
      assert ctx.redirect_uri == nil
      assert ctx.expires_at > ctx.created_at
    end

    test "different calls produce different states" do
      ctx1 = ChatGptOAuth.prepare_oauth_context()
      ctx2 = ChatGptOAuth.prepare_oauth_context()
      assert ctx1.state != ctx2.state
      assert ctx1.code_verifier != ctx2.code_verifier
    end
  end

  describe "assign_redirect_uri/2" do
    test "assigns redirect URI on correct port" do
      ctx = ChatGptOAuth.prepare_oauth_context()
      result = ChatGptOAuth.assign_redirect_uri(ctx, 1455)
      assert result.redirect_uri == "http://localhost:1455/auth/callback"
    end

    test "raises on wrong port" do
      ctx = ChatGptOAuth.prepare_oauth_context()

      assert_raise RuntimeError, fn ->
        ChatGptOAuth.assign_redirect_uri(ctx, 9999)
      end
    end
  end

  describe "build_authorization_url/1" do
    test "builds valid URL with PKCE params" do
      ctx = ChatGptOAuth.prepare_oauth_context() |> ChatGptOAuth.assign_redirect_uri(1455)
      url = ChatGptOAuth.build_authorization_url(ctx)
      assert String.starts_with?(url, "https://auth.openai.com/oauth/authorize?")
      assert String.contains?(url, "code_challenge=")
      assert String.contains?(url, "code_challenge_method=S256")
      assert String.contains?(url, "response_type=code")
      assert String.contains?(url, "state=")
    end

    test "raises without redirect URI" do
      ctx = ChatGptOAuth.prepare_oauth_context()

      assert_raise RuntimeError, fn ->
        ChatGptOAuth.build_authorization_url(ctx)
      end
    end
  end

  describe "parse_jwt_claims/1" do
    test "parses valid JWT" do
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(Jason.encode!(%{"exp" => 1_234_567_890, "sub" => "test"}),
          padding: false
        )

      sig = Base.url_encode64("signature", padding: false)
      token = header <> "." <> payload <> "." <> sig
      result = ChatGptOAuth.parse_jwt_claims(token)
      assert result["exp"] == 1_234_567_890
      assert result["sub"] == "test"
    end

    test "returns nil for invalid token" do
      assert ChatGptOAuth.parse_jwt_claims("not-a-jwt") == nil
      assert ChatGptOAuth.parse_jwt_claims("") == nil
      assert ChatGptOAuth.parse_jwt_claims(nil) == nil
    end
  end

  describe "blocked_model?/1" do
    test "blocks known stale models" do
      assert ChatGptOAuth.blocked_model?("gpt-5.2") == true
      assert ChatGptOAuth.blocked_model?("gpt-4o") == true
      assert ChatGptOAuth.blocked_model?("gpt-5.1-codex") == true
    end

    test "allows current models" do
      assert ChatGptOAuth.blocked_model?("gpt-5.4") == false
      assert ChatGptOAuth.blocked_model?("gpt-5.3-codex") == false
    end

    test "handles prefixed names" do
      assert ChatGptOAuth.blocked_model?("chatgpt-gpt-5.2") == true
      assert ChatGptOAuth.blocked_model?("chatgpt-gpt-5.4") == false
    end
  end

  describe "default_models/0" do
    test "returns non-empty list of current models" do
      models = ChatGptOAuth.default_models()
      assert "gpt-5.4" in models
      assert "gpt-5.3-codex" in models
      refute "gpt-5.2" in models
      refute "gpt-4o" in models
    end
  end

  describe "token storage" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "chatgpt_oauth_test_" <> Integer.to_string(:erlang.unique_integer())
        )

      # Also create a separate "fake legacy" dir to isolate from real ~/.code_puppy
      fake_legacy =
        Path.join(
          System.tmp_dir!(),
          "chatgpt_oauth_test_legacy_" <> Integer.to_string(:erlang.unique_integer())
        )

      File.mkdir_p!(tmp_dir)
      File.mkdir_p!(fake_legacy)

      original_home = System.get_env("PUP_EX_HOME")
      original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      System.put_env("PUP_EX_HOME", tmp_dir)
      Application.put_env(:code_puppy_control, :legacy_home_dir, fake_legacy)

      on_exit(fn ->
        if original_home,
          do: System.put_env("PUP_EX_HOME", original_home),
          else: System.delete_env("PUP_EX_HOME")

        case original_legacy do
          nil -> Application.delete_env(:code_puppy_control, :legacy_home_dir)
          v -> Application.put_env(:code_puppy_control, :legacy_home_dir, v)
        end

        File.rm_rf!(tmp_dir)
        File.rm_rf!(fake_legacy)
      end)

      :ok
    end

    test "save and load tokens round-trip" do
      tokens = %{"access_token" => "test_token", "refresh_token" => "test_refresh"}
      :ok = ChatGptOAuth.save_tokens(tokens)
      loaded = ChatGptOAuth.load_stored_tokens()
      assert loaded["access_token"] == "test_token"
      assert loaded["refresh_token"] == "test_refresh"
    end

    test "clear_stored_tokens removes the file" do
      :ok = ChatGptOAuth.save_tokens(%{"access_token" => "to_be_cleared"})
      :ok = ChatGptOAuth.clear_stored_tokens()
      assert ChatGptOAuth.load_stored_tokens() == nil
    end

    test "load_stored_tokens returns nil when no file" do
      assert ChatGptOAuth.load_stored_tokens() == nil
    end
  end

  describe "config/0" do
    test "returns expected OAuth configuration" do
      cfg = ChatGptOAuth.config()
      assert cfg.issuer == "https://auth.openai.com"
      assert cfg.required_port == 1455
      assert cfg.prefix == "chatgpt-"
    end
  end

  # ==========================================================================
  # Legacy Fallback Tests (READ-ONLY bridge, ADR-003 compliant)
  # ==========================================================================

  describe "legacy token fallback (read-only)" do
    setup do
      # Create separate temp dirs for Elixir home and legacy home
      ex_home =
        Path.join(
          System.tmp_dir!(),
          "chatgpt_oauth_ex_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      legacy_home =
        Path.join(
          System.tmp_dir!(),
          "chatgpt_oauth_legacy_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(Path.join(ex_home, "auth"))
      File.mkdir_p!(legacy_home)

      prev_ex_home = System.get_env("PUP_EX_HOME")
      prev_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)

      System.put_env("PUP_EX_HOME", ex_home)
      Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)

      on_exit(fn ->
        case prev_ex_home do
          nil -> System.delete_env("PUP_EX_HOME")
          v -> System.put_env("PUP_EX_HOME", v)
        end

        case prev_legacy do
          nil -> Application.delete_env(:code_puppy_control, :legacy_home_dir)
          v -> Application.put_env(:code_puppy_control, :legacy_home_dir, v)
        end

        File.rm_rf(ex_home)
        File.rm_rf(legacy_home)
      end)

      {:ok, ex_home: ex_home, legacy_home: legacy_home}
    end

    test "load_stored_tokens/0 falls back to legacy when Elixir file absent", %{
      legacy_home: legacy_home
    } do
      # Write token to legacy location only
      legacy_token_data = %{"access_token" => "legacy-token-123", "account_id" => "acct-legacy"}
      File.write!(Path.join(legacy_home, "chatgpt_oauth.json"), Jason.encode!(legacy_token_data))

      # Should find the legacy token
      loaded = ChatGptOAuth.load_stored_tokens()
      assert loaded != nil
      assert loaded["access_token"] == "legacy-token-123"
      assert loaded["account_id"] == "acct-legacy"
    end

    test "primary Elixir token file wins over legacy fallback", %{
      ex_home: ex_home,
      legacy_home: legacy_home
    } do
      # Write token to legacy location
      legacy_token_data = %{"access_token" => "legacy-token", "account_id" => "acct-legacy"}
      File.write!(Path.join(legacy_home, "chatgpt_oauth.json"), Jason.encode!(legacy_token_data))

      # Write different token to Elixir location
      ex_token_data = %{"access_token" => "ex-token-primary", "account_id" => "acct-ex"}
      auth_dir = Path.join(ex_home, "auth")
      File.mkdir_p!(auth_dir)
      File.write!(Path.join(auth_dir, "chatgpt_oauth.json"), Jason.encode!(ex_token_data))

      # Should load from Elixir location (primary wins)
      loaded = ChatGptOAuth.load_stored_tokens()
      assert loaded["access_token"] == "ex-token-primary"
      assert loaded["account_id"] == "acct-ex"
    end

    test "save_tokens/1 only writes to Elixir path (never legacy)", %{
      ex_home: ex_home,
      legacy_home: legacy_home
    } do
      # Write a legacy token
      legacy_token_data = %{"access_token" => "legacy-token", "account_id" => "acct-old"}
      File.write!(Path.join(legacy_home, "chatgpt_oauth.json"), Jason.encode!(legacy_token_data))

      # Save new tokens via Elixir code
      new_tokens = %{"access_token" => "new-ex-token", "account_id" => "acct-new"}
      :ok = ChatGptOAuth.save_tokens(new_tokens)

      # Verify Elixir file was created
      ex_path = Path.join([ex_home, "auth", "chatgpt_oauth.json"])
      assert File.exists?(ex_path)

      {:ok, saved_data} = File.read(ex_path)
      saved = Jason.decode!(saved_data)
      assert saved["access_token"] == "new-ex-token"

      # Verify legacy file was NOT modified
      legacy_path = Path.join(legacy_home, "chatgpt_oauth.json")
      {:ok, legacy_data} = File.read(legacy_path)
      legacy = Jason.decode!(legacy_data)
      assert legacy["access_token"] == "legacy-token"
    end

    test "clear_stored_tokens/0 only removes Elixir file (never legacy)", %{
      ex_home: ex_home,
      legacy_home: legacy_home
    } do
      # Write tokens to both locations
      auth_dir = Path.join(ex_home, "auth")
      File.mkdir_p!(auth_dir)

      File.write!(
        Path.join(auth_dir, "chatgpt_oauth.json"),
        Jason.encode!(%{"access_token" => "ex"})
      )

      legacy_token_data = %{"access_token" => "legacy-token", "account_id" => "acct-legacy"}
      File.write!(Path.join(legacy_home, "chatgpt_oauth.json"), Jason.encode!(legacy_token_data))

      # Clear stored tokens
      :ok = ChatGptOAuth.clear_stored_tokens()

      # Elixir file should be gone
      ex_path = Path.join([ex_home, "auth", "chatgpt_oauth.json"])
      refute File.exists?(ex_path)

      # Legacy file should still exist
      legacy_path = Path.join(legacy_home, "chatgpt_oauth.json")
      assert File.exists?(legacy_path)

      # After clearing Elixir tokens, fallback to legacy should still work
      loaded = ChatGptOAuth.load_stored_tokens()
      assert loaded["access_token"] == "legacy-token"
    end

    test "load_stored_tokens/0 returns nil when both locations empty", _context do
      # No tokens anywhere
      assert ChatGptOAuth.load_stored_tokens() == nil
    end
  end
end
