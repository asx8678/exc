defmodule CodePuppyControl.ModelFactory.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.ModelFactory.ProviderRegistry
  alias CodePuppyControl.LLM.Providers.{OpenAI, Anthropic, Google, Azure, Groq, Together}

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ProviderRegistry)
    ProviderRegistry.reset_for_test()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Built-in parity: registry matches ModelFactory.@provider_map exactly
  # ---------------------------------------------------------------------------

  describe "built-in parity with ModelFactory.@provider_map" do
    test "all 16 built-in types are present" do
      types = ProviderRegistry.built_in_types()
      assert length(types) == 16
    end

    test "openai -> OpenAI" do
      assert {:ok, OpenAI} = ProviderRegistry.lookup("openai")
    end

    test "anthropic -> Anthropic" do
      assert {:ok, Anthropic} = ProviderRegistry.lookup("anthropic")
    end

    test "custom_openai -> OpenAI" do
      assert {:ok, OpenAI} = ProviderRegistry.lookup("custom_openai")
    end

    test "custom_anthropic -> Anthropic" do
      assert {:ok, Anthropic} = ProviderRegistry.lookup("custom_anthropic")
    end

    test "azure_openai -> Azure" do
      assert {:ok, Azure} = ProviderRegistry.lookup("azure_openai")
    end

    test "cerebras -> OpenAI" do
      assert {:ok, OpenAI} = ProviderRegistry.lookup("cerebras")
    end

    test "zai_coding -> OpenAI" do
      assert {:ok, OpenAI} = ProviderRegistry.lookup("zai_coding")
    end

    test "zai_api -> OpenAI" do
      assert {:ok, OpenAI} = ProviderRegistry.lookup("zai_api")
    end

    test "openrouter -> OpenAI" do
      assert {:ok, OpenAI} = ProviderRegistry.lookup("openrouter")
    end

    test "gemini -> Google" do
      assert {:ok, Google} = ProviderRegistry.lookup("gemini")
    end

    test "gemini_oauth -> Google" do
      assert {:ok, Google} = ProviderRegistry.lookup("gemini_oauth")
    end

    test "custom_gemini -> Google" do
      assert {:ok, Google} = ProviderRegistry.lookup("custom_gemini")
    end

    test "claude_code -> Anthropic" do
      assert {:ok, Anthropic} = ProviderRegistry.lookup("claude_code")
    end

    test "chatgpt_oauth -> OpenAI" do
      assert {:ok, OpenAI} = ProviderRegistry.lookup("chatgpt_oauth")
    end

    test "groq -> Groq" do
      assert {:ok, Groq} = ProviderRegistry.lookup("groq")
    end

    test "together -> Together" do
      assert {:ok, Together} = ProviderRegistry.lookup("together")
    end
  end

  # ---------------------------------------------------------------------------
  # built_in_types/0 — sorted, deterministic, no runtime registrations
  # ---------------------------------------------------------------------------

  describe "built_in_types/0" do
    test "returns a sorted list of strings" do
      types = ProviderRegistry.built_in_types()
      assert types == Enum.sort(types)
      assert Enum.all?(types, &is_binary/1)
    end

    test "is deterministic across calls" do
      first = ProviderRegistry.built_in_types()
      second = ProviderRegistry.built_in_types()
      assert first == second
    end

    test "does not include runtime-registered types" do
      :ok = ProviderRegistry.register("my_custom", SomeModule)
      types = ProviderRegistry.built_in_types()
      refute "my_custom" in types
    end
  end

  # ---------------------------------------------------------------------------
  # all/0 — full current map including runtime registrations
  # ---------------------------------------------------------------------------

  describe "all/0" do
    test "returns a map with all built-in types as keys" do
      map = ProviderRegistry.all()
      built_ins = ProviderRegistry.built_in_types()

      Enum.each(built_ins, fn type ->
        assert Map.has_key?(map, type), "Missing built-in type: #{type}"
      end)
    end

    test "includes runtime-registered types" do
      :ok = ProviderRegistry.register("my_custom", SomeModule)
      map = ProviderRegistry.all()
      assert map["my_custom"] == SomeModule
    end

    test "does not include types after reset_for_test" do
      :ok = ProviderRegistry.register("my_custom", SomeModule)
      :ok = ProviderRegistry.reset_for_test()
      map = ProviderRegistry.all()
      refute Map.has_key?(map, "my_custom")
    end
  end

  # ---------------------------------------------------------------------------
  # lookup/1 — success and failure
  # ---------------------------------------------------------------------------

  describe "lookup/1" do
    test "returns {:ok, module} for known type" do
      assert {:ok, OpenAI} = ProviderRegistry.lookup("openai")
    end

    test "returns :error for unknown type" do
      assert :error = ProviderRegistry.lookup("nonexistent_provider")
    end

    test "returns :error for empty string" do
      assert :error = ProviderRegistry.lookup("")
    end
  end

  # ---------------------------------------------------------------------------
  # supported?/1 — boolean check
  # ---------------------------------------------------------------------------

  describe "supported?/1" do
    test "returns true for built-in types" do
      assert ProviderRegistry.supported?("openai")
      assert ProviderRegistry.supported?("anthropic")
      assert ProviderRegistry.supported?("gemini")
    end

    test "returns false for unknown types" do
      refute ProviderRegistry.supported?("fantasy_provider")
    end

    test "returns true for runtime-registered types" do
      refute ProviderRegistry.supported?("runtime_added")
      :ok = ProviderRegistry.register("runtime_added", SomeModule)
      assert ProviderRegistry.supported?("runtime_added")
    end
  end

  # ---------------------------------------------------------------------------
  # register/2 — add, override, validation
  # ---------------------------------------------------------------------------

  describe "register/2" do
    test "adds a new provider mapping" do
      assert :ok = ProviderRegistry.register("my_new_provider", MyTestProvider)
      assert {:ok, MyTestProvider} = ProviderRegistry.lookup("my_new_provider")
    end

    test "overrides an existing built-in mapping" do
      assert :ok = ProviderRegistry.register("openai", FakeOpenAI)
      assert {:ok, FakeOpenAI} = ProviderRegistry.lookup("openai")
    end

    test "rejects empty string type" do
      assert {:error, :empty_type} = ProviderRegistry.register("", SomeModule)
    end

    test "rejects non-atom module" do
      assert {:error, :invalid_module} = ProviderRegistry.register("valid_type", "not_a_module")
    end

    test "rejects non-binary type" do
      assert {:error, :invalid_type} = ProviderRegistry.register(:atom_type, SomeModule)
    end

    test "rejects both non-binary type and non-atom module" do
      assert {:error, :invalid_type} = ProviderRegistry.register(123, "nope")
    end

    test "nil module is rejected" do
      assert {:error, :invalid_module} = ProviderRegistry.register("my_type", nil)
    end
  end

  # ---------------------------------------------------------------------------
  # reset_for_test/0 — restore built-ins, remove runtime additions
  # ---------------------------------------------------------------------------

  describe "reset_for_test/0" do
    test "removes runtime-registered providers" do
      :ok = ProviderRegistry.register("custom_plugin", CustomPlugin)
      assert ProviderRegistry.supported?("custom_plugin")

      :ok = ProviderRegistry.reset_for_test()
      refute ProviderRegistry.supported?("custom_plugin")
    end

    test "restores overridden built-in mappings" do
      :ok = ProviderRegistry.register("openai", FakeOpenAI)
      assert {:ok, FakeOpenAI} = ProviderRegistry.lookup("openai")

      :ok = ProviderRegistry.reset_for_test()
      assert {:ok, OpenAI} = ProviderRegistry.lookup("openai")
    end

    test "is idempotent" do
      :ok = ProviderRegistry.reset_for_test()
      :ok = ProviderRegistry.reset_for_test()
      assert {:ok, OpenAI} = ProviderRegistry.lookup("openai")
    end

    test "all/0 after reset matches built-in count" do
      :ok = ProviderRegistry.register("extra_one", Module1)
      :ok = ProviderRegistry.register("extra_two", Module2)

      :ok = ProviderRegistry.reset_for_test()
      map = ProviderRegistry.all()
      assert map_size(map) == length(ProviderRegistry.built_in_types())
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic sorted outputs
  # ---------------------------------------------------------------------------

  describe "deterministic sorted outputs" do
    test "built_in_types/0 returns alphabetically sorted list" do
      types = ProviderRegistry.built_in_types()

      expected =
        [
          "anthropic",
          "azure_openai",
          "cerebras",
          "chatgpt_oauth",
          "claude_code",
          "custom_anthropic",
          "custom_gemini",
          "custom_openai",
          "gemini",
          "gemini_oauth",
          "groq",
          "openai",
          "openrouter",
          "together",
          "zai_api",
          "zai_coding"
        ]

      assert types == expected
    end

    test "all/0 keys are the same as built_in_types after reset" do
      :ok = ProviderRegistry.reset_for_test()
      all_keys = ProviderRegistry.all() |> Map.keys() |> Enum.sort()
      assert all_keys == ProviderRegistry.built_in_types()
    end
  end
end
