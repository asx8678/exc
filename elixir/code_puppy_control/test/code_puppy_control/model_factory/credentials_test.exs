defmodule CodePuppyControl.ModelFactory.CredentialsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.ModelFactory.Credentials

  # We use System.put_env/delete_env in tests, so not async

  # ── Module-level sandbox ──────────────────────────────────────────────
  # Because resolve_api_key/2 and resolve_headers/1 now fall through to
  # env_or_store/1 → credential_store_get/1 → Crypto.derive_key/0 when
  # env vars are absent, ANY test that deletes an env var can accidentally
  # read or CREATE the real ~/.code_puppy_ex/ credential store and
  # .machine_secret.  Redirect both paths to a temp dir so no test can
  # touch the real files.  (Newer describe blocks override PUP_EX_HOME
  # to their own temp dirs, which is fine — on_exit restores in LIFO
  # order, so the real env is always restored last.)
  setup_all do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "mf_cred_sandbox_#{:erlang.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    secret_path = Path.join(tmp, ".machine_secret")

    prev_ex_home = System.get_env("PUP_EX_HOME")
    prev_secret = System.get_env("PUP_MACHINE_SECRET_PATH")
    System.put_env("PUP_EX_HOME", tmp)
    System.put_env("PUP_MACHINE_SECRET_PATH", secret_path)

    on_exit(fn ->
      case prev_ex_home do
        nil -> System.delete_env("PUP_EX_HOME")
        v -> System.put_env("PUP_EX_HOME", v)
      end

      case prev_secret do
        nil -> System.delete_env("PUP_MACHINE_SECRET_PATH")
        v -> System.put_env("PUP_MACHINE_SECRET_PATH", v)
      end

      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "resolve_api_key/2" do
    test "resolves from model config api_key_env" do
      System.put_env("MY_CUSTOM_KEY", "sk-custom-123")

      result = Credentials.resolve_api_key("openai", %{"api_key_env" => "MY_CUSTOM_KEY"})
      assert result == "sk-custom-123"

      System.delete_env("MY_CUSTOM_KEY")
    end

    test "falls back to provider default env var" do
      System.put_env("OPENAI_API_KEY", "sk-openai-default")

      result = Credentials.resolve_api_key("openai", %{})
      assert result == "sk-openai-default"

      System.delete_env("OPENAI_API_KEY")
    end

    test "returns nil when no env vars set" do
      # Ensure the env vars are not set
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("NONEXISTENT_KEY")

      result = Credentials.resolve_api_key("openai", %{"api_key_env" => "NONEXISTENT_KEY"})
      assert result == nil
    end

    test "resolves anthropic provider default" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")

      result = Credentials.resolve_api_key("anthropic", %{})
      assert result == "sk-ant-test"

      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "resolves cerebras provider default" do
      System.put_env("CEREBRAS_API_KEY", "csk-test")

      result = Credentials.resolve_api_key("cerebras", %{})
      assert result == "csk-test"

      System.delete_env("CEREBRAS_API_KEY")
    end

    test "resolves openrouter provider default" do
      System.put_env("OPENROUTER_API_KEY", "sk-or-test")

      result = Credentials.resolve_api_key("openrouter", %{})
      assert result == "sk-or-test"

      System.delete_env("OPENROUTER_API_KEY")
    end

    test "config api_key_env takes precedence over provider default" do
      System.put_env("OPENAI_API_KEY", "default-key")
      System.put_env("MY_OVERRIDE_KEY", "override-key")

      result = Credentials.resolve_api_key("openai", %{"api_key_env" => "MY_OVERRIDE_KEY"})
      assert result == "override-key"

      System.delete_env("OPENAI_API_KEY")
      System.delete_env("MY_OVERRIDE_KEY")
    end
  end

  describe "validate/2" do
    test "returns :ok when env var is present" do
      System.put_env("OPENAI_API_KEY", "sk-present")

      assert :ok = Credentials.validate("openai", %{})

      System.delete_env("OPENAI_API_KEY")
    end

    test "returns {:missing, vars} when env var is absent" do
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("TEST_ABSENT_KEY")

      result = Credentials.validate("openai", %{"api_key_env" => "TEST_ABSENT_KEY"})
      assert {:missing, ["TEST_ABSENT_KEY"]} = result
    end

    test "returns {:missing, ...} for claude_code when no OAuth token" do
      # Ensure no OAuth token file exists by using temp dir
      result = Credentials.validate("claude_code", %{})
      assert {:missing, ["CLAUDE_CODE_OAUTH_TOKEN"]} = result
    end

    test "returns {:missing, ...} for chatgpt_oauth when no OAuth token" do
      # Ensure no OAuth token file exists by using temp dir
      result = Credentials.validate("chatgpt_oauth", %{})
      assert {:missing, ["CHATGPT_OAUTH_TOKEN"]} = result
    end

    test "validates custom api_key_env when specified" do
      System.put_env("MY_SPECIAL_KEY", "sk-special")

      assert :ok = Credentials.validate("openai", %{"api_key_env" => "MY_SPECIAL_KEY"})

      System.delete_env("MY_SPECIAL_KEY")
    end
  end

  describe "resolve_headers/1" do
    test "substitutes ${VAR} syntax" do
      System.put_env("AUTH_TOKEN", "bearer-123")

      result = Credentials.resolve_headers(%{"Authorization" => "Bearer ${AUTH_TOKEN}"})
      assert [{"Authorization", "Bearer bearer-123"}] = result

      System.delete_env("AUTH_TOKEN")
    end

    test "substitutes $VAR syntax" do
      System.put_env("API_VERSION", "v2")

      result = Credentials.resolve_headers(%{"X-Api-Version" => "$API_VERSION"})
      assert [{"X-Api-Version", "v2"}] = result

      System.delete_env("API_VERSION")
    end

    test "replaces missing env vars with empty string" do
      System.delete_env("NONEXISTENT_HEADER_VAR")

      result =
        Credentials.resolve_headers(%{"X-Key" => "prefix-${NONEXISTENT_HEADER_VAR}-suffix"})

      assert [{"X-Key", "prefix--suffix"}] = result
    end

    test "handles multiple env vars in one value" do
      System.put_env("HOST", "api.example.com")
      System.put_env("PORT", "443")

      result = Credentials.resolve_headers(%{"X-Endpoint" => "https://$HOST:$PORT/v1"})
      assert [{"X-Endpoint", "https://api.example.com:443/v1"}] = result

      System.delete_env("HOST")
      System.delete_env("PORT")
    end

    test "returns empty list for nil input" do
      assert Credentials.resolve_headers(nil) == []
    end

    test "preserves headers without env vars" do
      result = Credentials.resolve_headers(%{"Content-Type" => "application/json"})
      assert [{"Content-Type", "application/json"}] = result
    end
  end

  describe "resolve_custom_endpoint/1" do
    test "extracts url, headers, api_key from config" do
      System.put_env("PROXY_KEY", "sk-proxy")

      config = %{
        "url" => "https://proxy.example.com",
        "headers" => %{"Authorization" => "Bearer $PROXY_KEY"},
        "api_key" => "$PROXY_KEY"
      }

      assert {:ok, {url, headers, api_key}} = Credentials.resolve_custom_endpoint(config)
      assert url == "https://proxy.example.com"
      assert headers == [{"Authorization", "Bearer sk-proxy"}]
      assert api_key == "sk-proxy"

      System.delete_env("PROXY_KEY")
    end

    test "returns error when url is missing" do
      config = %{"headers" => %{}}
      assert {:error, :missing_custom_endpoint_url} = Credentials.resolve_custom_endpoint(config)
    end

    test "returns error for non-map input" do
      assert {:error, :no_custom_endpoint} = Credentials.resolve_custom_endpoint(nil)
      assert {:error, :no_custom_endpoint} = Credentials.resolve_custom_endpoint("bad")
    end

    test "handles missing api_key gracefully" do
      config = %{"url" => "https://example.com"}
      assert {:ok, {"https://example.com", [], nil}} = Credentials.resolve_custom_endpoint(config)
    end

    test "handles missing headers gracefully" do
      config = %{"url" => "https://example.com"}
      assert {:ok, {"https://example.com", [], nil}} = Credentials.resolve_custom_endpoint(config)
    end
  end

  describe "env var substitution with credential store fallback" do
    setup do
      # ── Isolation: redirect both credential store and machine secret ──
      # Production code path: ModelFactory.Credentials.env_or_store/1 →
      # credential_store_get/1 → CodePuppyControl.Credentials.get(key)
      # (no store_dir: option), so we MUST redirect the DEFAULT store via
      # PUP_EX_HOME.  We also isolate the machine secret so Crypto.derive_key/0
      # never reads or creates the real ~/.code_puppy_ex/.machine_secret.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mf_cred_fallback_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(tmp)
      store_dir = Path.join(tmp, "credentials")
      secret_path = Path.join(tmp, ".machine_secret")

      prev_ex_home = System.get_env("PUP_EX_HOME")
      prev_secret = System.get_env("PUP_MACHINE_SECRET_PATH")
      System.put_env("PUP_EX_HOME", tmp)
      System.put_env("PUP_MACHINE_SECRET_PATH", secret_path)

      # Unique key names to avoid collisions with other tests or real env
      prefix = "CP_OYL_TEST_#{:erlang.unique_integer([:positive])}"
      env_key = "#{prefix}_ENV_ONLY"
      store_key = "#{prefix}_STORE_ONLY"
      both_key = "#{prefix}_BOTH"
      neither_key = "#{prefix}_NEITHER"

      # Clean slate: delete all env vars
      for k <- [env_key, store_key, both_key, neither_key] do
        System.delete_env(k)
      end

      on_exit(fn ->
        # Restore env vars so other tests (and the real store) are unaffected
        case prev_ex_home do
          nil -> System.delete_env("PUP_EX_HOME")
          v -> System.put_env("PUP_EX_HOME", v)
        end

        case prev_secret do
          nil -> System.delete_env("PUP_MACHINE_SECRET_PATH")
          v -> System.put_env("PUP_MACHINE_SECRET_PATH", v)
        end

        for k <- [env_key, store_key, both_key, neither_key] do
          System.delete_env(k)
        end

        File.rm_rf(tmp)
      end)

      {:ok,
       env_key: env_key,
       store_key: store_key,
       both_key: both_key,
       neither_key: neither_key,
       store_dir: store_dir}
    end

    test "header substitution: env var takes precedence over store", context do
      System.put_env(context.both_key, "env-value")

      :ok =
        CodePuppyControl.Credentials.set(context.both_key, "store-value",
          store_dir: context.store_dir
        )

      result = Credentials.resolve_headers(%{"X-Test" => "${#{context.both_key}}"})
      assert [{"X-Test", "env-value"}] = result
    end

    test "header substitution: falls back to credential store when env unset", context do
      :ok =
        CodePuppyControl.Credentials.set(context.store_key, "store-secret",
          store_dir: context.store_dir
        )

      result = Credentials.resolve_headers(%{"X-Auth" => "Bearer $#{context.store_key}"})
      assert [{"X-Auth", "Bearer store-secret"}] = result
    end

    test "header substitution: empty string when neither env nor store", context do
      result =
        Credentials.resolve_headers(%{"X-Missing" => "prefix-${#{context.neither_key}}-suffix"})

      assert [{"X-Missing", "prefix--suffix"}] = result
    end

    test "custom endpoint api_key: falls back to credential store when env unset", context do
      :ok =
        CodePuppyControl.Credentials.set(context.store_key, "sk-store-endpoint",
          store_dir: context.store_dir
        )

      config = %{
        "url" => "https://custom.example.com",
        "api_key" => "$#{context.store_key}"
      }

      assert {:ok, {_url, _headers, api_key}} = Credentials.resolve_custom_endpoint(config)
      assert api_key == "sk-store-endpoint"
    end

    test "custom endpoint headers: falls back to credential store when env unset", context do
      :ok =
        CodePuppyControl.Credentials.set(context.store_key, "token-from-store",
          store_dir: context.store_dir
        )

      config = %{
        "url" => "https://custom.example.com",
        "headers" => %{"Authorization" => "Bearer ${#{context.store_key}}"}
      }

      assert {:ok, {_url, headers, _api_key}} = Credentials.resolve_custom_endpoint(config)
      assert headers == [{"Authorization", "Bearer token-from-store"}]
    end

    test "braced and unbraced syntax both resolve from store", context do
      :ok =
        CodePuppyControl.Credentials.set(context.store_key, "braced-val",
          store_dir: context.store_dir
        )

      result_braced =
        Credentials.resolve_headers(%{"X-A" => "${#{context.store_key}}"})

      :ok =
        CodePuppyControl.Credentials.set(context.store_key, "unbraced-val",
          store_dir: context.store_dir
        )

      result_unbraced =
        Credentials.resolve_headers(%{"X-B" => "$#{context.store_key}"})

      assert [{"X-A", "braced-val"}] = result_braced
      assert [{"X-B", "unbraced-val"}] = result_unbraced
    end
  end

  describe "resolve_api_key/2 with credential store" do
    setup do
      # ── Isolation: redirect both credential store and machine secret ──
      # resolve_api_key/2 calls env_or_store/1 → credential_store_get/1 →
      # CodePuppyControl.Credentials.get(key) (no store_dir: option).
      # PUP_EX_HOME redirects the default store; PUP_MACHINE_SECRET_PATH
      # isolates the encryption key.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mf_cred_resolve_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(tmp)
      store_dir = Path.join(tmp, "credentials")
      secret_path = Path.join(tmp, ".machine_secret")

      prev_ex_home = System.get_env("PUP_EX_HOME")
      prev_secret = System.get_env("PUP_MACHINE_SECRET_PATH")
      System.put_env("PUP_EX_HOME", tmp)
      System.put_env("PUP_MACHINE_SECRET_PATH", secret_path)

      # Ensure env vars are clean so we test the store fallback
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")

      on_exit(fn ->
        case prev_ex_home do
          nil -> System.delete_env("PUP_EX_HOME")
          v -> System.put_env("PUP_EX_HOME", v)
        end

        case prev_secret do
          nil -> System.delete_env("PUP_MACHINE_SECRET_PATH")
          v -> System.put_env("PUP_MACHINE_SECRET_PATH", v)
        end

        System.delete_env("OPENAI_API_KEY")
        System.delete_env("ANTHROPIC_API_KEY")
        File.rm_rf(tmp)
      end)

      {:ok, store_dir: store_dir}
    end

    test "falls back to credential store when env var is not set", %{store_dir: dir} do
      :ok = CodePuppyControl.Credentials.set("OPENAI_API_KEY", "sk-from-store", store_dir: dir)

      # OPENAI_API_KEY env var is unset (cleaned in setup), so
      # resolve_api_key should fall through to the encrypted store.
      # PUP_EX_HOME redirects the default store_dir to our temp dir,
      # so the production code path will find the key there.
      assert Credentials.resolve_api_key("openai", %{}) == "sk-from-store"
    end

    test "env var still wins over store when set", %{store_dir: dir} do
      :ok = CodePuppyControl.Credentials.set("OPENAI_API_KEY", "sk-from-store", store_dir: dir)
      System.put_env("OPENAI_API_KEY", "sk-from-env")

      assert Credentials.resolve_api_key("openai", %{}) == "sk-from-env"

      System.delete_env("OPENAI_API_KEY")
    end
  end

  describe "OAuth validation" do
    setup do
      # Create temp directories for OAuth token files
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "oauth_test_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(tmp_dir)

      # Redirect paths for both OAuth modules
      prev_ex_home = System.get_env("PUP_EX_HOME")
      System.put_env("PUP_EX_HOME", tmp_dir)

      on_exit(fn ->
        case prev_ex_home do
          nil -> System.delete_env("PUP_EX_HOME")
          v -> System.put_env("PUP_EX_HOME", v)
        end

        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "claude_code returns :ok when OAuth token exists", %{tmp_dir: dir} do
      # Create token file in expected location
      token_path = Path.join(dir, "claude_code_oauth.json")
      token_data = %{"access_token" => "test-token-123", "refresh_token" => "refresh-456"}
      File.write!(token_path, Jason.encode!(token_data))

      assert :ok = Credentials.validate("claude_code", %{})
    end

    test "claude_code returns {:missing, ...} when access_token is empty", %{tmp_dir: dir} do
      # Create token file with empty access_token
      token_path = Path.join(dir, "claude_code_oauth.json")
      token_data = %{"access_token" => "", "refresh_token" => "refresh-456"}
      File.write!(token_path, Jason.encode!(token_data))

      result = Credentials.validate("claude_code", %{})
      assert {:missing, ["CLAUDE_CODE_OAUTH_TOKEN"]} = result
    end

    test "chatgpt_oauth returns :ok when OAuth token exists", %{tmp_dir: dir} do
      # Create token file in expected location
      auth_dir = Path.join(dir, "auth")
      File.mkdir_p!(auth_dir)
      token_path = Path.join(auth_dir, "chatgpt_oauth.json")
      token_data = %{"access_token" => "test-token-789", "api_key" => "test-token-789"}
      File.write!(token_path, Jason.encode!(token_data))

      assert :ok = Credentials.validate("chatgpt_oauth", %{})
    end

    test "chatgpt_oauth returns {:missing, ...} when access_token is missing", %{tmp_dir: dir} do
      # Create token file without access_token
      auth_dir = Path.join(dir, "auth")
      File.mkdir_p!(auth_dir)
      token_path = Path.join(auth_dir, "chatgpt_oauth.json")
      token_data = %{"refresh_token" => "refresh-789"}
      File.write!(token_path, Jason.encode!(token_data))

      result = Credentials.validate("chatgpt_oauth", %{})
      assert {:missing, ["CHATGPT_OAUTH_TOKEN"]} = result
    end
  end
end
