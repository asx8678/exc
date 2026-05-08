defmodule CodePuppyControl.ModelRegistryTest do
  @moduledoc """
  Tests for the ModelRegistry GenServer.

  Covers:
  - GenServer startup and initialization
  - Config loading and retrieval
  - Reload functionality
  - Model type resolution
  - Type supported checks
  - Listing model names and types
  - Concurrent read access
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.ModelRegistry

  # ============================================================================
  # Startup Tests
  # ============================================================================

  describe "startup" do
    test "starts successfully and loads bundled models" do
      # The registry should have started in setup and loaded models
      configs = ModelRegistry.get_all_configs()
      assert is_map(configs)
      assert map_size(configs) >= 3
    end

    test "loaded models have expected keys" do
      config = ModelRegistry.get_config("wafer-glm-5.1")
      assert is_map(config)
      assert config["type"] == "custom_openai"
      assert config["provider"] == "wafer"
      assert config["name"] == "GLM-5.1"
      assert config["context_length"] == 200_000
    end
  end

  # ============================================================================
  # Config Retrieval Tests
  # ============================================================================

  describe "get_config/1" do
    test "returns config for known model" do
      config = ModelRegistry.get_config("firepass-kimi-k2p5-turbo")
      assert is_map(config)
      assert config["type"] == "custom_openai"
      assert config["provider"] == "firepass"
    end

    test "returns nil for unknown model" do
      assert ModelRegistry.get_config("totally-unknown-model-12345") == nil
    end

    test "handles multiple model lookups" do
      models = [
        "firepass-kimi-k2p5-turbo",
        "wafer-qwen3.5-397b",
        "wafer-glm-5.1"
      ]

      for model <- models do
        config = ModelRegistry.get_config(model)
        assert is_map(config), "Expected config for #{model}"
        assert config["type"] == "custom_openai"
      end
    end
  end

  describe "get_all_configs/0" do
    test "returns all configs as a map" do
      configs = ModelRegistry.get_all_configs()
      assert is_map(configs)

      # Should include all bundled models
      assert "wafer-glm-5.1" in Map.keys(configs)
      assert "firepass-kimi-k2p5-turbo" in Map.keys(configs)

      # Each config should be a map
      for {name, config} <- configs do
        assert is_binary(name)
        assert is_map(config)
        assert config["type"] != nil, "Model #{name} should have a type"
      end
    end
  end

  # ============================================================================
  # Reload Tests
  # ============================================================================

  describe "reload/0" do
    test "reloads configs successfully" do
      # Get initial count
      initial_count = ModelRegistry.get_all_configs() |> map_size()
      assert initial_count > 0

      # Reload
      assert :ok = ModelRegistry.reload()

      # Verify configs still loaded
      new_count = ModelRegistry.get_all_configs() |> map_size()
      assert new_count == initial_count
    end

    test "reload refreshes data (can pick up changes if files change)" do
      # This test verifies the reload mechanism works
      # In a real scenario, files could change between reloads

      # Verify initial state
      assert is_map(ModelRegistry.get_all_configs())

      # Reload should succeed
      assert :ok = ModelRegistry.reload()

      # Verify still works after reload
      assert is_map(ModelRegistry.get_all_configs())
      assert ModelRegistry.get_config("wafer-glm-5.1") != nil
    end
  end

  # ============================================================================
  # Model Type Tests
  # ============================================================================

  describe "get_model_type/1" do
    test "extracts type from config" do
      assert ModelRegistry.get_model_type(%{"type" => "openai"}) == "openai"
      assert ModelRegistry.get_model_type(%{"type" => "anthropic"}) == "anthropic"
      assert ModelRegistry.get_model_type(%{"type" => "zai_coding"}) == "zai_coding"
    end

    test "returns nil for config without type" do
      assert ModelRegistry.get_model_type(%{"name" => "test"}) == nil
      assert ModelRegistry.get_model_type(%{}) == nil
    end

    test "returns nil for invalid input" do
      assert ModelRegistry.get_model_type(nil) == nil
      assert ModelRegistry.get_model_type("string") == nil
      assert ModelRegistry.get_model_type(123) == nil
    end

    test "works with actual loaded configs" do
      config = ModelRegistry.get_config("wafer-glm-5.1")
      assert ModelRegistry.get_model_type(config) == "custom_openai"
    end
  end

  describe "type_supported?/1" do
    test "returns true for known types" do
      known_types = [
        "openai",
        "anthropic",
        "custom_anthropic",
        "azure_openai",
        "custom_openai",
        "zai_coding",
        "zai_api",
        "cerebras",
        "claude_code",
        "openrouter",
        "round_robin",
        "gemini",
        "gemini_oauth",
        "custom_gemini"
      ]

      for type <- known_types do
        assert ModelRegistry.type_supported?(type), "Type #{type} should be supported"
      end
    end

    test "returns false for unknown types" do
      refute ModelRegistry.type_supported?("unknown_type")
      refute ModelRegistry.type_supported?("random_type_123")
      refute ModelRegistry.type_supported?("")
    end

    test "handles edge cases" do
      refute ModelRegistry.type_supported?(nil)
      refute ModelRegistry.type_supported?(123)
      refute ModelRegistry.type_supported?(:atom)
    end
  end

  describe "known_model_types/0" do
    test "returns all known model types" do
      types = ModelRegistry.known_model_types()
      assert is_list(types)
      assert length(types) >= 10

      # Verify it includes all expected types
      assert "openai" in types
      assert "anthropic" in types
      assert "zai_coding" in types
      assert "round_robin" in types
    end
  end

  describe "list_model_types/0" do
    test "returns types from currently loaded configs" do
      types = ModelRegistry.list_model_types()
      assert is_list(types)

      # Based on bundled models.json, should have custom_openai type
      assert "custom_openai" in types
    end

    test "returns only unique types" do
      types = ModelRegistry.list_model_types()
      unique_types = Enum.uniq(types)
      assert length(types) == length(unique_types)
    end
  end

  # ============================================================================
  # Listing Tests
  # ============================================================================

  describe "list_model_names/0" do
    test "returns all model names" do
      names = ModelRegistry.list_model_names()
      assert is_list(names)
      assert length(names) >= 3

      # Check for expected models from bundled models.json
      assert "firepass-kimi-k2p5-turbo" in names
      assert "wafer-qwen3.5-397b" in names
      assert "wafer-glm-5.1" in names
    end

    test "returns sorted list" do
      names = ModelRegistry.list_model_names()
      assert names == Enum.sort(names)
    end

    test "returns consistent results after reload" do
      names_before = ModelRegistry.list_model_names()
      ModelRegistry.reload()
      names_after = ModelRegistry.list_model_names()

      assert names_before == names_after
    end
  end

  # ============================================================================
  # Concurrent Access Tests
  # ============================================================================

  describe "concurrent reads" do
    test "handles concurrent config lookups" do
      # Create 100 concurrent tasks that all read configs
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            ModelRegistry.get_config("wafer-glm-5.1")
          end)
        end

      results = Task.await_many(tasks)

      # All should return the same config
      first_result = hd(results)
      assert is_map(first_result)
      assert first_result["type"] == "custom_openai"

      # Verify all results are identical
      assert Enum.all?(results, fn r -> r == first_result end)
    end

    test "handles concurrent list operations" do
      # Mix of get_all_configs and list_model_names concurrently
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              ModelRegistry.get_all_configs() |> map_size()
            else
              ModelRegistry.list_model_names() |> length()
            end
          end)
        end

      results = Task.await_many(tasks)

      # All should return positive counts
      assert Enum.all?(results, fn count -> count >= 3 end)
    end

    test "reads during reload are safe" do
      # Start a bunch of concurrent readers
      reader_tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            for _ <- 1..10 do
              _ = ModelRegistry.get_config("wafer-glm-5.1")
              _ = ModelRegistry.list_model_names()
              :ok
            end
          end)
        end

      # Trigger a reload while reads are happening
      :ok = ModelRegistry.reload()

      # Wait for all readers to complete
      results = Task.await_many(reader_tasks)

      # Each task returns a list of :ok results (10 per task)
      assert Enum.all?(results, fn task_results ->
               is_list(task_results) and Enum.all?(task_results, &(&1 == :ok))
             end)

      # Verify data integrity after reload
      configs = ModelRegistry.get_all_configs()
      assert map_size(configs) >= 3
      assert ModelRegistry.get_config("wafer-glm-5.1") != nil
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration with actual loaded data" do
    test "loaded bundled models have correct structure" do
      bundled_models = [
        "firepass-kimi-k2p5-turbo",
        "wafer-qwen3.5-397b",
        "wafer-glm-5.1"
      ]

      for model_name <- bundled_models do
        config = ModelRegistry.get_config(model_name)
        assert is_map(config), "Expected config for #{model_name}"

        # Verify required keys
        assert config["type"] != nil, "#{model_name} should have a type"
        assert config["type"] == "custom_openai", "#{model_name} should have type 'custom_openai'"
        assert is_integer(config["context_length"]), "#{model_name} should have context_length"
      end
    end

    test "loaded firepass model has correct structure" do
      config = ModelRegistry.get_config("firepass-kimi-k2p5-turbo")
      assert config["type"] == "custom_openai"
      assert config["provider"] == "firepass"
      assert config["context_length"] == 262_144

      # Check custom_endpoint structure
      assert is_map(config["custom_endpoint"])
      assert config["custom_endpoint"]["url"] == "https://api.fireworks.ai/inference/v1"
      assert config["custom_endpoint"]["api_key"] == "$FIREWORKS_API_KEY"
    end

    test "list_model_types matches actual loaded configs" do
      # Get all types from loaded configs
      loaded_types = ModelRegistry.list_model_types()

      # Get all configs and extract types manually
      configs = ModelRegistry.get_all_configs()

      extracted_types =
        configs
        |> Map.values()
        |> Enum.map(&Map.get(&1, "type"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      assert loaded_types == extracted_types
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles model names with special characters" do
      # Verify that existing models with dashes and dots work
      assert ModelRegistry.get_config("wafer-glm-5.1") != nil
      assert ModelRegistry.get_config("firepass-kimi-k2p5-turbo") != nil
    end

    test "empty string model name returns nil" do
      assert ModelRegistry.get_config("") == nil
    end

    test "very long model name returns nil" do
      long_name = String.duplicate("a", 1000)
      assert ModelRegistry.get_config(long_name) == nil
    end

    test "non-binary model name returns nil" do
      assert ModelRegistry.get_config(nil) == nil
      assert ModelRegistry.get_config(123) == nil
      assert ModelRegistry.get_config(:atom) == nil
      assert ModelRegistry.get_config(["list"]) == nil
      assert ModelRegistry.get_config(%{}) == nil
    end
  end

  # ============================================================================
  # Overlay File Loading Tests
  # ============================================================================

  describe "overlay file loading" do
    @tag :tmp_dir
    test "loads overlay models from extra_models.json via Paths", %{tmp_dir: tmp_dir} do
      overlay_content =
        Jason.encode!(%{
          "test-overlay-model" => %{
            "type" => "openai",
            "provider" => "test",
            "name" => "test-model",
            "context_length" => 128_000
          }
        })

      File.write!(Path.join(tmp_dir, "extra_models.json"), overlay_content)

      old_home = System.get_env("PUP_EX_HOME")
      System.put_env("PUP_EX_HOME", tmp_dir)

      try do
        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("test-overlay-model")
        assert is_map(config)
        assert config["type"] == "openai"
        assert config["provider"] == "test"
      after
        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        ModelRegistry.reload()
      end
    end

    @tag :tmp_dir
    test "later overlays win on key conflicts (merge precedence)", %{tmp_dir: tmp_dir} do
      first_overlay =
        Jason.encode!(%{
          "conflict-model" => %{
            "type" => "openai",
            "provider" => "first",
            "name" => "first-version",
            "context_length" => 1000
          }
        })

      second_overlay =
        Jason.encode!(%{
          "conflict-model" => %{
            "type" => "anthropic",
            "provider" => "second",
            "name" => "second-version",
            "context_length" => 2000
          }
        })

      File.write!(Path.join(tmp_dir, "extra_models.json"), first_overlay)
      File.write!(Path.join(tmp_dir, "claude_models.json"), second_overlay)

      old_home = System.get_env("PUP_EX_HOME")
      System.put_env("PUP_EX_HOME", tmp_dir)

      try do
        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("conflict-model")
        assert config["type"] == "anthropic"
        assert config["provider"] == "second"
        assert config["context_length"] == 2000
      after
        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        ModelRegistry.reload()
      end
    end

    @tag :tmp_dir
    test "malformed overlay JSON is skipped without crashing", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "extra_models.json"), "not valid json {[")

      valid_overlay =
        Jason.encode!(%{
          "valid-model" => %{
            "type" => "openai",
            "provider" => "test",
            "name" => "valid",
            "context_length" => 128_000
          }
        })

      File.write!(Path.join(tmp_dir, "claude_models.json"), valid_overlay)

      old_home = System.get_env("PUP_EX_HOME")
      System.put_env("PUP_EX_HOME", tmp_dir)

      try do
        assert :ok = ModelRegistry.reload()

        assert ModelRegistry.get_config("valid-model") != nil
        assert ModelRegistry.get_all_configs() != nil
      after
        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        ModelRegistry.reload()
      end
    end

    @tag :tmp_dir
    test "non-object JSON in overlay is skipped", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "extra_models.json"), "[\"not\", \"an\", \"object\"]")

      old_home = System.get_env("PUP_EX_HOME")
      System.put_env("PUP_EX_HOME", tmp_dir)

      try do
        assert :ok = ModelRegistry.reload()
        assert ModelRegistry.get_config("wafer-glm-5.1") != nil
      after
        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        ModelRegistry.reload()
      end
    end

    @tag :tmp_dir
    test "loads claude_code models from claude_models.json overlay", %{tmp_dir: tmp_dir} do
      claude_overlay =
        Jason.encode!(%{
          "claude-code-claude-opus-4-7" => %{
            "type" => "claude_code",
            "name" => "claude-opus-4-7",
            "custom_endpoint" => %{
              "url" => "https://api.anthropic.com",
              "api_key" => "test-key"
            },
            "context_length" => 200_000,
            "oauth_source" => "claude-code-plugin",
            "supported_settings" => ["temperature", "extended_thinking"]
          }
        })

      File.write!(Path.join(tmp_dir, "claude_models.json"), claude_overlay)

      old_home = System.get_env("PUP_EX_HOME")
      System.put_env("PUP_EX_HOME", tmp_dir)

      try do
        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("claude-code-claude-opus-4-7")
        assert is_map(config)
        assert config["type"] == "claude_code"
        assert config["name"] == "claude-opus-4-7"
        assert config["context_length"] == 200_000
        assert config["oauth_source"] == "claude-code-plugin"
        assert config["supported_settings"] == ["temperature", "extended_thinking"]

        # Verify custom_endpoint structure
        assert is_map(config["custom_endpoint"])
        assert config["custom_endpoint"]["url"] == "https://api.anthropic.com"
        assert config["custom_endpoint"]["api_key"] == "test-key"
      after
        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        ModelRegistry.reload()
      end
    end
  end

  # ============================================================================
  # Reload Error Path Tests
  # ============================================================================

  describe "reload/0 error path" do
    test "returns {:error, reason} when bundled JSON is missing and no overlays" do
      # Save original config
      original_path = Application.get_env(:code_puppy_control, :bundled_models_path)
      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      # Use empty tmp dirs so no overlays exist either
      tmp_elixir =
        Path.join(System.tmp_dir!(), "mr_err_#{:erlang.unique_integer([:positive])}")

      tmp_legacy =
        Path.join(System.tmp_dir!(), "mr_err_legacy_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_elixir)
      File.mkdir_p!(tmp_legacy)

      try do
        Application.put_env(
          :code_puppy_control,
          :bundled_models_path,
          "/tmp/nonexistent_models.json"
        )

        System.put_env("PUP_EX_HOME", tmp_elixir)
        Application.put_env(:code_puppy_control, :legacy_home_dir, tmp_legacy)

        result = ModelRegistry.reload()
        assert {:error, _reason} = result
      after
        # Restore
        if original_path,
          do: Application.put_env(:code_puppy_control, :bundled_models_path, original_path),
          else: Application.delete_env(:code_puppy_control, :bundled_models_path)

        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(tmp_elixir)
        File.rm_rf!(tmp_legacy)

        ModelRegistry.reload()
      end
    end
  end

  # ==========================================================================
  # models.json Loading Tests (legacy + Elixir home)
  # ==========================================================================

  describe "models.json loading from legacy and Elixir homes" do
    test "loads models.json from legacy home via Application env override" do
      legacy_home =
        Path.join(System.tmp_dir!(), "mr_legacy_mdl_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(legacy_home)

      models_content =
        Jason.encode!(%{
          "legacy-main-model" => %{
            "type" => "openai",
            "provider" => "legacy-main",
            "name" => "legacy-main-v1",
            "context_length" => 128_000
          }
        })

      File.write!(Path.join(legacy_home, "models.json"), models_content)

      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      # Use an empty Elixir home so only the legacy models.json loads
      elixir_home =
        Path.join(System.tmp_dir!(), "mr_elixir_mdl_empty_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(elixir_home)

      try do
        Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)
        System.put_env("PUP_EX_HOME", elixir_home)

        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("legacy-main-model")
        assert is_map(config)
        assert config["type"] == "openai"
        assert config["provider"] == "legacy-main"
      after
        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(legacy_home)
        File.rm_rf!(elixir_home)
        ModelRegistry.reload()
      end
    end

    test "loads models.json from Elixir home via PUP_EX_HOME" do
      elixir_home =
        Path.join(System.tmp_dir!(), "mr_elixir_mdl_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(elixir_home)

      models_content =
        Jason.encode!(%{
          "elixir-main-model" => %{
            "type" => "anthropic",
            "provider" => "elixir-main",
            "name" => "elixir-main-v1",
            "context_length" => 200_000
          }
        })

      File.write!(Path.join(elixir_home, "models.json"), models_content)

      old_home = System.get_env("PUP_EX_HOME")

      try do
        System.put_env("PUP_EX_HOME", elixir_home)

        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("elixir-main-model")
        assert is_map(config)
        assert config["type"] == "anthropic"
        assert config["provider"] == "elixir-main"
      after
        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(elixir_home)
        ModelRegistry.reload()
      end
    end

    test "Elixir home models.json wins over legacy home models.json on conflicts" do
      legacy_home =
        Path.join(System.tmp_dir!(), "mr_legacy_mdl_c_#{:erlang.unique_integer([:positive])}")

      elixir_home =
        Path.join(System.tmp_dir!(), "mr_elixir_mdl_c_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(legacy_home)
      File.mkdir_p!(elixir_home)

      legacy_models =
        Jason.encode!(%{
          "shared-model" => %{
            "type" => "openai",
            "provider" => "legacy",
            "name" => "legacy-version",
            "context_length" => 64_000
          }
        })

      elixir_models =
        Jason.encode!(%{
          "shared-model" => %{
            "type" => "anthropic",
            "provider" => "elixir",
            "name" => "elixir-version",
            "context_length" => 200_000
          }
        })

      File.write!(Path.join(legacy_home, "models.json"), legacy_models)
      File.write!(Path.join(elixir_home, "models.json"), elixir_models)

      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      try do
        Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)
        System.put_env("PUP_EX_HOME", elixir_home)

        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("shared-model")
        # Elixir-home models.json wins (loaded after legacy)
        assert config["type"] == "anthropic"
        assert config["provider"] == "elixir"
        assert config["context_length"] == 200_000
      after
        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(legacy_home)
        File.rm_rf!(elixir_home)
        ModelRegistry.reload()
      end
    end

    test "full precedence: bundled → legacy models → legacy extra → Elixir models → Elixir extra" do
      legacy_home =
        Path.join(System.tmp_dir!(), "mr_legacy_prec_#{:erlang.unique_integer([:positive])}")

      elixir_home =
        Path.join(System.tmp_dir!(), "mr_elixir_prec_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(legacy_home)
      File.mkdir_p!(elixir_home)

      # Legacy models.json defines a model that overrides a bundled model
      File.write!(
        Path.join(legacy_home, "models.json"),
        Jason.encode!(%{
          "wafer-glm-5.1" => %{
            "type" => "custom_openai",
            "provider" => "legacy-override",
            "name" => "GLM-5.1-legacy"
          },
          "legacy-unique" => %{"type" => "openai", "provider" => "legacy"}
        })
      )

      # Legacy extra_models.json overrides the legacy models.json value
      File.write!(
        Path.join(legacy_home, "extra_models.json"),
        Jason.encode!(%{
          "wafer-glm-5.1" => %{
            "type" => "custom_openai",
            "provider" => "legacy-extra-override",
            "name" => "GLM-5.1-legacy-extra"
          }
        })
      )

      # Elixir models.json overrides all legacy
      File.write!(
        Path.join(elixir_home, "models.json"),
        Jason.encode!(%{
          "wafer-glm-5.1" => %{
            "type" => "custom_openai",
            "provider" => "elixir-override",
            "name" => "GLM-5.1-elixir"
          },
          "elixir-unique" => %{"type" => "anthropic", "provider" => "elixir"}
        })
      )

      # Elixir extra_models.json overrides Elixir models.json
      File.write!(
        Path.join(elixir_home, "extra_models.json"),
        Jason.encode!(%{
          "wafer-glm-5.1" => %{
            "type" => "custom_openai",
            "provider" => "elixir-extra-override",
            "name" => "GLM-5.1-elixir-extra"
          }
        })
      )

      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      try do
        Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)
        System.put_env("PUP_EX_HOME", elixir_home)

        assert :ok = ModelRegistry.reload()

        # Elixir extra_models.json wins (highest precedence)
        config = ModelRegistry.get_config("wafer-glm-5.1")
        assert config["provider"] == "elixir-extra-override"
        assert config["name"] == "GLM-5.1-elixir-extra"

        # Both legacy and Elixir unique models are present
        assert ModelRegistry.get_config("legacy-unique") != nil
        assert ModelRegistry.get_config("elixir-unique") != nil
      after
        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(legacy_home)
        File.rm_rf!(elixir_home)
        ModelRegistry.reload()
      end
    end

    test "legacy models.json via override dir bypasses Isolation guard (expected — not real ~/.code_puppy)" do
      # When the path is under real ~/.code_puppy, safe_read_file routes
      # through Isolation.read_only_legacy/1. This test uses a test override
      # dir (NOT under real ~/.code_puppy) which correctly goes through
      # File.read/1 — verifying the override mechanism works for tests.
      legacy_home =
        Path.join(System.tmp_dir!(), "mr_legacy_iso_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(legacy_home)

      File.write!(
        Path.join(legacy_home, "models.json"),
        Jason.encode!(%{
          "iso-test-model" => %{"type" => "openai", "provider" => "iso-test"}
        })
      )

      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      elixir_home =
        Path.join(System.tmp_dir!(), "mr_elixir_iso_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(elixir_home)

      try do
        Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)
        System.put_env("PUP_EX_HOME", elixir_home)

        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("iso-test-model")
        assert is_map(config)
        assert config["provider"] == "iso-test"
      after
        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(legacy_home)
        File.rm_rf!(elixir_home)
        ModelRegistry.reload()
      end
    end
  end

  # ==========================================================================
  # Legacy Overlay Tests
  # ==========================================================================

  describe "legacy home overlay loading" do
    @tag :tmp_dir
    test "loads overlay from legacy home when base models file is missing", %{tmp_dir: tmp_dir} do
      # Setup: tmp dir as legacy home with an extra_models.json
      legacy_home =
        Path.join(System.tmp_dir!(), "mr_legacy_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(legacy_home)

      overlay_content =
        Jason.encode!(%{
          "legacy-only-model" => %{
            "type" => "custom_openai",
            "provider" => "legacy-test",
            "name" => "legacy-only",
            "context_length" => 64_000
          }
        })

      File.write!(Path.join(legacy_home, "extra_models.json"), overlay_content)

      original_path = Application.get_env(:code_puppy_control, :bundled_models_path)
      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      try do
        # Point bundled models to nonexistent path
        Application.put_env(
          :code_puppy_control,
          :bundled_models_path,
          "/tmp/nonexistent_models.json"
        )

        # Use empty Elixir home (no Elixir-home overlays)
        System.put_env("PUP_EX_HOME", tmp_dir)
        Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)

        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("legacy-only-model")
        assert is_map(config)
        assert config["type"] == "custom_openai"
        assert config["provider"] == "legacy-test"
      after
        if original_path,
          do: Application.put_env(:code_puppy_control, :bundled_models_path, original_path),
          else: Application.delete_env(:code_puppy_control, :bundled_models_path)

        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(legacy_home)
        ModelRegistry.reload()
      end
    end

    test "Elixir-home overlays win over legacy overlays on key conflict" do
      legacy_home =
        Path.join(System.tmp_dir!(), "mr_legacy_conflict_#{:erlang.unique_integer([:positive])}")

      elixir_home =
        Path.join(System.tmp_dir!(), "mr_elixir_conflict_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(legacy_home)
      File.mkdir_p!(elixir_home)

      legacy_overlay =
        Jason.encode!(%{
          "conflict-model" => %{
            "type" => "openai",
            "provider" => "legacy",
            "name" => "legacy-version",
            "context_length" => 1000
          }
        })

      elixir_overlay =
        Jason.encode!(%{
          "conflict-model" => %{
            "type" => "anthropic",
            "provider" => "elixir",
            "name" => "elixir-version",
            "context_length" => 2000
          }
        })

      File.write!(Path.join(legacy_home, "extra_models.json"), legacy_overlay)
      File.write!(Path.join(elixir_home, "extra_models.json"), elixir_overlay)

      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      try do
        Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)
        System.put_env("PUP_EX_HOME", elixir_home)

        assert :ok = ModelRegistry.reload()

        config = ModelRegistry.get_config("conflict-model")
        # Elixir-home overlay wins (loaded after legacy)
        assert config["type"] == "anthropic"
        assert config["provider"] == "elixir"
        assert config["context_length"] == 2000
      after
        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(legacy_home)
        File.rm_rf!(elixir_home)
        ModelRegistry.reload()
      end
    end

    test "legacy chatgpt and claude overlays load from legacy home" do
      legacy_home =
        Path.join(System.tmp_dir!(), "mr_legacy_types_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(legacy_home)

      chatgpt_overlay =
        Jason.encode!(%{
          "legacy-chatgpt-model" => %{
            "type" => "chatgpt_oauth",
            "name" => "legacy-chatgpt",
            "context_length" => 128_000
          }
        })

      claude_overlay =
        Jason.encode!(%{
          "legacy-claude-model" => %{
            "type" => "claude_code",
            "name" => "legacy-claude",
            "context_length" => 200_000
          }
        })

      File.write!(Path.join(legacy_home, "chatgpt_models.json"), chatgpt_overlay)
      File.write!(Path.join(legacy_home, "claude_models.json"), claude_overlay)

      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      try do
        Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)
        # Use empty Elixir home so only legacy overlays load
        System.put_env("PUP_EX_HOME", legacy_home)

        assert :ok = ModelRegistry.reload()

        assert ModelRegistry.get_config("legacy-chatgpt-model")["type"] == "chatgpt_oauth"
        assert ModelRegistry.get_config("legacy-claude-model")["type"] == "claude_code"
      after
        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(legacy_home)
        ModelRegistry.reload()
      end
    end

    test "base models + legacy overlays + Elixir overlays merge correctly" do
      legacy_home =
        Path.join(System.tmp_dir!(), "mr_legacy_merge_#{:erlang.unique_integer([:positive])}")

      elixir_home =
        Path.join(System.tmp_dir!(), "mr_elixir_merge_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(legacy_home)
      File.mkdir_p!(elixir_home)

      # Legacy overlay adds a unique model
      File.write!(
        Path.join(legacy_home, "extra_models.json"),
        Jason.encode!(%{
          "from-legacy" => %{"type" => "openai", "provider" => "legacy"}
        })
      )

      # Elixir overlay adds another unique model
      File.write!(
        Path.join(elixir_home, "extra_models.json"),
        Jason.encode!(%{
          "from-elixir" => %{"type" => "anthropic", "provider" => "elixir"}
        })
      )

      _original_legacy = Application.get_env(:code_puppy_control, :legacy_home_dir)
      old_home = System.get_env("PUP_EX_HOME")

      try do
        Application.put_env(:code_puppy_control, :legacy_home_dir, legacy_home)
        System.put_env("PUP_EX_HOME", elixir_home)

        assert :ok = ModelRegistry.reload()

        # Both overlays present alongside bundled models
        assert ModelRegistry.get_config("from-legacy") != nil
        assert ModelRegistry.get_config("from-elixir") != nil
        # Bundled models still present
        assert ModelRegistry.get_config("wafer-glm-5.1") != nil
      after
        Application.delete_env(:code_puppy_control, :legacy_home_dir)

        if old_home,
          do: System.put_env("PUP_EX_HOME", old_home),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(legacy_home)
        File.rm_rf!(elixir_home)
        ModelRegistry.reload()
      end
    end
  end
end
