defmodule CodePuppyControl.LLM.ModelRegistryTest do
  @moduledoc """
  Tests for ModelRegistry — ETS-backed model config lookup.

  Covers:
  - get_config returns config for known models
  - get_config returns nil for unknown models
  - get_all_configs returns a map
  - get_model_type extracts type from config
  - type_supported? for known and unknown types
  - list_model_names returns sorted list
  - list_model_types returns unique types
  - reload re-reads config from disk
  - known_model_types returns static list
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.ModelRegistry

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelRegistry)

    # Wait for configs to be populated — there is a window between
    # the GenServer process starting and ETS being populated in init/1.
    # Under concurrent test load, the process may be alive but configs
    # not yet loaded.
    wait_for_configs_populated()

    :ok
  end

  defp wait_for_configs_populated do
    if map_size(ModelRegistry.get_all_configs()) == 0 do
      Process.sleep(10)
      wait_for_configs_populated()
    end
  end

  # ── get_config ──────────────────────────────────────────────────────────

  describe "get_config/1" do
    test "returns config for a model loaded from models.json" do
      # The bundled models.json should have at least one model
      all = ModelRegistry.get_all_configs()
      assert map_size(all) > 0

      # Pick the first model and verify we can get it individually
      {name, config} = Enum.at(all, 0)
      assert ModelRegistry.get_config(name) == config
    end

    test "returns nil for unknown model" do
      assert ModelRegistry.get_config("absolutely-nonexistent-model") == nil
    end

    test "returns nil for non-string input" do
      assert ModelRegistry.get_config(nil) == nil
      assert ModelRegistry.get_config(123) == nil
    end
  end

  # ── get_all_configs ─────────────────────────────────────────────────────

  describe "get_all_configs/0" do
    test "returns a map of model names to config maps" do
      all = ModelRegistry.get_all_configs()
      assert is_map(all)

      Enum.each(all, fn {name, config} ->
        assert is_binary(name)
        assert is_map(config)
      end)
    end
  end

  # ── get_model_type ─────────────────────────────────────────────────────

  describe "get_model_type/1" do
    test "extracts type string from config" do
      assert ModelRegistry.get_model_type(%{"type" => "openai"}) == "openai"
      assert ModelRegistry.get_model_type(%{"type" => "anthropic"}) == "anthropic"
    end

    test "returns nil when type is missing" do
      assert ModelRegistry.get_model_type(%{}) == nil
    end

    test "returns nil for non-map input" do
      assert ModelRegistry.get_model_type(nil) == nil
      assert ModelRegistry.get_model_type("string") == nil
    end
  end

  # ── type_supported? ────────────────────────────────────────────────────

  describe "type_supported?/1" do
    test "returns true for known types" do
      for type <- [
            "openai",
            "anthropic",
            "custom_openai",
            "azure_openai",
            "round_robin",
            "gemini"
          ] do
        assert ModelRegistry.type_supported?(type) == true,
               "Expected type '#{type}' to be supported"
      end
    end

    test "returns false for unknown types" do
      assert ModelRegistry.type_supported?("doesnotexist") == false
      assert ModelRegistry.type_supported?("") == false
    end

    test "returns false for non-string input" do
      assert ModelRegistry.type_supported?(nil) == false
      assert ModelRegistry.type_supported?(123) == false
    end
  end

  # ── list_model_names ───────────────────────────────────────────────────

  describe "list_model_names/0" do
    test "returns sorted list of model names" do
      names = ModelRegistry.list_model_names()
      assert is_list(names)
      assert names == Enum.sort(names)

      Enum.each(names, fn name ->
        assert is_binary(name)
      end)
    end
  end

  # ── list_model_types ───────────────────────────────────────────────────

  describe "list_model_types/0" do
    test "returns unique sorted types from loaded configs" do
      types = ModelRegistry.list_model_types()
      assert is_list(types)
      assert types == Enum.uniq(types)
      assert types == Enum.sort(types)

      Enum.each(types, fn type ->
        assert is_binary(type)
      end)
    end
  end

  # ── known_model_types ──────────────────────────────────────────────────

  describe "known_model_types/0" do
    test "returns list of all known model types" do
      known = ModelRegistry.known_model_types()
      assert is_list(known)
      assert "openai" in known
      assert "anthropic" in known
      assert "round_robin" in known
    end
  end

  # ── reload ─────────────────────────────────────────────────────────────

  describe "reload/0" do
    test "reloads models successfully" do
      assert :ok = ModelRegistry.reload()
      # After reload, we should still have models
      assert map_size(ModelRegistry.get_all_configs()) > 0
    end

    test "model persists across reload" do
      all_before = ModelRegistry.get_all_configs()
      ModelRegistry.reload()
      all_after = ModelRegistry.get_all_configs()

      # All previously loaded models should still be present
      Enum.each(all_before, fn {name, _config} ->
        assert Map.has_key?(all_after, name), "Model '#{name}' lost after reload"
      end)
    end
  end

  # ── ETS Injection ──────────────────────────────────────────────────────

  describe "dynamic model injection" do
    test "injected model is retrievable via get_config" do
      :ets.insert(:model_configs, {"dynamic-test-model", %{"type" => "openai", "name" => "dyn"}})
      assert ModelRegistry.get_config("dynamic-test-model") != nil
    after
      :ets.delete(:model_configs, "dynamic-test-model")
    end

    test "injected model appears in list_model_names" do
      :ets.insert(:model_configs, {"listed-test-model", %{"type" => "openai", "name" => "list"}})
      names = ModelRegistry.list_model_names()
      assert "listed-test-model" in names
    after
      :ets.delete(:model_configs, "listed-test-model")
    end
  end
end
