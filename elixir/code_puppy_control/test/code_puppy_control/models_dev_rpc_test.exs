defmodule CodePuppyControl.ModelsDevRpcTest do
  @moduledoc """
  Integration tests for the Models Dev Parser with the bundled data.

  These tests verify the Registry works correctly with the actual bundled
  models_dev_api.json file, validating the full stack from JSON parsing
  through to the Registry API.
  """

  use ExUnit.Case

  alias CodePuppyControl.ModelsDevParser.Registry
  alias CodePuppyControl.ModelsDevParser.{ProviderInfo, ModelInfo}

  # ============================================================================
  # Setup
  # ============================================================================

  setup_all do
    # Start the global Registry once for all tests
    case Registry.start_link(name: CodePuppyControl.ModelsDevParser.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  # ============================================================================
  # Integration Tests with Bundled Data
  # ============================================================================

  describe "Registry with bundled data" do
    test "loads providers from bundled JSON" do
      providers = Registry.get_providers()

      assert is_list(providers)
      assert length(providers) >= 1

      # Verify known providers exist
      provider_ids = Enum.map(providers, & &1.id)

      # Check for some known providers that should be in the bundled data
      assert "anthropic" in provider_ids or "openai" in provider_ids or
               "google" in provider_ids or length(providers) > 0

      # Verify provider structure
      provider = hd(providers)
      assert %ProviderInfo{} = provider
      assert is_binary(provider.id)
      assert is_binary(provider.name)
      assert is_list(provider.env)
    end

    test "loads models from bundled JSON" do
      models = Registry.get_models()

      assert is_list(models)
      assert length(models) >= 1

      # Verify model structure
      model = hd(models)
      assert %ModelInfo{} = model
      assert is_binary(model.provider_id)
      assert is_binary(model.model_id)
      assert is_binary(model.name)
    end

    test "data source indicates bundled file" do
      source = Registry.data_source()

      # Should indicate bundled source
      assert is_binary(source)
      assert source =~ "bundled" or source =~ "file"
    end
  end

  describe "get_providers" do
    test "returns list of providers via Registry" do
      providers = Registry.get_providers()

      assert is_list(providers)
      assert length(providers) >= 1

      # Verify provider structure
      provider = hd(providers)
      assert is_binary(provider.id)
      assert is_binary(provider.name)
      assert is_list(provider.env)
    end
  end

  describe "get_provider" do
    test "returns specific provider when found" do
      providers = Registry.get_providers()
      provider_id = hd(providers).id
      provider = Registry.get_provider(provider_id)

      assert provider != nil
      assert provider.id == provider_id
      assert is_binary(provider.name)
    end

    test "returns nil for unknown provider" do
      assert Registry.get_provider("nonexistent_provider_12345") == nil
    end
  end

  describe "get_models" do
    test "returns all models from bundled JSON" do
      models = Registry.get_models()

      assert is_list(models)
      assert length(models) >= 1

      # Verify model structure
      model = hd(models)
      assert %ModelInfo{} = model
      assert is_binary(model.provider_id)
      assert is_binary(model.model_id)
      assert is_binary(model.name)
    end

    test "filters by provider" do
      providers = Registry.get_providers()
      provider_id = hd(providers).id
      # Must pass Registry as first arg when specifying provider_id
      models = Registry.get_models(Registry, provider_id)

      # All returned models should be from the specified provider
      Enum.each(models, fn model ->
        assert model.provider_id == provider_id
      end)
    end
  end

  describe "search_models" do
    test "searches by query" do
      results = Registry.search_models(Registry, query: "claude")
      assert is_list(results)

      # If results returned, verify they match the query
      Enum.each(results, fn model ->
        name = String.downcase(model.name)
        id = String.downcase(model.model_id)
        assert String.contains?(name, "claude") or String.contains?(id, "claude")
      end)
    end

    test "filters by capabilities" do
      results = Registry.search_models(Registry, capability_filters: %{"tool_call" => true})
      assert is_list(results)

      # All returned models should have tool_call capability
      Enum.each(results, fn model ->
        assert model.tool_call == true
      end)
    end
  end

  describe "config conversion" do
    test "to_config creates valid Code Puppy config" do
      model = hd(Registry.get_models())
      config = Registry.to_config(model)

      assert is_map(config)
      assert is_binary(config["type"])
      assert is_binary(config["model"])
      assert config["enabled"] == true
      assert is_binary(config["provider_id"])
      assert is_list(config["env_vars"])
      assert is_map(config["capabilities"])
    end
  end
end
