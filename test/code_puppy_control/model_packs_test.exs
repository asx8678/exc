defmodule CodePuppyControl.ModelPacksTest do
  @moduledoc """
  Tests for the ModelPacks GenServer.

  Covers:
  - Starting with default packs loaded
  - Getting packs by name (including nil for current)
  - Listing all packs
  - Setting/getting current pack
  - Role resolution (get_model_for_role, get_fallback_chain)
  - Creating and deleting user packs
  - Pack persistence (save/load cycle)
  - RoleConfig and ModelPack struct operations
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.ModelPacks
  alias CodePuppyControl.ModelPacks.RoleConfig
  alias CodePuppyControl.ModelPacks.ModelPack

  setup do
    # Ensure ModelPacks GenServer is running
    case Process.whereis(ModelPacks) do
      nil ->
        start_supervised!(ModelPacks)

      _pid ->
        :ok
    end

    # Clean up any test user packs
    for pack <- ModelPacks.list_packs() do
      if not ModelPacks.builtin_pack?(pack.name) and String.starts_with?(pack.name, "test-") do
        ModelPacks.delete_pack(pack.name)
      end
    end

    :ok
  end

  # ============================================================================
  # Initialization Tests
  # ============================================================================

  describe "initialization" do
    test "starts with all default packs loaded" do
      packs = ModelPacks.list_packs()
      pack_names = Enum.map(packs, & &1.name)

      assert "single" in pack_names
      assert "coding" in pack_names
      assert "economical" in pack_names
      assert "capacity" in pack_names
    end

    test "default packs have correct structure" do
      single = ModelPacks.get_pack("single")
      assert single.name == "single"
      assert single.description == "Use one model for all tasks"
      assert single.default_role == "coder"
      assert map_size(single.roles) == 5
      assert single.roles["planner"].primary == "auto"
    end

    test "single pack uses auto for all roles" do
      single = ModelPacks.get_pack("single")

      assert single.roles["planner"].primary == "auto"
      assert single.roles["coder"].primary == "auto"
      assert single.roles["reviewer"].primary == "auto"
      assert single.roles["summarizer"].primary == "auto"
      assert single.roles["title"].primary == "auto"
    end

    test "coding pack has correct roles configuration" do
      coding = ModelPacks.get_pack("coding")
      assert coding.name == "coding"
      assert coding.description == "Optimized for coding tasks with specialized models"

      assert coding.roles["coder"].primary == "wafer-glm-5.1"
      assert coding.roles["coder"].fallbacks == ["firepass-kimi-k2p5-turbo", "wafer-qwen3.5-397b"]
      assert coding.roles["coder"].trigger == "provider_failure"

      assert coding.roles["planner"].primary == "claude-sonnet-4"
      assert coding.roles["planner"].trigger == "context_overflow"
    end

    test "economical pack uses cost-effective models" do
      economical = ModelPacks.get_pack("economical")
      assert economical.name == "economical"
      assert economical.description == "Cost-effective model selection for budget-conscious usage"

      assert economical.roles["planner"].primary == "gemini-2.5-flash"
      assert economical.roles["coder"].primary == "firepass-kimi-k2p5-turbo"
      assert economical.roles["reviewer"].primary == "gpt-4o-mini"
    end

    test "capacity pack uses high-capacity models" do
      capacity = ModelPacks.get_pack("capacity")
      assert capacity.name == "capacity"
      assert capacity.description == "Models with large context windows for big tasks"

      assert capacity.roles["planner"].primary == "firepass-kimi-k2p5-turbo"
      assert capacity.roles["coder"].primary == "wafer-qwen3.5-397b"

      # All roles in capacity pack use context_overflow trigger
      assert capacity.roles["planner"].trigger == "context_overflow"
      assert capacity.roles["coder"].trigger == "context_overflow"
      assert capacity.roles["reviewer"].trigger == "context_overflow"
    end
  end

  # ============================================================================
  # Get Pack Tests
  # ============================================================================

  describe "get_pack/1" do
    test "returns pack by name" do
      pack = ModelPacks.get_pack("coding")
      assert %ModelPack{} = pack
      assert pack.name == "coding"
    end

    test "returns current pack when name is nil" do
      ModelPacks.set_current_pack("economical")
      pack = ModelPacks.get_pack(nil)
      assert pack.name == "economical"
    end

    test "falls back to single pack for unknown name" do
      pack = ModelPacks.get_pack("nonexistent-pack")
      assert pack.name == "single"
    end
  end

  # ============================================================================
  # List Packs Tests
  # ============================================================================

  describe "list_packs/0" do
    test "returns all packs sorted by name" do
      packs = ModelPacks.list_packs()
      pack_names = Enum.map(packs, & &1.name)

      assert pack_names == Enum.sort(pack_names)
      # At least 4 built-in packs
      assert length(packs) >= 4
    end

    test "returns pack structs" do
      packs = ModelPacks.list_packs()
      assert Enum.all?(packs, fn pack -> match?(%ModelPack{}, pack) end)
    end
  end

  # ============================================================================
  # Current Pack Tests
  # ============================================================================

  describe "set_current_pack/1" do
    test "sets the current pack when pack exists" do
      assert :ok = ModelPacks.set_current_pack("coding")
      assert ModelPacks.get_current_pack().name == "coding"
    end

    test "returns error for non-existent pack" do
      assert {:error, :not_found} = ModelPacks.set_current_pack("nonexistent")
      # Current pack should remain unchanged
      assert ModelPacks.get_current_pack().name == "single"
    end

    test "can switch between packs" do
      :ok = ModelPacks.set_current_pack("coding")
      assert ModelPacks.get_current_pack().name == "coding"

      :ok = ModelPacks.set_current_pack("capacity")
      assert ModelPacks.get_current_pack().name == "capacity"

      :ok = ModelPacks.set_current_pack("single")
      assert ModelPacks.get_current_pack().name == "single"
    end
  end

  describe "get_current_pack/0" do
    test "returns current pack" do
      ModelPacks.set_current_pack("economical")
      pack = ModelPacks.get_current_pack()
      assert pack.name == "economical"
    end

    test "defaults to single pack" do
      # Reset to single for clean state
      ModelPacks.set_current_pack("single")
      pack = ModelPacks.get_current_pack()
      assert pack.name == "single"
    end
  end

  # ============================================================================
  # Role Resolution Tests
  # ============================================================================

  describe "get_model_for_role/1" do
    test "returns primary model for a role in current pack" do
      ModelPacks.set_current_pack("coding")
      assert ModelPacks.get_model_for_role("coder") == "wafer-glm-5.1"
      assert ModelPacks.get_model_for_role("planner") == "claude-sonnet-4"
    end

    test "uses default_role when role is nil" do
      ModelPacks.set_current_pack("coding")
      # coding pack's default_role is "coder"
      assert ModelPacks.get_model_for_role(nil) == "wafer-glm-5.1"
    end

    test "falls back to default_role for unknown role" do
      ModelPacks.set_current_pack("coding")
      # Unknown role should fall back to default_role (coder)
      assert ModelPacks.get_model_for_role("unknown-role") == "wafer-glm-5.1"
    end

    test "returns auto for single pack roles" do
      ModelPacks.set_current_pack("single")
      assert ModelPacks.get_model_for_role("coder") == "auto"
      assert ModelPacks.get_model_for_role("planner") == "auto"
    end
  end

  describe "get_fallback_chain/1" do
    test "returns full chain for a role" do
      ModelPacks.set_current_pack("coding")
      chain = ModelPacks.get_fallback_chain("coder")

      assert chain == ["wafer-glm-5.1", "firepass-kimi-k2p5-turbo", "wafer-qwen3.5-397b"]
    end

    test "returns single item when no fallbacks" do
      ModelPacks.set_current_pack("single")
      chain = ModelPacks.get_fallback_chain("coder")

      assert chain == ["auto"]
    end

    test "uses default_role when role is nil" do
      ModelPacks.set_current_pack("coding")
      chain = ModelPacks.get_fallback_chain(nil)

      # Should use coder role (the default)
      assert chain == ["wafer-glm-5.1", "firepass-kimi-k2p5-turbo", "wafer-qwen3.5-397b"]
    end
  end

  # ============================================================================
  # User Pack Tests
  # ============================================================================

  describe "create_pack/4" do
    test "creates a new user pack" do
      roles = %{
        "coder" => %{
          primary: "gpt-4",
          fallbacks: ["gpt-3.5"],
          trigger: "provider_failure"
        },
        "planner" => %{
          primary: "claude-3",
          fallbacks: [],
          trigger: "context_overflow"
        }
      }

      assert {:ok, pack} = ModelPacks.create_pack("test-custom", "My test pack", roles, "coder")
      assert pack.name == "test-custom"
      assert pack.description == "My test pack"
      assert pack.default_role == "coder"
      assert pack.roles["coder"].primary == "gpt-4"
    end

    test "user pack appears in list" do
      roles = %{"coder" => %{primary: "gpt-4", fallbacks: []}}
      {:ok, _} = ModelPacks.create_pack("test-listable", "Test", roles)

      pack_names = ModelPacks.list_packs() |> Enum.map(& &1.name)
      assert "test-listable" in pack_names
    end

    test "cannot create pack with built-in name" do
      roles = %{"coder" => %{primary: "gpt-4", fallbacks: []}}

      assert {:error, :builtin_pack} =
               ModelPacks.create_pack("single", "Cannot override", roles)

      assert {:error, :builtin_pack} =
               ModelPacks.create_pack("coding", "Cannot override", roles)
    end

    test "user pack can be retrieved" do
      roles = %{
        "reviewer" => %{
          primary: "claude-sonnet",
          fallbacks: ["gpt-4o-mini"],
          trigger: "always"
        }
      }

      {:ok, _} = ModelPacks.create_pack("test-retrievable", "Test", roles, "reviewer")
      pack = ModelPacks.get_pack("test-retrievable")

      assert pack.name == "test-retrievable"
      assert pack.roles["reviewer"].primary == "claude-sonnet"
    end
  end

  describe "delete_pack/1" do
    test "deletes a user pack" do
      roles = %{"coder" => %{primary: "gpt-4", fallbacks: []}}
      {:ok, _} = ModelPacks.create_pack("test-deletable", "Test", roles)

      assert ModelPacks.delete_pack("test-deletable") == true

      pack_names = ModelPacks.list_packs() |> Enum.map(& &1.name)
      refute "test-deletable" in pack_names
    end

    test "returns false for non-existent pack" do
      assert ModelPacks.delete_pack("never-existed-pack") == false
    end

    test "cannot delete built-in packs" do
      assert ModelPacks.delete_pack("single") == false
      assert ModelPacks.delete_pack("coding") == false
      assert ModelPacks.delete_pack("economical") == false
      assert ModelPacks.delete_pack("capacity") == false
    end

    test "deleting current pack resets to single" do
      roles = %{"coder" => %{primary: "gpt-4", fallbacks: []}}
      {:ok, _} = ModelPacks.create_pack("test-current", "Test", roles)

      ModelPacks.set_current_pack("test-current")
      assert ModelPacks.get_current_pack().name == "test-current"

      ModelPacks.delete_pack("test-current")
      assert ModelPacks.get_current_pack().name == "single"
    end
  end

  # ============================================================================
  # Persistence Tests
  # ============================================================================

  describe "persistence" do
    test "user packs persist and reload" do
      roles = %{
        "coder" => %{
          primary: "custom-model",
          fallbacks: ["fallback-1", "fallback-2"],
          trigger: "provider_failure"
        }
      }

      {:ok, created} =
        ModelPacks.create_pack("test-persist", "Persistence test", roles, "coder")

      assert created.roles["coder"].primary == "custom-model"

      # Reload from disk
      :ok = ModelPacks.reload()

      # Pack should still exist after reload
      reloaded = ModelPacks.get_pack("test-persist")
      assert reloaded.name == "test-persist"
      assert reloaded.roles["coder"].primary == "custom-model"
      assert reloaded.roles["coder"].fallbacks == ["fallback-1", "fallback-2"]
    end

    test "deletion persists across reloads" do
      roles = %{"coder" => %{primary: "gpt-4", fallbacks: []}}
      {:ok, _} = ModelPacks.create_pack("test-delete-persist", "Test", roles)

      ModelPacks.delete_pack("test-delete-persist")
      :ok = ModelPacks.reload()

      pack_names = ModelPacks.list_packs() |> Enum.map(& &1.name)
      refute "test-delete-persist" in pack_names
    end

    test "reload resets current pack if it no longer exists" do
      roles = %{"coder" => %{primary: "gpt-4", fallbacks: []}}
      {:ok, _} = ModelPacks.create_pack("test-reload-reset", "Test", roles)

      ModelPacks.set_current_pack("test-reload-reset")

      # Manually delete the pack file entry and reload
      ModelPacks.delete_pack("test-reload-reset")
      :ok = ModelPacks.reload()

      # Should reset to single
      assert ModelPacks.get_current_pack().name == "single"
    end
  end

  # ============================================================================
  # RoleConfig Struct Tests
  # ============================================================================

  describe "RoleConfig struct" do
    test "has correct default values" do
      config = %RoleConfig{primary: "gpt-4"}

      assert config.primary == "gpt-4"
      assert config.fallbacks == []
      assert config.trigger == "provider_failure"
    end

    test "get_model_chain returns primary + fallbacks" do
      config = %RoleConfig{
        primary: "model-a",
        fallbacks: ["model-b", "model-c"]
      }

      assert RoleConfig.get_model_chain(config) == ["model-a", "model-b", "model-c"]
    end

    test "get_model_chain with no fallbacks returns just primary" do
      config = %RoleConfig{primary: "model-x", fallbacks: []}
      assert RoleConfig.get_model_chain(config) == ["model-x"]
    end
  end

  # ============================================================================
  # ModelPack Struct Tests
  # ============================================================================

  describe "ModelPack struct" do
    test "get_model_for_role returns primary for existing role" do
      pack = %ModelPack{
        name: "test",
        description: "Test",
        roles: %{
          "coder" => %RoleConfig{primary: "gpt-4"},
          "planner" => %RoleConfig{primary: "claude-3"}
        },
        default_role: "coder"
      }

      assert ModelPack.get_model_for_role(pack, "coder") == "gpt-4"
      assert ModelPack.get_model_for_role(pack, "planner") == "claude-3"
    end

    test "get_model_for_role falls back to default_role for unknown role" do
      pack = %ModelPack{
        name: "test",
        description: "Test",
        roles: %{
          "coder" => %RoleConfig{primary: "gpt-4"}
        },
        default_role: "coder"
      }

      assert ModelPack.get_model_for_role(pack, "unknown") == "gpt-4"
    end

    test "get_model_for_role uses default_role when role is nil" do
      pack = %ModelPack{
        name: "test",
        description: "Test",
        roles: %{
          "coder" => %RoleConfig{primary: "gpt-4"},
          "planner" => %RoleConfig{primary: "claude-3"}
        },
        default_role: "planner"
      }

      assert ModelPack.get_model_for_role(pack, nil) == "claude-3"
    end

    test "get_fallback_chain returns full chain" do
      pack = %ModelPack{
        name: "test",
        description: "Test",
        roles: %{
          "coder" => %RoleConfig{primary: "gpt-4", fallbacks: ["gpt-3.5", "gpt-3"]}
        },
        default_role: "coder"
      }

      assert ModelPack.get_fallback_chain(pack, "coder") == ["gpt-4", "gpt-3.5", "gpt-3"]
    end

    test "to_map converts pack to map" do
      pack = %ModelPack{
        name: "test",
        description: "Test pack",
        roles: %{
          "coder" => %RoleConfig{primary: "gpt-4", fallbacks: ["gpt-3.5"], trigger: "always"}
        },
        default_role: "coder"
      }

      map = ModelPack.to_map(pack)

      assert map.name == "test"
      assert map.description == "Test pack"
      assert map.default_role == "coder"
      assert map.roles["coder"].primary == "gpt-4"
      assert map.roles["coder"].fallbacks == ["gpt-3.5"]
    end
  end

  # ============================================================================
  # Utility Tests
  # ============================================================================

  describe "builtin_pack?/1" do
    test "returns true for built-in packs" do
      assert ModelPacks.builtin_pack?("single")
      assert ModelPacks.builtin_pack?("coding")
      assert ModelPacks.builtin_pack?("economical")
      assert ModelPacks.builtin_pack?("capacity")
    end

    test "returns false for non-built-in packs" do
      refute ModelPacks.builtin_pack?("custom-pack")
      refute ModelPacks.builtin_pack?("my-pack")
    end
  end

  describe "reload/0" do
    test "reloads user packs from disk" do
      # This is tested more thoroughly in persistence tests
      assert :ok = ModelPacks.reload()
    end

    test "built-in packs remain after reload" do
      :ok = ModelPacks.reload()

      pack_names = ModelPacks.list_packs() |> Enum.map(& &1.name)
      assert "single" in pack_names
      assert "coding" in pack_names
      assert "economical" in pack_names
      assert "capacity" in pack_names
    end
  end
end
