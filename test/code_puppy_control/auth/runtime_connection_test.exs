defmodule CodePuppyControl.Auth.RuntimeConnectionTest do
  @moduledoc """
  Focused tests for RuntimeConnection.resolve_chatgpt/1 error semantics.

  Verifies the precision bug fix: when access_token is valid but account_id
  is missing, the error must be :missing_account_id (not :not_authenticated).
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Auth.RuntimeConnection

  # Helper to isolate PUP_EX_HOME + PUP_MACHINE_SECRET_PATH + legacy_home_dir to temp dirs.
  # Optionally writes a ChatGPT OAuth token file when chatgpt_tokens: is provided.
  defp with_pup_ex_home(opts, fun) when is_list(opts) and is_function(fun, 0) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "rc_test_#{:erlang.unique_integer([:positive, :monotonic])}"
      )

    # Separate fake legacy dir to isolate from real ~/.code_puppy
    fake_legacy =
      Path.join(
        System.tmp_dir!(),
        "rc_test_legacy_#{:erlang.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(fake_legacy)

    if token_data = Keyword.get(opts, :chatgpt_tokens) do
      auth_dir = Path.join(tmp_dir, "auth")
      File.mkdir_p!(auth_dir)
      File.write!(Path.join(auth_dir, "chatgpt_oauth.json"), Jason.encode!(token_data))
    end

    secret_path = Path.join(tmp_dir, ".machine_secret")

    prev_ex_home = System.get_env("PUP_EX_HOME")
    prev_secret = System.get_env("PUP_MACHINE_SECRET_PATH")
    prev_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
    System.put_env("PUP_EX_HOME", tmp_dir)
    System.put_env("PUP_MACHINE_SECRET_PATH", secret_path)
    Application.put_env(:code_puppy_control, :legacy_home_dir, fake_legacy)

    try do
      fun.()
    after
      case prev_ex_home do
        nil -> System.delete_env("PUP_EX_HOME")
        v -> System.put_env("PUP_EX_HOME", v)
      end

      case prev_secret do
        nil -> System.delete_env("PUP_MACHINE_SECRET_PATH")
        v -> System.put_env("PUP_MACHINE_SECRET_PATH", v)
      end

      case prev_legacy do
        nil -> Application.delete_env(:code_puppy_control, :legacy_home_dir)
        v -> Application.put_env(:code_puppy_control, :legacy_home_dir, v)
      end

      File.rm_rf(tmp_dir)
      File.rm_rf(fake_legacy)
    end
  end

  describe "resolve/2 — chatgpt_oauth error semantics" do
    test "no token file returns {:error, :not_authenticated}" do
      with_pup_ex_home([], fn ->
        config = %{
          "type" => "chatgpt_oauth",
          "name" => "gpt-5.5",
          "custom_endpoint" => %{"url" => "https://chatgpt.com/backend-api/codex"}
        }

        assert {:error, :not_authenticated} = RuntimeConnection.resolve(config, "chatgpt-gpt-5.5")
      end)
    end

    test "access_token present but no account_id returns {:error, :missing_account_id}" do
      # Write a token file with a non-expired access_token but no account_id.
      # We need a valid (non-expired) JWT so get_valid_access_token succeeds.
      # Build a minimal JWT with a future exp claim.
      future_exp = System.system_time(:second) + 3600
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(Jason.encode!(%{"exp" => future_exp, "sub" => "test"}), padding: false)

      sig = Base.url_encode64("fakesig", padding: false)
      access_token = header <> "." <> payload <> "." <> sig

      with_pup_ex_home(
        [chatgpt_tokens: %{"access_token" => access_token, "api_key" => access_token}],
        fn ->
          config = %{
            "type" => "chatgpt_oauth",
            "name" => "gpt-5.5",
            "custom_endpoint" => %{"url" => "https://chatgpt.com/backend-api/codex"}
          }

          assert {:error, :missing_account_id} =
                   RuntimeConnection.resolve(config, "chatgpt-gpt-5.5")
        end
      )
    end

    test "access_token present but empty account_id returns {:error, :missing_account_id}" do
      future_exp = System.system_time(:second) + 3600
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(Jason.encode!(%{"exp" => future_exp, "sub" => "test"}), padding: false)

      sig = Base.url_encode64("fakesig", padding: false)
      access_token = header <> "." <> payload <> "." <> sig

      with_pup_ex_home(
        [
          chatgpt_tokens: %{
            "access_token" => access_token,
            "api_key" => access_token,
            "account_id" => ""
          }
        ],
        fn ->
          config = %{
            "type" => "chatgpt_oauth",
            "name" => "gpt-5.5",
            "custom_endpoint" => %{"url" => "https://chatgpt.com/backend-api/codex"}
          }

          assert {:error, :missing_account_id} =
                   RuntimeConnection.resolve(config, "chatgpt-gpt-5.5")
        end
      )
    end

    test "access_token and account_id present returns {:ok, _}" do
      future_exp = System.system_time(:second) + 3600
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(Jason.encode!(%{"exp" => future_exp, "sub" => "test"}), padding: false)

      sig = Base.url_encode64("fakesig", padding: false)
      access_token = header <> "." <> payload <> "." <> sig

      with_pup_ex_home(
        [
          chatgpt_tokens: %{
            "access_token" => access_token,
            "api_key" => access_token,
            "account_id" => "acct-xyz"
          }
        ],
        fn ->
          config = %{
            "type" => "chatgpt_oauth",
            "name" => "gpt-5.5",
            "custom_endpoint" => %{"url" => "https://chatgpt.com/backend-api/codex"}
          }

          assert {:ok, resolved} = RuntimeConnection.resolve(config, "chatgpt-gpt-5.5")
          assert resolved.api_key == access_token
          assert {"ChatGPT-Account-Id", "acct-xyz"} in resolved.extra_headers
        end
      )
    end
  end

  # ==========================================================================
  # Legacy Token Fallback Tests (READ-ONLY bridge, ADR-003 compliant)
  # ==========================================================================

  describe "resolve/2 — chatgpt_oauth with legacy token fallback" do
    setup do
      # Create separate temp dirs for Elixir home and legacy home
      ex_home =
        Path.join(
          System.tmp_dir!(),
          "rc_legacy_ex_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      legacy_home =
        Path.join(
          System.tmp_dir!(),
          "rc_legacy_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(ex_home)
      File.mkdir_p!(legacy_home)
      secret_path = Path.join(ex_home, ".machine_secret")

      prev_ex_home = System.get_env("PUP_EX_HOME")
      prev_secret = System.get_env("PUP_MACHINE_SECRET_PATH")
      prev_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)

      System.put_env("PUP_EX_HOME", ex_home)
      System.put_env("PUP_MACHINE_SECRET_PATH", secret_path)
      Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)

      on_exit(fn ->
        case prev_ex_home do
          nil -> System.delete_env("PUP_EX_HOME")
          v -> System.put_env("PUP_EX_HOME", v)
        end

        case prev_secret do
          nil -> System.delete_env("PUP_MACHINE_SECRET_PATH")
          v -> System.put_env("PUP_MACHINE_SECRET_PATH", v)
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

    test "resolves from legacy token when Elixir file absent", %{legacy_home: legacy_home} do
      # Build a non-expired JWT for access_token
      future_exp = System.system_time(:second) + 3600
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(Jason.encode!(%{"exp" => future_exp, "sub" => "test"}), padding: false)

      sig = Base.url_encode64("fakesig", padding: false)
      access_token = header <> "." <> payload <> "." <> sig

      # Write token to legacy location only
      token_data = %{"access_token" => access_token, "account_id" => "acct-legacy-resolve"}
      File.write!(Path.join(legacy_home, "chatgpt_oauth.json"), Jason.encode!(token_data))

      config = %{
        "type" => "chatgpt_oauth",
        "name" => "gpt-5.5",
        "custom_endpoint" => %{"url" => "https://chatgpt.com/backend-api/codex"}
      }

      assert {:ok, resolved} = RuntimeConnection.resolve(config, "chatgpt-gpt-5.5")
      assert resolved.api_key == access_token
      assert {"ChatGPT-Account-Id", "acct-legacy-resolve"} in resolved.extra_headers
    end

    test "Elixir token wins over legacy fallback", %{ex_home: ex_home, legacy_home: legacy_home} do
      # Build two different JWTs
      future_exp = System.system_time(:second) + 3600
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload1 =
        Base.url_encode64(Jason.encode!(%{"exp" => future_exp, "sub" => "legacy"}),
          padding: false
        )

      payload2 =
        Base.url_encode64(Jason.encode!(%{"exp" => future_exp, "sub" => "ex"}), padding: false)

      sig = Base.url_encode64("fakesig", padding: false)
      legacy_token = header <> "." <> payload1 <> "." <> sig
      ex_token = header <> "." <> payload2 <> "." <> sig

      # Write to legacy
      File.write!(
        Path.join(legacy_home, "chatgpt_oauth.json"),
        Jason.encode!(%{"access_token" => legacy_token, "account_id" => "acct-legacy"})
      )

      # Write to Elixir
      auth_dir = Path.join(ex_home, "auth")
      File.mkdir_p!(auth_dir)

      File.write!(
        Path.join(auth_dir, "chatgpt_oauth.json"),
        Jason.encode!(%{"access_token" => ex_token, "account_id" => "acct-ex"})
      )

      config = %{
        "type" => "chatgpt_oauth",
        "name" => "gpt-5.5"
      }

      # Should use Elixir token
      assert {:ok, resolved} = RuntimeConnection.resolve(config, "chatgpt-gpt-5.5")
      assert resolved.api_key == ex_token
      assert {"ChatGPT-Account-Id", "acct-ex"} in resolved.extra_headers
    end

    test "legacy token with missing account_id returns :missing_account_id", %{
      legacy_home: legacy_home
    } do
      # Build a valid JWT
      future_exp = System.system_time(:second) + 3600
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(Jason.encode!(%{"exp" => future_exp, "sub" => "test"}), padding: false)

      sig = Base.url_encode64("fakesig", padding: false)
      access_token = header <> "." <> payload <> "." <> sig

      # Write legacy token without account_id
      token_data = %{"access_token" => access_token}
      File.write!(Path.join(legacy_home, "chatgpt_oauth.json"), Jason.encode!(token_data))

      config = %{
        "type" => "chatgpt_oauth",
        "name" => "gpt-5.5"
      }

      assert {:error, :missing_account_id} = RuntimeConnection.resolve(config, "chatgpt-gpt-5.5")
    end
  end
end
