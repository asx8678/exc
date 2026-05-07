defmodule CodePuppyControl.ModelsDevParserTest do
  @moduledoc """
  Tests for the ModelsDevParser module.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.ModelsDevParser
  alias CodePuppyControl.ModelsDevParser.{ProviderInfo, ModelInfo, Registry}

  # ============================================================================
  # Test Data
  # ============================================================================

  defp test_provider_data do
    %{
      "id" => "test-provider",
      "name" => "Test Provider",
      "env" => ["TEST_API_KEY"],
      "api" => "https://api.test.com/v1",
      "npm" => "@test/sdk",
      "doc" => "https://docs.test.com",
      "models" => %{
        "test-model-1" => %{
          "id" => "test-model-1",
          "name" => "Test Model One",
          "attachment" => true,
          "reasoning" => false,
          "tool_call" => true,
          "temperature" => true,
          "knowledge" => "2024-01",
          "release_date" => "2024-01-15",
          "last_updated" => "2024-03-01",
          "modalities" => %{
            "input" => ["text", "image"],
            "output" => ["text"]
          },
          "open_weights" => false,
          "cost" => %{
            "input" => 0.001,
            "output" => 0.002,
            "cache_read" => 0.0005
          },
          "limit" => %{
            "context" => 128_000,
            "output" => 4096
          }
        },
        "test-model-2" => %{
          "id" => "test-model-2",
          "name" => "Test Model Two",
          "attachment" => false,
          "reasoning" => true,
          "tool_call" => false,
          "temperature" => false,
          "structured_output" => true,
          "modalities" => %{
            "input" => ["text"],
            "output" => ["text"]
          },
          "open_weights" => true,
          "cost" => %{
            "input" => 0.01,
            "output" => 0.03
          },
          "limit" => %{
            "context" => 32_000,
            "output" => 2048
          }
        },
        "cheap-model" => %{
          "id" => "cheap-model",
          "name" => "Cheap Model",
          "modalities" => %{
            "input" => ["text"],
            "output" => ["text"]
          },
          "cost" => %{
            "input" => 0.0001,
            "output" => 0.0002
          },
          "limit" => %{
            "context" => 16_000,
            "output" => 1024
          }
        }
      }
    }
  end

  defp another_provider_data do
    %{
      "id" => "another-provider",
      "name" => "Another Provider",
      "env" => ["ANOTHER_API_KEY"],
      "api" => "https://api.another.com/v2",
      "models" => %{
        "gpt-model" => %{
          "id" => "gpt-model",
          "name" => "GPT Model",
          "attachment" => false,
          "reasoning" => false,
          "tool_call" => true,
          "temperature" => true,
          "knowledge" => "2024-06",
          "modalities" => %{
            "input" => ["text"],
            "output" => ["text"]
          },
          "cost" => %{
            "input" => 0.005,
            "output" => 0.015
          },
          "limit" => %{
            "context" => 256_000,
            "output" => 8192
          }
        }
      }
    }
  end

  # ============================================================================
  # Setup
  # ============================================================================

  defp write_test_data(temp_path) do
    test_data = %{
      "test-provider" => test_provider_data(),
      "another-provider" => another_provider_data()
    }

    File.mkdir_p!(Path.dirname(temp_path))
    File.write!(temp_path, Jason.encode!(test_data))
  end

  # FIX (code_puppy-mmk.2): Use temp files instead of writing to the shared
  # fixture, preventing test pollution of models_dev_parser_test_data.json.
  setup do
    # Create a per-test temp file so we never modify the repo fixture
    temp_path =
      Path.join(
        System.tmp_dir!(),
        "models_dev_parser_test_#{:erlang.unique_integer([:positive])}.json"
      )

    write_test_data(temp_path)

    # Generate unique name for this test instance
    name = :"test_registry_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} = Registry.start_link(json_path: temp_path, name: name)

    on_exit(fn ->
      # Deterministic shutdown: monitor before stop to avoid TOCTOU race
      # between Process.alive? check and GenServer.stop.
      stop_registry(pid)

      # Clean up temp file
      File.rm(temp_path)
    end)

    {:ok, %{registry: pid, temp_path: temp_path}}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Stops a GenServer deterministically.
  # Uses Process.alive? check to avoid crashing on already-dead processes
  # (e.g. when test body already cleaned up a different registry and the
  # setup-created registry exits early under async load), then monitor +
  # DOWN-receive to confirm termination before the on_exit proceeds.
  defp stop_registry(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      GenServer.stop(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1000 -> :ok
      end
    end
  end

  # ============================================================================
  # ProviderInfo Tests
  # ============================================================================

  describe "ProviderInfo" do
    test "struct creation with required fields" do
      provider = %ProviderInfo{
        id: "test",
        name: "Test Provider",
        env: ["API_KEY"]
      }

      assert provider.id == "test"
      assert provider.name == "Test Provider"
      assert provider.env == ["API_KEY"]
    end

    test "model_count/1 returns correct count" do
      provider = %ProviderInfo{
        id: "test",
        name: "Test",
        env: ["KEY"],
        models: %{"m1" => %{}, "m2" => %{}, "m3" => %{}}
      }

      assert ProviderInfo.model_count(provider) == 3
    end

    test "model_count/1 handles empty models" do
      provider = %ProviderInfo{
        id: "test",
        name: "Test",
        env: ["KEY"]
      }

      assert ProviderInfo.model_count(provider) == 0
    end
  end

  # ============================================================================
  # ModelInfo Tests
  # ============================================================================

  describe "ModelInfo" do
    test "struct creation with required fields" do
      model = %ModelInfo{
        provider_id: "provider",
        model_id: "model-1",
        name: "Model One"
      }

      assert model.provider_id == "provider"
      assert model.model_id == "model-1"
      assert model.name == "Model One"
      assert model.attachment == false
      # default
      assert model.temperature == true
    end

    test "full_id/1 returns correct full identifier" do
      model = %ModelInfo{
        provider_id: "anthropic",
        model_id: "claude-3-opus",
        name: "Claude 3 Opus"
      }

      assert ModelInfo.full_id(model) == "anthropic::claude-3-opus"
    end

    test "has_vision?/1 detects image capability" do
      vision_model = %ModelInfo{
        provider_id: "test",
        model_id: "vision",
        name: "Vision Model",
        input_modalities: ["text", "image"]
      }

      non_vision_model = %ModelInfo{
        provider_id: "test",
        model_id: "text",
        name: "Text Model",
        input_modalities: ["text"]
      }

      assert ModelInfo.has_vision?(vision_model) == true
      assert ModelInfo.has_vision?(non_vision_model) == false
    end

    test "multimodal?/1 detects multiple modalities" do
      multimodal = %ModelInfo{
        provider_id: "test",
        model_id: "multi",
        name: "Multimodal",
        input_modalities: ["text", "image"],
        output_modalities: ["text"]
      }

      single_modal = %ModelInfo{
        provider_id: "test",
        model_id: "single",
        name: "Single",
        input_modalities: ["text"],
        output_modalities: ["text"]
      }

      assert ModelInfo.multimodal?(multimodal) == true
      assert ModelInfo.multimodal?(single_modal) == false
    end

    test "supports_capability?/1 checks capabilities" do
      model = %ModelInfo{
        provider_id: "test",
        model_id: "test",
        name: "Test",
        reasoning: true,
        tool_call: false,
        temperature: true
      }

      assert ModelInfo.supports_capability?(model, :reasoning) == true
      assert ModelInfo.supports_capability?(model, :tool_call) == false
      assert ModelInfo.supports_capability?(model, "temperature") == true
      assert ModelInfo.supports_capability?(model, :nonexistent) == false
    end
  end

  # ============================================================================
  # Registry Tests - Provider Operations
  # ============================================================================

  describe "Registry provider operations" do
    test "get_providers/1 returns sorted list", %{registry: registry} do
      providers = Registry.get_providers(registry)

      assert length(providers) == 2
      # Sorted by name (Another Provider, Test Provider)
      assert hd(providers).name == "Another Provider"
      assert hd(providers).id == "another-provider"
    end

    test "get_provider/2 returns specific provider", %{registry: registry} do
      provider = Registry.get_provider(registry, "test-provider")

      assert provider.name == "Test Provider"
      assert provider.env == ["TEST_API_KEY"]
      assert provider.api == "https://api.test.com/v1"
      assert provider.npm == "@test/sdk"
      assert provider.doc == "https://docs.test.com"
    end

    test "get_provider/2 returns nil for unknown", %{registry: registry} do
      assert Registry.get_provider(registry, "unknown") == nil
    end
  end

  # ============================================================================
  # Registry Tests - Model Operations
  # ============================================================================

  describe "Registry model operations" do
    test "get_models/2 returns all models when no provider specified", %{registry: registry} do
      models = Registry.get_models(registry)

      # 3 from test-provider + 1 from another-provider = 4
      assert length(models) == 4

      # Sorted by name
      names = Enum.map(models, & &1.name)
      assert names == ["Cheap Model", "GPT Model", "Test Model One", "Test Model Two"]
    end

    test "get_models/2 filters by provider", %{registry: registry} do
      models = Registry.get_models(registry, "test-provider")

      assert length(models) == 3
      assert Enum.all?(models, &(&1.provider_id == "test-provider"))
    end

    test "get_model/3 returns specific model", %{registry: registry} do
      model = Registry.get_model(registry, "test-provider", "test-model-1")

      assert model.name == "Test Model One"
      assert model.attachment == true
      assert model.tool_call == true
      assert model.context_length == 128_000
      assert model.cost_input == 0.001
    end

    test "get_model/3 returns nil for unknown", %{registry: registry} do
      assert Registry.get_model(registry, "test-provider", "unknown") == nil
    end
  end

  # ============================================================================
  # Registry Tests - Search and Filter
  # ============================================================================

  describe "Registry search operations" do
    test "search_models/2 with query filters by name", %{registry: registry} do
      results = Registry.search_models(registry, query: "GPT")

      assert length(results) == 1
      assert hd(results).name == "GPT Model"
    end

    test "search_models/2 with query filters by model_id", %{registry: registry} do
      results = Registry.search_models(registry, query: "cheap")

      assert length(results) == 1
      assert hd(results).model_id == "cheap-model"
    end

    test "search_models/2 is case insensitive", %{registry: registry} do
      results_lower = Registry.search_models(registry, query: "gpt")
      results_upper = Registry.search_models(registry, query: "GPT")

      assert length(results_lower) == 1
      assert length(results_upper) == 1
      assert hd(results_lower).name == hd(results_upper).name
    end

    test "search_models/2 with capability filters", %{registry: registry} do
      # Filter for models with reasoning
      results = Registry.search_models(registry, capability_filters: %{"reasoning" => true})

      assert length(results) == 1
      assert hd(results).reasoning == true
      assert hd(results).name == "Test Model Two"
    end

    test "search_models/2 with multiple filters", %{registry: registry} do
      results =
        Registry.search_models(registry,
          query: "model",
          capability_filters: %{"tool_call" => true}
        )

      # Should get test-model-1 and gpt-model (both have tool_call=true)
      assert length(results) == 2
    end
  end

  describe "Registry filter operations" do
    test "filter_by_cost/4 with max_input_cost", %{registry: registry} do
      all_models = Registry.get_models(registry)

      filtered = Registry.filter_by_cost(registry, all_models, 0.001, nil)

      # Only cheap-model and test-model-1 have input cost <= 0.001
      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.cost_input <= 0.001))
    end

    test "filter_by_cost/4 with max_output_cost", %{registry: registry} do
      all_models = Registry.get_models(registry)

      filtered = Registry.filter_by_cost(registry, all_models, nil, 0.0002)

      # cheap-model has output cost of 0.0002, test-model-1 has 0.002
      assert length(filtered) == 1
      assert hd(filtered).name == "Cheap Model"
    end

    test "filter_by_cost/4 with both constraints", %{registry: registry} do
      all_models = Registry.get_models(registry)

      filtered = Registry.filter_by_cost(registry, all_models, 0.005, 0.02)

      # Multiple models should match
      assert length(filtered) >= 1
      assert Enum.all?(filtered, &(&1.cost_input <= 0.005 and &1.cost_output <= 0.02))
    end

    test "filter_by_context/3 filters by minimum context", %{registry: registry} do
      all_models = Registry.get_models(registry)

      filtered = Registry.filter_by_context(registry, all_models, 100_000)

      # Only test-model-1 and gpt-model have context >= 100k
      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.context_length >= 100_000))
    end
  end

  # ============================================================================
  # Registry Tests - Config Conversion
  # ============================================================================

  describe "Registry config conversion" do
    test "to_config/2 creates Code Puppy config", %{registry: registry} do
      model = Registry.get_model(registry, "test-provider", "test-model-1")
      config = Registry.to_config(registry, model)

      assert config["type"] == "test-provider"
      assert config["model"] == "test-model-1"
      assert config["enabled"] == true
      assert config["provider_id"] == "test-provider"
      assert config["env_vars"] == ["TEST_API_KEY"]
      assert config["api_url"] == "https://api.test.com/v1"
      assert config["npm_package"] == "@test/sdk"

      # Cost information
      assert config["input_cost_per_token"] == 0.001
      assert config["output_cost_per_token"] == 0.002
      assert config["cache_read_cost_per_token"] == 0.0005

      # Limits
      assert config["max_tokens"] == 128_000
      assert config["max_output_tokens"] == 4096

      # Capabilities
      assert config["capabilities"]["attachment"] == true
      assert config["capabilities"]["reasoning"] == false
      assert config["capabilities"]["tool_call"] == true
      assert config["capabilities"]["temperature"] == true

      # Modalities
      assert config["input_modalities"] == ["text", "image"]
      assert config["output_modalities"] == ["text"]

      # Metadata
      assert config["metadata"]["knowledge"] == "2024-01"
      assert config["metadata"]["release_date"] == "2024-01-15"
      assert config["metadata"]["open_weights"] == false
    end

    test "to_config/2 with known provider uses type mapping", %{
      registry: _setup_registry,
      temp_path: temp_path
    } do
      # Create a provider with a known ID from the mapping
      provider_data = %{
        "anthropic" => %{
          "id" => "anthropic",
          "name" => "Anthropic",
          "env" => ["ANTHROPIC_API_KEY"],
          "api" => "https://api.anthropic.com/v1",
          "models" => %{
            "claude-3-opus" => %{
              "id" => "claude-3-opus",
              "name" => "Claude 3 Opus",
              "modalities" => %{"input" => ["text"], "output" => ["text"]},
              "cost" => %{},
              "limit" => %{"context" => 100_000, "output" => 4096}
            }
          }
        }
      }

      File.write!(temp_path, Jason.encode!(provider_data))

      # Start registry with new data using a unique name
      name = :"mapping_test_registry_#{:erlang.unique_integer([:positive])}"
      {:ok, new_registry} = Registry.start_link(json_path: temp_path, name: name)

      model = Registry.get_model(new_registry, "anthropic", "claude-3-opus")
      assert model != nil

      config = Registry.to_config(new_registry, model)
      # Provider type should be "anthropic" (from mapping)
      assert config["type"] == "anthropic"
      assert config["provider_id"] == "anthropic"

      # Cleanup
      stop_registry(new_registry)
    end
  end

  # ============================================================================
  # Registry Tests - Data Source
  # ============================================================================

  describe "Registry data source tracking" do
    test "data_source/1 returns file source when loaded from file", %{registry: registry} do
      source = Registry.data_source(registry)
      assert source =~ "file:"
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles missing provider fields gracefully", %{
      registry: _setup_registry,
      temp_path: temp_path
    } do
      bad_data = %{
        "bad-provider" => %{
          # Missing "name" and "env"
          "api" => "https://api.bad.com"
        }
      }

      File.write!(temp_path, Jason.encode!(bad_data))
      name = :"bad_provider_test_#{:erlang.unique_integer([:positive])}"
      {:ok, registry} = Registry.start_link(json_path: temp_path, name: name)

      # Should have 0 providers since the only one was malformed
      assert Registry.get_providers(registry) == []

      stop_registry(registry)
    end

    test "handles missing model name gracefully", %{
      registry: _setup_registry,
      temp_path: temp_path
    } do
      bad_data = %{
        "test-provider" => %{
          "id" => "test-provider",
          "name" => "Test Provider",
          "env" => ["KEY"],
          "models" => %{
            "good-model" => %{
              "id" => "good-model",
              "name" => "Good Model"
            },
            "bad-model" => %{
              "id" => "bad-model"
              # Missing "name"
            }
          }
        }
      }

      File.write!(temp_path, Jason.encode!(bad_data))
      name = :"bad_model_test_#{:erlang.unique_integer([:positive])}"
      {:ok, registry} = Registry.start_link(json_path: temp_path, name: name)

      # Should have 1 model (the good one)
      models = Registry.get_models(registry)
      assert length(models) == 1
      assert hd(models).name == "Good Model"

      stop_registry(registry)
    end

    test "handles negative context length gracefully", %{
      registry: _setup_registry,
      temp_path: temp_path
    } do
      bad_data = %{
        "test-provider" => %{
          "id" => "test-provider",
          "name" => "Test Provider",
          "env" => ["KEY"],
          "models" => %{
            "bad-model" => %{
              "id" => "bad-model",
              "name" => "Bad Model",
              "limit" => %{
                "context" => -100
              }
            }
          }
        }
      }

      File.write!(temp_path, Jason.encode!(bad_data))
      name = :"neg_context_test_#{:erlang.unique_integer([:positive])}"
      {:ok, registry} = Registry.start_link(json_path: temp_path, name: name)

      # Model should be skipped due to negative context
      assert Registry.get_models(registry) == []

      stop_registry(registry)
    end
  end

  # ============================================================================
  # Module API Tests (convenience functions)
  # ============================================================================

  describe "Module convenience API" do
    test "delegates to Registry", %{registry: registry} do
      # Test that the module-level functions delegate correctly
      providers = ModelsDevParser.get_providers(registry)
      assert length(providers) == 2

      models = ModelsDevParser.get_models(registry, "test-provider")
      assert length(models) == 3

      model = ModelsDevParser.get_model(registry, "test-provider", "test-model-1")
      assert model.name == "Test Model One"
    end
  end

  # ============================================================================
  # Async API Regression Tests
  # ============================================================================

  describe "ApiClient async API path" do
    alias CodePuppyControl.ModelsDevParser.ApiClient

    # Mock HTTP client module that returns successful responses
    defmodule MockHttpClientSuccess do
      def get("https://models.dev/api.json", _opts) do
        data = %{
          "test-provider" => %{
            "id" => "test-provider",
            "name" => "Test Provider",
            "env" => ["TEST_API_KEY"],
            "api" => "https://api.test.com/v1",
            "models" => %{
              "test-model-1" => %{
                "id" => "test-model-1",
                "name" => "Test Model One",
                "modalities" => %{"input" => ["text"], "output" => ["text"]},
                "cost" => %{"input" => 0.001, "output" => 0.002},
                "limit" => %{"context" => 128_000, "output" => 4096}
              }
            }
          }
        }

        {:ok, %{status: 200, body: Jason.encode!(data)}}
      end
    end

    # Mock HTTP client that returns HTTP error
    defmodule MockHttpClientError do
      def get("https://models.dev/api.json", _opts) do
        {:ok, %{status: 500, body: "Internal Server Error"}}
      end
    end

    # Mock HTTP client that returns network failure
    defmodule MockHttpClientNetworkError do
      def get("https://models.dev/api.json", _opts) do
        {:error, :econnrefused}
      end
    end

    # Mock HTTP client that returns empty JSON
    defmodule MockHttpClientEmpty do
      def get("https://models.dev/api.json", _opts) do
        {:ok, %{status: 200, body: Jason.encode!(%{})}}
      end
    end

    # Mock HTTP client for fresh data
    defmodule MockHttpClientFresh do
      def get("https://models.dev/api.json", _opts) do
        data = %{"fresh" => "data"}
        {:ok, %{status: 200, body: Jason.encode!(data)}}
      end
    end

    # Mock HTTP client that always fails (for fallback testing)
    defmodule MockHttpClientAlwaysFail do
      def get("https://models.dev/api.json", _opts) do
        {:error, :nxdomain}
      end
    end

    test "do_fetch_from_api returns {:ok, data} on successful API fetch" do
      state = %{
        cached_data: nil,
        cache_time: nil,
        http_client: MockHttpClientSuccess
      }

      # Should return {:ok, decoded_data} tuple
      assert {:ok, data} = ApiClient.do_fetch_from_api(state)
      assert is_map(data)
      assert Map.has_key?(data, "test-provider")
    end

    test "do_fetch_from_api returns {:error, reason} on HTTP error" do
      state = %{
        cached_data: nil,
        cache_time: nil,
        http_client: MockHttpClientError
      }

      # Should return {:error, {:http_error, 500}} tuple
      assert {:error, {:http_error, 500}} = ApiClient.do_fetch_from_api(state)
    end

    test "do_fetch_from_api returns {:error, reason} on network failure" do
      state = %{
        cached_data: nil,
        cache_time: nil,
        http_client: MockHttpClientNetworkError
      }

      # Should return {:error, :econnrefused}
      assert {:error, :econnrefused} = ApiClient.do_fetch_from_api(state)
    end

    test "do_fetch_from_api returns {:error, :invalid_response} on empty JSON" do
      state = %{
        cached_data: nil,
        cache_time: nil,
        http_client: MockHttpClientEmpty
      }

      # Should return {:error, :invalid_response} for empty map
      assert {:error, :invalid_response} = ApiClient.do_fetch_from_api(state)
    end

    test "fetch_from_api uses cache when cache is fresh" do
      cached_data = %{"cached" => "data"}
      now = System.monotonic_time(:second)

      state = %{
        json_path: nil,
        cached_data: cached_data,
        cache_time: now,
        data_source: "test",
        http_client: nil
      }

      # Should return cached data without making HTTP request
      assert {:ok, ^cached_data} = ApiClient.fetch_from_api(state)
    end

    test "fetch_from_api fetches from API when cache is expired" do
      # Create a very old cache time
      old_time = System.monotonic_time(:second) - 400

      state = %{
        json_path: nil,
        cached_data: %{"old" => "data"},
        cache_time: old_time,
        data_source: "test",
        http_client: MockHttpClientFresh
      }

      # Should fetch fresh data since cache is expired
      assert {:ok, data} = ApiClient.fetch_from_api(state)
      assert data == %{"fresh" => "data"}
    end

    test "load_data_async falls back to bundled file when API fails" do
      priv_dir = :code.priv_dir(:code_puppy_control)
      bundled_path = Path.join(priv_dir, "models_dev_api.json")

      # Save original content if file exists
      original_content = if File.exists?(bundled_path), do: File.read!(bundled_path), else: nil

      fallback_data = %{
        "fallback-provider" => %{
          "id" => "fallback-provider",
          "name" => "Fallback Provider",
          "env" => ["KEY"],
          "models" => %{}
        }
      }

      # Ensure priv dir exists and write fallback data
      File.mkdir_p!(priv_dir)
      File.write!(bundled_path, Jason.encode!(fallback_data))

      # Restore original content on exit (or delete if there was none)
      on_exit(fn ->
        if original_content do
          File.write!(bundled_path, original_content)
        else
          File.rm!(bundled_path)
        end
      end)

      state = %{
        json_path: nil,
        cached_data: nil,
        cache_time: nil,
        data_source: "unknown",
        providers: %{},
        models: %{},
        http_client: MockHttpClientAlwaysFail
      }

      # Should fall back to bundled file
      assert {:ok, new_state} = ApiClient.load_data_async(state)
      assert new_state.data_source =~ "bundled:"
      assert Map.has_key?(new_state.providers, "fallback-provider")
    end

    test "load_data_async returns error when both API and bundled file fail" do
      priv_dir = :code.priv_dir(:code_puppy_control)
      bundled_path = Path.join(priv_dir, "models_dev_api.json")

      # Save original content if file exists
      original_content = if File.exists?(bundled_path), do: File.read!(bundled_path), else: nil

      # Delete the bundled file to simulate it being missing
      if File.exists?(bundled_path) do
        File.rm!(bundled_path)
      end

      # Restore original content on exit (or ensure deleted if there was none)
      on_exit(fn ->
        if original_content do
          File.mkdir_p!(priv_dir)
          File.write!(bundled_path, original_content)
        else
          if File.exists?(bundled_path), do: File.rm!(bundled_path)
        end
      end)

      state = %{
        json_path: nil,
        cached_data: nil,
        cache_time: nil,
        data_source: "unknown",
        providers: %{},
        models: %{},
        http_client: MockHttpClientAlwaysFail
      }

      # Should return error since both API and fallback failed
      assert {:error, error_message} = ApiClient.load_data_async(state)
      assert error_message =~ "No data source available"
    end

    test "load_data_async uses custom json_path when provided" do
      # Write test data to a temp file
      temp_path = Path.join(System.tmp_dir!(), "test_api_client_#{System.monotonic_time()}.json")

      custom_data = %{
        "custom-provider" => %{
          "id" => "custom-provider",
          "name" => "Custom Provider",
          "env" => ["CUSTOM_KEY"],
          "models" => %{}
        }
      }

      File.write!(temp_path, Jason.encode!(custom_data))

      on_exit(fn ->
        if File.exists?(temp_path) do
          File.rm(temp_path)
        end
      end)

      state = %{
        json_path: temp_path,
        cached_data: nil,
        cache_time: nil,
        data_source: "unknown",
        providers: %{},
        models: %{},
        http_client: nil
      }

      # Should load from custom path, not API
      assert {:ok, new_state} = ApiClient.load_data_async(state)
      assert new_state.data_source == "file:#{temp_path}"
      assert Map.has_key?(new_state.providers, "custom-provider")
    end
  end

  # ============================================================================
  # ConfigBuilder Tests
  # ============================================================================

  describe "ConfigBuilder" do
    alias CodePuppyControl.ModelsDevParser.ConfigBuilder

    test "maybe_put adds value when condition is met" do
      result = ConfigBuilder.maybe_put(%{}, "key", "value")
      assert result == %{"key" => "value"}
    end

    test "maybe_put skips nil values" do
      result = ConfigBuilder.maybe_put(%{}, "key", nil)
      assert result == %{}
    end

    test "maybe_put skips empty strings" do
      result = ConfigBuilder.maybe_put(%{}, "key", "")
      assert result == %{}
    end

    test "maybe_put skips empty lists" do
      result = ConfigBuilder.maybe_put(%{}, "key", [])
      assert result == %{}
    end

    test "maybe_put with custom condition" do
      result = ConfigBuilder.maybe_put(%{}, "key", 5, &(&1 > 10))
      assert result == %{}

      result = ConfigBuilder.maybe_put(%{}, "key", 15, &(&1 > 10))
      assert result == %{"key" => 15}
    end

    test "build with nil provider returns minimal config" do
      model = %ModelInfo{
        provider_id: "test",
        model_id: "model-1",
        name: "Test Model",
        attachment: true,
        tool_call: false,
        temperature: false
      }

      config = ConfigBuilder.build(model, nil)

      assert config["type"] == "test"
      assert config["model"] == "model-1"
      assert config["capabilities"]["attachment"] == true
      assert config["capabilities"]["tool_call"] == false
      assert config["capabilities"]["temperature"] == false
    end

    test "build omits zero/empty values" do
      provider = %ProviderInfo{
        id: "test",
        name: "Test",
        env: ["KEY"]
      }

      model = %ModelInfo{
        provider_id: "test",
        model_id: "model-1",
        name: "Test Model",
        context_length: 0,
        max_output: 0,
        input_modalities: [],
        output_modalities: [],
        cost_input: nil,
        cost_output: nil
      }

      config = ConfigBuilder.build(model, provider)

      # Should not have zero/empty values
      refute Map.has_key?(config, "max_tokens")
      refute Map.has_key?(config, "max_output_tokens")
      refute Map.has_key?(config, "input_modalities")
      refute Map.has_key?(config, "output_modalities")
      refute Map.has_key?(config, "input_cost_per_token")
      refute Map.has_key?(config, "output_cost_per_token")
    end
  end
end
