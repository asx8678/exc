defmodule CodePuppyControl.LLM.CredentialsTest do
  @moduledoc """
  Port of credential-related tests from tests/test_model_factory.py.

  Covers:
  - API key resolution (env var lookup order)
  - Custom env var override via api_key_env
  - Provider default fallback
  - Header substitution ($VAR and ${VAR} syntax)
  - Custom endpoint resolution (url + headers + api_key)
  - Validation (missing keys)
  - OAuth models validate token presence
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.ModelFactory.Credentials

  # Helper to save, set, and restore env vars within a test
  defp with_env(vars, fun) do
    saved = Enum.map(vars, fn {k, _v} -> {k, System.get_env(k)} end)

    Enum.each(vars, fn {k, v} ->
      if v == nil, do: System.delete_env(k), else: System.put_env(k, v)
    end)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  # ── Module-level sandbox ──────────────────────────────────────────────
  # resolve_api_key/2 and resolve_headers/1 now fall through to
  # env_or_store/1 → credential_store_get/1 → Crypto.derive_key/0 when
  # env vars are absent.  Without this sandbox, any test that deletes an
  # env var (e.g. with_env [{"OPENAI_API_KEY", nil}, …]) would read or
  # CREATE the real ~/.code_puppy_ex/ credential store and .machine_secret.
  # Redirect both paths and legacy home to throwaway temp dirs.
  setup_all do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "llm_cred_sandbox_#{:erlang.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)

    fake_legacy =
      Path.join(
        System.tmp_dir!(),
        "llm_cred_legacy_#{:erlang.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(fake_legacy)
    secret_path = Path.join(tmp, ".machine_secret")

    prev_ex_home = System.get_env("PUP_EX_HOME")
    prev_secret = System.get_env("PUP_MACHINE_SECRET_PATH")
    prev_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
    System.put_env("PUP_EX_HOME", tmp)
    System.put_env("PUP_MACHINE_SECRET_PATH", secret_path)
    Application.put_env(:code_puppy_control, :legacy_home_dir, fake_legacy)

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

      File.rm_rf(tmp)
      File.rm_rf(fake_legacy)
    end)

    :ok
  end

  # ── API Key Resolution ─────────────────────────────────────────────────

  describe "resolve_api_key/2" do
    test "returns nil when no env var is set" do
      with_env([{"OPENAI_API_KEY", nil}], fn ->
        assert Credentials.resolve_api_key("openai", %{}) == nil
      end)
    end

    test "resolves from provider default env var" do
      with_env([{"OPENAI_API_KEY", "sk-test-123"}], fn ->
        assert Credentials.resolve_api_key("openai", %{}) == "sk-test-123"
      end)
    end

    test "resolves from model-specific api_key_env first" do
      with_env([{"MY_CUSTOM_KEY", "custom-value"}, {"OPENAI_API_KEY", "default-value"}], fn ->
        assert Credentials.resolve_api_key("openai", %{"api_key_env" => "MY_CUSTOM_KEY"}) ==
                 "custom-value"
      end)
    end

    test "falls back to provider default when api_key_env is not set" do
      with_env([{"ANTHROPIC_API_KEY", "ant-default"}], fn ->
        assert Credentials.resolve_api_key("anthropic", %{}) == "ant-default"
      end)
    end

    test "returns nil for unknown provider type" do
      assert Credentials.resolve_api_key("unknown_provider", %{}) == nil
    end
  end

  # ── Header Substitution ────────────────────────────────────────────────

  describe "resolve_headers/1" do
    test "substitutes $VAR syntax in header values" do
      with_env([{"MY_TOKEN", "secret-token"}], fn ->
        headers = Credentials.resolve_headers(%{"Authorization" => "Bearer $MY_TOKEN"})
        assert headers == [{"Authorization", "Bearer secret-token"}]
      end)
    end

    test "substitutes ${VAR} syntax in header values" do
      with_env([{"MY_TOKEN", "secret-token"}], fn ->
        headers = Credentials.resolve_headers(%{"X-Api-Key" => "${MY_TOKEN}"})
        assert headers == [{"X-Api-Key", "secret-token"}]
      end)
    end

    test "returns empty string when env var is not set" do
      with_env([{"NONEXISTENT_VAR", nil}], fn ->
        headers = Credentials.resolve_headers(%{"Auth" => "$NONEXISTENT_VAR"})
        assert headers == [{"Auth", ""}]
      end)
    end

    test "passes through literal values without substitution" do
      headers = Credentials.resolve_headers(%{"Content-Type" => "application/json"})
      assert headers == [{"Content-Type", "application/json"}]
    end

    test "handles empty map" do
      assert Credentials.resolve_headers(%{}) == []
    end

    test "handles non-map input" do
      assert Credentials.resolve_headers(nil) == []
      assert Credentials.resolve_headers("not a map") == []
    end
  end

  # ── Custom Endpoint Resolution ─────────────────────────────────────────

  describe "resolve_custom_endpoint/1" do
    test "resolves URL, headers, and api_key" do
      with_env([{"OPENAI_API_KEY", "sk-custom"}], fn ->
        config = %{
          "url" => "https://custom.api.com/v1",
          "headers" => %{"X-Api-Key" => "$OPENAI_API_KEY"},
          "api_key" => "$OPENAI_API_KEY"
        }

        assert {:ok, {url, headers, api_key}} = Credentials.resolve_custom_endpoint(config)
        assert url == "https://custom.api.com/v1"
        assert {"X-Api-Key", "sk-custom"} in headers
        assert api_key == "sk-custom"
      end)
    end

    test "returns error when URL is missing" do
      config = %{"headers" => %{}}
      assert {:error, :missing_custom_endpoint_url} = Credentials.resolve_custom_endpoint(config)
    end

    test "returns error for non-map input" do
      assert {:error, :no_custom_endpoint} = Credentials.resolve_custom_endpoint(nil)
      assert {:error, :no_custom_endpoint} = Credentials.resolve_custom_endpoint("string")
    end

    test "api_key is nil when not specified" do
      config = %{"url" => "https://example.com", "headers" => %{}}
      assert {:ok, {_url, _headers, api_key}} = Credentials.resolve_custom_endpoint(config)
      assert api_key == nil
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────

  describe "validate/2" do
    test "returns :ok when required env var is set" do
      with_env([{"OPENAI_API_KEY", "present"}], fn ->
        assert :ok = Credentials.validate("openai", %{})
      end)
    end

    test "returns missing when required env var is absent" do
      with_env([{"OPENAI_API_KEY", nil}], fn ->
        assert {:missing, ["OPENAI_API_KEY"]} = Credentials.validate("openai", %{})
      end)
    end

    test "returns {:missing, ...} for claude_code when no OAuth token" do
      result = Credentials.validate("claude_code", %{})
      assert {:missing, ["CLAUDE_CODE_OAUTH_TOKEN"]} = result
    end

    test "returns {:missing, ...} for chatgpt_oauth when no OAuth token" do
      result = Credentials.validate("chatgpt_oauth", %{})
      assert {:missing, ["CHATGPT_OAUTH_TOKEN"]} = result
    end

    test "uses api_key_env for validation" do
      with_env([{"MY_SPECIAL_KEY", nil}], fn ->
        assert {:missing, ["MY_SPECIAL_KEY"]} =
                 Credentials.validate("openai", %{"api_key_env" => "MY_SPECIAL_KEY"})
      end)
    end

    test "unknown provider type returns :ok (no required vars)" do
      assert :ok = Credentials.validate("unknown_provider", %{})
    end
  end
end
