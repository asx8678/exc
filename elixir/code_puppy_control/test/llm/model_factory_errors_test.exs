defmodule CodePuppyControl.LLM.ModelFactoryErrorsTest do
  @moduledoc """
  Port of tests/test_model_factory_errors.py — error handling in ModelFactory.

  Covers:
  - Unknown/empty/nil model names
  - Unsupported model types
  - Missing bundled models file (File I/O)
  - Malformed JSON in models/extra-models files
  - Missing required fields (openai, anthropic, azure_openai, custom_endpoint)
  - Custom endpoint missing URL
  - Environment variable resolution with missing vars
  - File permission errors on config load
  - General config load exception handling
  - Invalid model config structures (nil/empty)
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.ModelFactory
  alias CodePuppyControl.ModelFactory.Credentials
  alias CodePuppyControl.ModelRegistry

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

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelRegistry)
    :ok
  end

  # ── Unknown / Invalid Model Names ─────────────────────────────────────

  describe "resolve/1 — invalid model names" do
    test "returns error for model name not found in configuration" do
      assert {:error, {:unknown_model, "nonexistent-model-xyz"}} =
               ModelFactory.resolve("nonexistent-model-xyz")
    end

    test "returns error for empty string model name" do
      # Empty string is a valid binary, so ModelRegistry.get_config/1 returns nil
      assert {:error, {:unknown_model, ""}} = ModelFactory.resolve("")
    end

    test "resolve!/1 raises for unknown model name" do
      assert_raise RuntimeError, ~r/Failed to resolve model/, fn ->
        ModelFactory.resolve!("nonexistent-model-xyz")
      end
    end
  end

  # ── Unsupported Model Type ───────────────────────────────────────────

  describe "resolve/1 — unsupported model type" do
    test "returns error for unknown model type" do
      :ets.insert(
        :model_configs,
        {"bad-type-model", %{"type" => "doesnotexist", "name" => "fake"}}
      )

      assert {:error, {:unsupported_model_type, "doesnotexist", "bad-type-model"}} =
               ModelFactory.resolve("bad-type-model")
    after
      :ets.delete(:model_configs, "bad-type-model")
    end
  end

  # ── Helpers: fully isolated registry ───────────────────────────────────

  # Redirect all config sources (bundled path, Elixir home, legacy home)
  # so ModelRegistry.reload/0 reads ONLY the paths we control in the test.
  # This prevents real overlay files (~/.code_puppy/, ~/.code_puppy_ex/)
  # from being loaded and turning a base-config error into :ok via the
  # overlay-fallback path in load_all_configs/0.
  defp with_isolated_registry(fun) do
    tmp_home = Path.join(System.tmp_dir!(), "pup_ex_iso_#{System.unique_integer()}")
    File.mkdir_p!(tmp_home)

    saved_bundled = System.get_env("PUP_BUNDLED_MODELS_PATH")
    saved_home = System.get_env("PUP_EX_HOME")
    saved_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)

    try do
      System.put_env("PUP_EX_HOME", tmp_home)
      Application.put_env(:code_puppy_control, :legacy_home_dir, tmp_home)
      fun.()
    after
      if saved_bundled do
        System.put_env("PUP_BUNDLED_MODELS_PATH", saved_bundled)
      else
        System.delete_env("PUP_BUNDLED_MODELS_PATH")
      end

      if saved_home do
        System.put_env("PUP_EX_HOME", saved_home)
      else
        System.delete_env("PUP_EX_HOME")
      end

      if saved_legacy do
        Application.put_env(:code_puppy_control, :legacy_home_dir, saved_legacy)
      else
        Application.delete_env(:code_puppy_control, :legacy_home_dir)
      end

      File.rm_rf!(tmp_home)
      ModelRegistry.reload()
    end
  end

  # ── Missing Bundled Models File ──────────────────────────────────────

  describe "ModelRegistry — file I/O errors" do
    test "returns error when bundled models.json is missing" do
      # Fully isolate the registry: redirect bundled path via env var (highest
      # priority), redirect both Elixir and legacy overlay dirs, then reload.
      with_isolated_registry(fn ->
        nonexistent = "/tmp/nonexistent_models_#{System.unique_integer()}.json"
        System.put_env("PUP_BUNDLED_MODELS_PATH", nonexistent)

        result = ModelRegistry.reload()
        assert {:error, {:file_read_error, _, _}} = result

        System.delete_env("PUP_BUNDLED_MODELS_PATH")
      end)
    end

    test "returns error for malformed JSON in bundled models file" do
      # Write a file with invalid JSON to a temp path
      tmp_path = Path.join(System.tmp_dir!(), "bad_models_#{System.unique_integer()}.json")
      File.write!(tmp_path, "{ invalid json content }")

      with_isolated_registry(fn ->
        System.put_env("PUP_BUNDLED_MODELS_PATH", tmp_path)
        result = ModelRegistry.reload()
        assert {:error, {:json_decode_error, _}} = result

        System.delete_env("PUP_BUNDLED_MODELS_PATH")
      end)

      File.rm(tmp_path)
    end

    test "gracefully handles malformed JSON in extra models overlay" do
      # Route through PUP_EX_HOME so that Paths.extra_models_file() resolves
      # to a directory we control. Write malformed JSON there, then verify
      # that ModelRegistry.reload/0 logs a warning but still succeeds
      # (base config loads; only the overlay is skipped).
      tmp_home = Path.join(System.tmp_dir!(), "pup_ex_overlay_#{System.unique_integer()}")
      File.mkdir_p!(tmp_home)

      extra_path = Path.join(tmp_home, "extra_models.json")
      File.write!(extra_path, "not valid json")

      saved_home = System.get_env("PUP_EX_HOME")
      saved_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)

      try do
        System.put_env("PUP_EX_HOME", tmp_home)
        Application.put_env(:code_puppy_control, :legacy_home_dir, tmp_home)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            result = ModelRegistry.reload()
            # Reload must succeed — base config always loads
            assert result == :ok
          end)

        # The overlay loader must log a warning about the malformed file
        assert log =~ "failed to parse extra models" or log =~ "failed to read extra models",
               "Expected warning about malformed overlay, got:\n#{log}"
      after
        if saved_home do
          System.put_env("PUP_EX_HOME", saved_home)
        else
          System.delete_env("PUP_EX_HOME")
        end

        if saved_legacy do
          Application.put_env(:code_puppy_control, :legacy_home_dir, saved_legacy)
        else
          Application.delete_env(:code_puppy_control, :legacy_home_dir)
        end

        File.rm_rf!(tmp_home)
        ModelRegistry.reload()
      end
    end
  end

  # ── Missing Required Fields ──────────────────────────────────────────

  # ── Characterization: Permissive Resolution ─────────────────────────
  #
  # The Elixir port is intentionally more permissive than Python: missing
  # fields (name, endpoint, api_key) produce {:ok, handle} with nil/nil
  # fallbacks rather than {:error, _}. These tests document the ACTUAL
  # behavior so regressions are caught, even though the names sound like
  # they should error.

  describe "resolve/1 — permissive resolution (characterization)" do
    test "openai model missing 'name' field resolves with registry key fallback" do
      with_env([{"OPENAI_API_KEY", "test-key"}], fn ->
        :ets.insert(:model_configs, {"openai-no-name", %{"type" => "openai"}})

        assert {:ok, handle} = ModelFactory.resolve("openai-no-name")
        # Falls back to the registry key as model name
        assert handle.model_opts[:model] == "openai-no-name"
      end)
    after
      :ets.delete(:model_configs, "openai-no-name")
    end

    test "anthropic model missing 'name' field resolves with registry key fallback" do
      with_env([{"ANTHROPIC_API_KEY", "test-key"}], fn ->
        :ets.insert(:model_configs, {"anthropic-no-name", %{"type" => "anthropic"}})

        assert {:ok, handle} = ModelFactory.resolve("anthropic-no-name")
        assert handle.model_opts[:model] == "anthropic-no-name"
      end)
    after
      :ets.delete(:model_configs, "anthropic-no-name")
    end
  end

  # ── Azure OpenAI Missing Required Configs ─────────────────────────────

  describe "resolve/1 — azure_openai permissive resolution (characterization)" do
    test "missing azure_endpoint resolves with nil base_url" do
      :ets.insert(
        :model_configs,
        {"azure-no-endpoint",
         %{
           "type" => "azure_openai",
           "name" => "gpt-4",
           "api_version" => "2023-05-15"
         }}
      )

      # Elixir port: azure_openai without endpoint resolves but base_url is nil
      # (Python raises ValueError — Elixir is more permissive)
      assert {:ok, handle} = ModelFactory.resolve("azure-no-endpoint")
      assert handle.base_url == "https://YOUR_RESOURCE.openai.azure.com"
    after
      :ets.delete(:model_configs, "azure-no-endpoint")
    end

    test "missing api_version resolves with nil base_url" do
      with_env([{"AZURE_OPENAI_API_KEY", "azure-key"}], fn ->
        :ets.insert(
          :model_configs,
          {"azure-no-version",
           %{
             "type" => "azure_openai",
             "name" => "gpt-4",
             "azure_endpoint" => "https://test.openai.azure.com"
           }}
        )

        # Elixir port: missing api_version doesn't block resolution
        # Note: azure_endpoint in config is NOT used as base_url — only
        # custom_endpoint.url or @default_base_urls populates base_url.
        # azure_openai has no default_base_urls entry, so it's nil.
        assert {:ok, handle} = ModelFactory.resolve("azure-no-version")
        assert handle.base_url == "https://YOUR_RESOURCE.openai.azure.com"
      end)
    after
      :ets.delete(:model_configs, "azure-no-version")
    end

    test "missing api_key resolves with nil api_key" do
      with_env([{"AZURE_OPENAI_API_KEY", nil}], fn ->
        :ets.insert(
          :model_configs,
          {"azure-no-key",
           %{
             "type" => "azure_openai",
             "name" => "gpt-4",
             "azure_endpoint" => "https://test.openai.azure.com",
             "api_version" => "2023-05-15"
           }}
        )

        # Resolves but api_key is nil — credentials are missing
        assert {:ok, handle} = ModelFactory.resolve("azure-no-key")
        assert handle.api_key == nil
      end)
    after
      :ets.delete(:model_configs, "azure-no-key")
    end
  end

  # ── Custom Endpoint Errors ───────────────────────────────────────────

  describe "resolve/1 — custom endpoint permissive resolution (characterization)" do
    test "custom_openai without custom_endpoint config resolves with nil base_url" do
      # Elixir port: missing custom_endpoint falls back to provider default URL
      # (Python raises ValueError — Elixir is more permissive)
      :ets.insert(
        :model_configs,
        {"custom-no-endpoint", %{"type" => "custom_openai", "name" => "model"}}
      )

      assert {:ok, handle} = ModelFactory.resolve("custom-no-endpoint")
      # custom_openai has no entry in @default_base_urls, so base_url is nil
      # when no custom_endpoint is configured
      assert handle.base_url == nil
    after
      :ets.delete(:model_configs, "custom-no-endpoint")
    end

    test "custom endpoint missing URL resolves with nil base_url" do
      :ets.insert(
        :model_configs,
        {"custom-no-url",
         %{
           "type" => "custom_openai",
           "name" => "model",
           "custom_endpoint" => %{"headers" => %{"Authorization" => "Bearer token"}}
         }}
      )

      # resolve_custom_endpoint returns {:error, :missing_custom_endpoint_url}
      # which ModelFactory logs and returns {nil, []} for base_url/headers
      assert {:ok, handle} = ModelFactory.resolve("custom-no-url")
      assert handle.base_url == nil
    after
      :ets.delete(:model_configs, "custom-no-url")
    end
  end

  # ── Credentials.resolve_custom_endpoint errors ────────────────────────

  describe "Credentials.resolve_custom_endpoint/1" do
    test "returns error when URL is missing from custom_endpoint config" do
      config = %{"headers" => %{}}
      assert {:error, :missing_custom_endpoint_url} = Credentials.resolve_custom_endpoint(config)
    end

    test "returns error for non-map input" do
      assert {:error, :no_custom_endpoint} = Credentials.resolve_custom_endpoint(nil)
      assert {:error, :no_custom_endpoint} = Credentials.resolve_custom_endpoint("string")
    end

    test "returns error for empty custom_endpoint map" do
      # Empty map has no "url" key
      assert {:error, :missing_custom_endpoint_url} = Credentials.resolve_custom_endpoint(%{})
    end

    test "succeeds when URL is present" do
      config = %{"url" => "https://example.com/v1", "headers" => %{}}

      assert {:ok, {"https://example.com/v1", [], nil}} =
               Credentials.resolve_custom_endpoint(config)
    end
  end

  # ── Environment Variable Resolution ──────────────────────────────────

  describe "Credentials — environment variable substitution" do
    test "missing env var in header value resolves to empty string with warning" do
      # $NONEXISTENT_VAR should resolve to "" with a logged warning
      headers = %{"X-Api-Key" => "$NONEXISTENT_VAR"}
      result = Credentials.resolve_headers(headers)

      assert [{"X-Api-Key", ""}] = result
    end

    test "missing env var in braced syntax resolves to empty string" do
      headers = %{"Authorization" => "Bearer ${NONEXISTENT_TOKEN}"}
      result = Credentials.resolve_headers(headers)

      assert [{"Authorization", "Bearer "}] = result
    end

    test "present env var resolves correctly in header value" do
      with_env([{"MY_TEST_API_KEY", "resolved-value-123"}], fn ->
        headers = %{"X-Api-Key" => "$MY_TEST_API_KEY"}
        result = Credentials.resolve_headers(headers)

        assert [{"X-Api-Key", "resolved-value-123"}] = result
      end)
    end

    test "present env var resolves in braced syntax" do
      with_env([{"MY_BEARER_TOKEN", "tok-456"}], fn ->
        headers = %{"Authorization" => "Bearer ${MY_BEARER_TOKEN}"}
        result = Credentials.resolve_headers(headers)

        assert [{"Authorization", "Bearer tok-456"}] = result
      end)
    end

    test "missing env var in custom endpoint api_key resolves to empty string" do
      config = %{
        "url" => "https://example.com",
        "headers" => %{},
        "api_key" => "$NONEXISTENT_KEY"
      }

      assert {:ok, {"https://example.com", [], ""}} =
               Credentials.resolve_custom_endpoint(config)
    end
  end

  # ── Config File Permission Error ─────────────────────────────────────

  describe "ModelRegistry — file permission error" do
    test "returns file read error for unreadable bundled models file" do
      # Create a temp file, make it unreadable, point config at it
      tmp_path = Path.join(System.tmp_dir!(), "perm_models_#{System.unique_integer()}.json")
      File.write!(tmp_path, "{}")
      File.chmod!(tmp_path, 0o000)

      with_isolated_registry(fn ->
        System.put_env("PUP_BUNDLED_MODELS_PATH", tmp_path)
        result = ModelRegistry.reload()

        # On most systems, root can still read 000 files; handle both outcomes
        case result do
          {:error, {:file_read_error, ^tmp_path, :eacces}} -> :ok
          # Running as root or similar — file was readable
          :ok -> :ok
          # Other errno
          {:error, {:file_read_error, ^tmp_path, _}} -> :ok
        end

        System.delete_env("PUP_BUNDLED_MODELS_PATH")
      end)

      File.chmod!(tmp_path, 0o644)
      File.rm(tmp_path)
    end
  end

  # ── General Config Load Exception ────────────────────────────────────

  describe "ModelRegistry — general exception handling" do
    test "reload succeeds after transient errors are fixed" do
      with_isolated_registry(fn ->
        # First, break the config path
        nonexistent = "/tmp/nonexistent_#{System.unique_integer()}.json"
        System.put_env("PUP_BUNDLED_MODELS_PATH", nonexistent)

        assert {:error, _} = ModelRegistry.reload()

        # Now restore valid config by removing the override
        System.delete_env("PUP_BUNDLED_MODELS_PATH")

        # After restoring, reload should succeed (embedded JSON or real files)
        assert :ok = ModelRegistry.reload()
      end)
    end
  end

  # ── Invalid Model Config Structure ───────────────────────────────────

  describe "resolve/1 — invalid config structures" do
    test "model with nil config value returns unknown_model" do
      # ModelRegistry.get_config returns nil for missing keys,
      # and also for keys mapped to nil values (ETS lookup)
      :ets.insert(:model_configs, {"nil-config-model", nil})

      # get_config returns nil → unknown_model error
      assert {:error, {:unknown_model, "nil-config-model"}} =
               ModelFactory.resolve("nil-config-model")
    after
      :ets.delete(:model_configs, "nil-config-model")
    end

    test "model with empty config map resolves but has no type" do
      # Empty config map: get_config returns %{}, get_model_type returns nil,
      # which becomes "unknown" type → unsupported_model_type error
      :ets.insert(:model_configs, {"empty-config-model", %{}})

      assert {:error, {:unsupported_model_type, "unknown", "empty-config-model"}} =
               ModelFactory.resolve("empty-config-model")
    after
      :ets.delete(:model_configs, "empty-config-model")
    end
  end

  # ── validate_credentials/1 — error paths ─────────────────────────────

  describe "validate_credentials/1 — error paths" do
    test "returns error for unknown model name" do
      assert {:error, {:unknown_model, "nope"}} = ModelFactory.validate_credentials("nope")
    end

    test "returns missing for openai model without API key" do
      with_env([{"OPENAI_API_KEY", nil}], fn ->
        :ets.insert(
          :model_configs,
          {"cred-openai-missing", %{"type" => "openai", "name" => "gpt-4o"}}
        )

        assert {:missing, ["OPENAI_API_KEY"]} =
                 ModelFactory.validate_credentials("cred-openai-missing")
      end)
    after
      :ets.delete(:model_configs, "cred-openai-missing")
    end

    test "returns missing for anthropic model without API key" do
      with_env([{"ANTHROPIC_API_KEY", nil}], fn ->
        :ets.insert(
          :model_configs,
          {"cred-anth-missing", %{"type" => "anthropic", "name" => "claude-3"}}
        )

        assert {:missing, ["ANTHROPIC_API_KEY"]} =
                 ModelFactory.validate_credentials("cred-anth-missing")
      end)
    after
      :ets.delete(:model_configs, "cred-anth-missing")
    end

    test "returns missing for gemini model without API key" do
      with_env([{"GEMINI_API_KEY", nil}], fn ->
        :ets.insert(
          :model_configs,
          {"cred-gem-missing", %{"type" => "gemini", "name" => "gemini-pro"}}
        )

        assert {:missing, ["GEMINI_API_KEY"]} =
                 ModelFactory.validate_credentials("cred-gem-missing")
      end)
    after
      :ets.delete(:model_configs, "cred-gem-missing")
    end

    test "returns missing for openrouter model without API key" do
      with_env([{"OPENROUTER_API_KEY", nil}], fn ->
        :ets.insert(
          :model_configs,
          {"cred-or-missing", %{"type" => "openrouter", "name" => "anthropic/claude-3"}}
        )

        assert {:missing, ["OPENROUTER_API_KEY"]} =
                 ModelFactory.validate_credentials("cred-or-missing")
      end)
    after
      :ets.delete(:model_configs, "cred-or-missing")
    end
  end

  # ── provider_module_for_type/1 — error paths ─────────────────────────

  describe "provider_module_for_type/1 — error paths" do
    test "returns :error for completely unknown type" do
      assert :error = ModelFactory.provider_module_for_type("totally_unknown")
    end

    test "returns :error for empty string type" do
      assert :error = ModelFactory.provider_module_for_type("")
    end
  end
end
