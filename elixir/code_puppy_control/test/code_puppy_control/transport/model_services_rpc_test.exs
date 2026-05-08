defmodule CodePuppyControl.Transport.ModelServicesRpcTest do
  @moduledoc """
  Tests for model services RPC handlers.

  These tests verify the JSON-RPC handlers for model_registry, model_availability,
  model_packs, and model_utils services work correctly via the stdio transport.
  """

  use ExUnit.Case

  alias CodePuppyControl.Transport.StdioService
  alias CodePuppyControl.Support.StdioTestHelper

  @test_models_path Path.expand("../../fixtures/test_models.json", __DIR__)

  # ============================================================================
  # Model Registry RPC Tests
  # ============================================================================

  describe "model_registry.get_config" do
    test "returns config for existing model" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_registry.get_config",
        "params" => %{"model_name" => "test-model"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["model_name"] == "test-model"
      # Config may be nil if model doesn't exist, or a map if it does
      assert Map.has_key?(response["result"], "config")
    end

    test "returns error for missing model_name param" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_registry.get_config",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "model_name"
    end

    test "returns error for non-map params instead of crashing" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_registry.get_config",
        "params" => []
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "Invalid params: expected object"
    end

    test "returns enabled:false for disabled models (regression test)" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_registry.get_config",
        "params" => %{"model_name" => "disabled-test-model"}
      }

      output =
        capture_stdio(
          [Jason.encode!(request)],
          fn -> StdioService.run() end,
          env: [{"PUP_BUNDLED_MODELS_PATH", @test_models_path}]
        )

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["model_name"] == "disabled-test-model"
      assert response["result"]["config"]["enabled"] == false
    end
  end

  describe "model_registry.list_models" do
    test "returns list of all models" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_registry.list_models",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert is_list(response["result"]["models"])
      assert is_integer(response["result"]["count"])
    end
  end

  describe "model_registry.get_all_configs" do
    test "returns all model configs as map" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_registry.get_all_configs",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert is_map(response["result"]["configs"])
      assert is_integer(response["result"]["count"])
    end
  end

  # ============================================================================
  # Model Availability RPC Tests
  # ============================================================================

  describe "model_availability.check" do
    test "returns availability status for model" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_availability.check",
        "params" => %{"model_name" => "test-model"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["model_name"] == "test-model"
      assert is_boolean(response["result"]["available"])
      # reason may be nil or a string
      assert Map.has_key?(response["result"], "reason")
    end

    test "returns error for missing model_name param" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_availability.check",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "model_name"
    end
  end

  describe "model_availability.snapshot" do
    test "returns full availability snapshot" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_availability.snapshot",
        "params" => %{"model_name" => "test-model"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["model_name"] == "test-model"
      assert is_boolean(response["result"]["available"])
      assert is_boolean(response["result"]["is_last_resort"])
      assert Map.has_key?(response["result"], "reason")
    end
  end

  # ============================================================================
  # Model Packs RPC Tests
  # ============================================================================

  describe "model_packs.get_pack" do
    test "returns pack by name" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_packs.get_pack",
        "params" => %{"pack_name" => "single"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["pack"]["name"] == "single"
      assert is_map(response["result"]["pack"]["roles"])
      assert is_boolean(response["result"]["pack"]["is_builtin"])
    end

    test "returns current pack when name is nil" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_packs.get_pack",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert is_map(response["result"]["pack"])
      assert response["result"]["pack"]["name"]
    end
  end

  describe "model_packs.get_current" do
    test "returns current model pack" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_packs.get_current",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert is_map(response["result"]["pack"])
      assert response["result"]["pack"]["name"]
      assert is_map(response["result"]["pack"]["roles"])
    end
  end

  describe "model_packs.list_packs" do
    test "returns all available packs" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_packs.list_packs",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert is_list(response["result"]["packs"])
      assert is_integer(response["result"]["count"])

      # Should include built-in packs like "single", "coding", "economical", "capacity"
      pack_names = Enum.map(response["result"]["packs"], & &1["name"])
      assert "single" in pack_names
    end
  end

  describe "model_packs.get_model_for_role" do
    test "returns primary model for role" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_packs.get_model_for_role",
        "params" => %{"role" => "coder"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["role"] == "coder"
      assert is_binary(response["result"]["model"])
    end

    test "defaults to coder role when not specified" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_packs.get_model_for_role",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["role"] == "coder"
      assert is_binary(response["result"]["model"])
    end
  end

  # ============================================================================
  # Model Utils RPC Tests
  # ============================================================================

  describe "model_utils.resolve_model" do
    test "returns config for existing model" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_utils.resolve_model",
        "params" => %{"model_name" => "test-model"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["model_name"] == "test-model"
      # Config may be nil if not found, or a map with type info
      assert Map.has_key?(response["result"], "config")
      assert Map.has_key?(response["result"], "type")
    end

    test "returns error for missing model_name param" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "model_utils.resolve_model",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "model_name"
    end
  end

  # ============================================================================
  # JSON-RPC ID Threading Regression Tests
  # ============================================================================

  describe "JSON-RPC id threading (regression)" do
    test "workflow.get_status error response echoes request id" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "method" => "workflow.get_status",
        "params" => %{"workflow_id" => "nonexistent"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)

      assert response["id"] == 42,
             "JSON-RPC id must be echoed in error response, got: #{inspect(response["id"])}"

      assert response["error"]["code"] == -32_001
      assert response["error"]["message"] =~ "Workflow not found"
      # The id must NOT appear in error data (was the pre-bug)
      refute Map.has_key?(response["error"], "data"),
             "error.data should not contain the request id (was the bug)"
    end

    test "workflow.cancel error response echoes request id" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 99,
        "method" => "workflow.cancel",
        "params" => %{"workflow_id" => "nonexistent"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)

      assert response["id"] == 99,
             "JSON-RPC id must be echoed in error response, got: #{inspect(response["id"])}"

      assert response["error"]["code"] == -32_001
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp capture_stdio(inputs, fun \\ nil, opts \\ []) do
    StdioTestHelper.capture_stdio(inputs, fun, opts)
  end
end
