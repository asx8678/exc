defmodule CodePuppyControl.LLM.ModelFactoryTest do
  @moduledoc """
  Port of tests/test_model_factory.py — ModelFactory.resolve/1 and credential resolution.

  Covers:
  - Resolving known model types to provider handles
  - Error for unknown model names
  - Error for unsupported model types
  - Provider module lookup
  - Credentials: validation via ModelFactory
  - Custom endpoint resolution
  - Handle struct fields
  - list_available/0 filtering
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.ModelFactory
  alias CodePuppyControl.ModelFactory.Handle
  alias CodePuppyControl.ModelRegistry
  alias CodePuppyControl.LLM.Providers.{OpenAI, Anthropic, Google}

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

  # Helper to isolate PUP_EX_HOME + PUP_MACHINE_SECRET_PATH to a temp dir.
  # Optionally writes a ChatGPT OAuth token file when chatgpt_tokens: is provided.
  #
  # Usage:
  #   with_pup_ex_home([], fn -> ... end)                      # empty home, no tokens
  #   with_pup_ex_home(chatgpt_tokens: %{...}, fn -> ... end)  # with token file
  defp with_pup_ex_home(opts, fun) when is_list(opts) and is_function(fun, 0) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mf_home_#{:erlang.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)

    # Optionally write ChatGPT OAuth tokens into auth/chatgpt_oauth.json
    if token_data = Keyword.get(opts, :chatgpt_tokens) do
      auth_dir = Path.join(tmp_dir, "auth")
      File.mkdir_p!(auth_dir)
      File.write!(Path.join(auth_dir, "chatgpt_oauth.json"), Jason.encode!(token_data))
    end

    secret_path = Path.join(tmp_dir, ".machine_secret")

    prev_ex_home = System.get_env("PUP_EX_HOME")
    prev_secret = System.get_env("PUP_MACHINE_SECRET_PATH")
    System.put_env("PUP_EX_HOME", tmp_dir)
    System.put_env("PUP_MACHINE_SECRET_PATH", secret_path)

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

      File.rm_rf(tmp_dir)
    end
  end

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelRegistry)
    # (code_puppy-i1n) ProviderRegistry may be dead if supervisor tree was killed.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.ModelFactory.ProviderRegistry
    )

    :ok
  end

  # ── Resolve ─────────────────────────────────────────────────────────────

  describe "resolve/1" do
    test "returns error for unknown model name" do
      assert {:error, {:unknown_model, "nonexistent-model-xyz"}} =
               ModelFactory.resolve("nonexistent-model-xyz")
    end

    test "returns error for unsupported model type" do
      :ets.insert(
        :model_configs,
        {"bad-type-model", %{"type" => "doesnotexist", "name" => "fake"}}
      )

      assert {:error, {:unsupported_model_type, "doesnotexist", "bad-type-model"}} =
               ModelFactory.resolve("bad-type-model")
    after
      :ets.delete(:model_configs, "bad-type-model")
    end

    test "returns error for OAuth phase-4 types" do
      :ets.insert(
        :model_configs,
        {"claude-code-test", %{"type" => "claude_code", "name" => "test"}}
      )

      assert {:error, :not_authenticated} =
               ModelFactory.resolve("claude-code-test")
    after
      :ets.delete(:model_configs, "claude-code-test")
    end

    test "returns error for round_robin type" do
      :ets.insert(:model_configs, {"rr-model", %{"type" => "round_robin", "name" => "rr"}})

      assert {:error, :round_robin_use_routing} = ModelFactory.resolve("rr-model")
    after
      :ets.delete(:model_configs, "rr-model")
    end

    test "resolves openai model with API key" do
      with_env([{"OPENAI_API_KEY", "test-key-123"}], fn ->
        :ets.insert(:model_configs, {"test-openai", %{"type" => "openai", "name" => "gpt-4o"}})

        assert {:ok, handle} = ModelFactory.resolve("test-openai")
        assert %Handle{} = handle
        assert handle.provider_module == OpenAI
        assert handle.api_key == "test-key-123"
        assert handle.model_name == "test-openai"
      end)
    after
      :ets.delete(:model_configs, "test-openai")
    end

    test "resolves anthropic model with API key" do
      with_env([{"ANTHROPIC_API_KEY", "ant-key-456"}], fn ->
        :ets.insert(
          :model_configs,
          {"test-anthropic", %{"type" => "anthropic", "name" => "claude-sonnet-4"}}
        )

        assert {:ok, handle} = ModelFactory.resolve("test-anthropic")
        assert handle.provider_module == Anthropic
        assert handle.api_key == "ant-key-456"
      end)
    after
      :ets.delete(:model_configs, "test-anthropic")
    end

    test "resolves custom_openai with custom endpoint" do
      with_env([{"OPENAI_API_KEY", "cust-key"}], fn ->
        :ets.insert(
          :model_configs,
          {"custom-model",
           %{
             "type" => "custom_openai",
             "name" => "cust",
             "custom_endpoint" => %{
               "url" => "https://fake.url/v1",
               "headers" => %{"X-Api-Key" => "$OPENAI_API_KEY"},
               "api_key" => "$OPENAI_API_KEY"
             }
           }}
        )

        assert {:ok, handle} = ModelFactory.resolve("custom-model")
        assert handle.base_url == "https://fake.url/v1"
        assert {"X-Api-Key", "cust-key"} in handle.extra_headers
      end)
    after
      :ets.delete(:model_configs, "custom-model")
    end

    test "custom endpoint missing URL returns handle with nil base_url" do
      :ets.insert(
        :model_configs,
        {"custom-no-url",
         %{
           "type" => "custom_openai",
           "name" => "bad",
           "custom_endpoint" => %{"headers" => %{}}
         }}
      )

      assert {:ok, handle} = ModelFactory.resolve("custom-no-url")
      assert handle.base_url == nil
    after
      :ets.delete(:model_configs, "custom-no-url")
    end

    test "azure_openai resolves without azure_endpoint" do
      :ets.insert(
        :model_configs,
        {"az-missing",
         %{
           "type" => "azure_openai",
           "name" => "az",
           "api_version" => "2023-05-15"
         }}
      )

      assert {:ok, handle} = ModelFactory.resolve("az-missing")
      # Without azure_endpoint, base_url comes from provider defaults (nil for azure)
      assert handle.base_url == "https://YOUR_RESOURCE.openai.azure.com"
    after
      :ets.delete(:model_configs, "az-missing")
    end

    test "resolves gemini model" do
      with_env([{"GEMINI_API_KEY", "gem-key"}], fn ->
        :ets.insert(
          :model_configs,
          {"test-gemini", %{"type" => "gemini", "name" => "gemini-pro"}}
        )

        assert {:ok, handle} = ModelFactory.resolve("test-gemini")
        # Gemini uses the Google provider
        assert handle.provider_module == Google
        assert handle.api_key == "gem-key"
      end)
    after
      :ets.delete(:model_configs, "test-gemini")
    end

    test "resolves cerebras model" do
      with_env([{"CEREBRAS_API_KEY", "cerebras-key"}], fn ->
        :ets.insert(
          :model_configs,
          {"test-cerebras", %{"type" => "cerebras", "name" => "llama3"}}
        )

        assert {:ok, handle} = ModelFactory.resolve("test-cerebras")
        assert handle.provider_module == OpenAI
        assert handle.api_key == "cerebras-key"
      end)
    after
      :ets.delete(:model_configs, "test-cerebras")
    end
  end

  # ── resolve!/1 ──────────────────────────────────────────────────────────

  describe "resolve!/1" do
    test "returns handle for valid model" do
      with_env([{"OPENAI_API_KEY", "test"}], fn ->
        :ets.insert(:model_configs, {"resolve-bang", %{"type" => "openai", "name" => "gpt-4o"}})
        assert %Handle{} = ModelFactory.resolve!("resolve-bang")
      end)
    after
      :ets.delete(:model_configs, "resolve-bang")
    end

    test "raises for unknown model" do
      assert_raise RuntimeError, ~r/Failed to resolve model/, fn ->
        ModelFactory.resolve!("definitely-nonexistent")
      end
    end
  end

  # ── Provider Module Lookup ──────────────────────────────────────────────

  describe "provider_module_for_type/1" do
    test "returns OpenAI for openai type" do
      assert {:ok, OpenAI} = ModelFactory.provider_module_for_type("openai")
    end

    test "returns Anthropic for anthropic type" do
      assert {:ok, Anthropic} = ModelFactory.provider_module_for_type("anthropic")
    end

    test "returns OpenAI for custom_openai" do
      assert {:ok, OpenAI} = ModelFactory.provider_module_for_type("custom_openai")
    end

    test "returns Google for gemini type" do
      assert {:ok, Google} = ModelFactory.provider_module_for_type("gemini")
    end

    test "returns error for unknown type" do
      assert :error = ModelFactory.provider_module_for_type("doesnotexist")
    end
  end

  # ── Validate Credentials ───────────────────────────────────────────────

  describe "validate_credentials/1" do
    test "returns error for unknown model" do
      assert {:error, {:unknown_model, "nope"}} = ModelFactory.validate_credentials("nope")
    end

    test "returns :ok when API key is present" do
      with_env([{"OPENAI_API_KEY", "present"}], fn ->
        :ets.insert(:model_configs, {"cred-test", %{"type" => "openai", "name" => "gpt-4o"}})
        assert :ok = ModelFactory.validate_credentials("cred-test")
      end)
    after
      :ets.delete(:model_configs, "cred-test")
    end

    test "returns missing when API key is absent" do
      with_env([{"OPENAI_API_KEY", nil}], fn ->
        :ets.insert(:model_configs, {"cred-missing", %{"type" => "openai", "name" => "gpt-4o"}})
        assert {:missing, ["OPENAI_API_KEY"]} = ModelFactory.validate_credentials("cred-missing")
      end)
    after
      :ets.delete(:model_configs, "cred-missing")
    end
  end

  # ── List Available ─────────────────────────────────────────────────────

  describe "list_available/0" do
    test "returns list of {name, type, module} tuples" do
      with_env([{"OPENAI_API_KEY", "present"}], fn ->
        available = ModelFactory.list_available()
        assert is_list(available)

        Enum.each(available, fn {name, type, mod} ->
          assert is_binary(name)
          assert is_binary(type)
          assert mod in [OpenAI, Anthropic]
        end)
      end)
    end

    test "unauthenticated chatgpt_oauth model does not appear in list_available" do
      # Isolate to empty home so no real chatgpt_oauth.json leaks in
      with_pup_ex_home([], fn ->
        CodePuppyControl.ModelFactory.ProviderRegistry.register("chatgpt_oauth", OpenAI)

        :ets.insert(
          :model_configs,
          {"chatgpt-gpt-5.5", %{"type" => "chatgpt_oauth", "name" => "gpt-5.5"}}
        )

        available = ModelFactory.list_available()

        # Unauthenticated chatgpt_oauth model should NOT appear
        refute Enum.any?(available, fn {n, _, _} -> n == "chatgpt-gpt-5.5" end)
      end)
    after
      :ets.delete(:model_configs, "chatgpt-gpt-5.5")
      CodePuppyControl.ModelFactory.ProviderRegistry.reset_for_test()
    end

    test "authenticated chatgpt_oauth model with account_id appears in list_available" do
      with_pup_ex_home(
        [chatgpt_tokens: %{"access_token" => "valid-token", "account_id" => "acct-xyz"}],
        fn ->
          CodePuppyControl.ModelFactory.ProviderRegistry.register("chatgpt_oauth", OpenAI)

          :ets.insert(
            :model_configs,
            {"chatgpt-gpt-5.5", %{"type" => "chatgpt_oauth", "name" => "gpt-5.5"}}
          )

          available = ModelFactory.list_available()

          # Authenticated chatgpt_oauth model SHOULD appear
          assert Enum.any?(available, fn {n, _, _} -> n == "chatgpt-gpt-5.5" end)
        end
      )
    after
      :ets.delete(:model_configs, "chatgpt-gpt-5.5")
      CodePuppyControl.ModelFactory.ProviderRegistry.reset_for_test()
    end

    test "chatgpt_oauth model with token but no account_id does not appear" do
      with_pup_ex_home(
        [chatgpt_tokens: %{"access_token" => "valid-token"}],
        fn ->
          CodePuppyControl.ModelFactory.ProviderRegistry.register("chatgpt_oauth", OpenAI)

          :ets.insert(
            :model_configs,
            {"chatgpt-gpt-5.5", %{"type" => "chatgpt_oauth", "name" => "gpt-5.5"}}
          )

          available = ModelFactory.list_available()

          # Missing account_id should exclude the model
          refute Enum.any?(available, fn {n, _, _} -> n == "chatgpt-gpt-5.5" end)
        end
      )
    after
      :ets.delete(:model_configs, "chatgpt-gpt-5.5")
      CodePuppyControl.ModelFactory.ProviderRegistry.reset_for_test()
    end
  end

  # ── Handle Struct ──────────────────────────────────────────────────────

  describe "Handle" do
    test "to_provider_opts merges model_opts with api_key and base_url" do
      handle = %Handle{
        model_name: "test",
        provider_module: OpenAI,
        provider_config: %{},
        api_key: "sk-test",
        base_url: "https://api.openai.com",
        model_opts: [model: "gpt-4o", temperature: 0.7]
      }

      opts = Handle.to_provider_opts(handle)
      assert opts[:model] == "gpt-4o"
      assert opts[:temperature] == 0.7
      assert opts[:api_key] == "sk-test"
      assert opts[:base_url] == "https://api.openai.com"
    end

    test "to_provider_opts skips nil api_key and base_url" do
      handle = %Handle{
        model_name: "test",
        provider_module: OpenAI,
        provider_config: %{},
        api_key: nil,
        base_url: nil,
        model_opts: [model: "gpt-4o"]
      }

      opts = Handle.to_provider_opts(handle)
      assert opts[:model] == "gpt-4o"
      refute Keyword.has_key?(opts, :api_key)
      refute Keyword.has_key?(opts, :base_url)
    end
  end
end
