defmodule CodePuppyControl.LLM.ModelPacksPropertyTest do
  @moduledoc """
  Property-based tests for ModelPacks behavioral invariants.

  Tests REAL routing and fallback behavior, not struct-field tautologies:
  - Unknown roles always route through default_role
  - nil role delegates to default_role
  - Orphan default_role (not in roles) degrades to "auto"
  - Fallback chain for unknown roles delegates to default_role's chain
  - Fallback chains contain no duplicates when inputs are distinct
  - to_map preserves all role data
  - create_pack + retrieval round-trips correctly
  - All default packs have consistent structure
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :property

  alias CodePuppyControl.ModelPacks
  alias CodePuppyControl.ModelPacks.{ModelPack, RoleConfig}

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelPacks)
    ModelPacks.set_current_pack("single")

    # Clean up any test user packs
    for pack <- ModelPacks.list_packs() do
      if not ModelPacks.builtin_pack?(pack.name) and String.starts_with?(pack.name, "test-pp-") do
        ModelPacks.delete_pack(pack.name)
      end
    end

    :ok
  end

  # ── RoleConfig Properties ───────────────────────────────────────────────

  describe "RoleConfig properties" do
    property "get_model_chain always starts with primary" do
      check all(
              primary <- string(:alphanumeric, min_length: 1, max_length: 20),
              fallbacks <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20), max_length: 5)
            ) do
        config = %RoleConfig{primary: primary, fallbacks: fallbacks}
        chain = RoleConfig.get_model_chain(config)

        assert hd(chain) == primary
        assert length(chain) == 1 + length(fallbacks)
      end
    end

    property "get_model_chain returns primary + fallbacks in order" do
      check all(primary <- string(:alphanumeric, min_length: 1, max_length: 20)) do
        fallbacks = ["fb-a", "fb-b", "fb-c"]
        config = %RoleConfig{primary: primary, fallbacks: fallbacks}
        chain = RoleConfig.get_model_chain(config)

        assert chain == [primary] ++ fallbacks
      end
    end
  end

  # ── ModelPack Properties ────────────────────────────────────────────────

  describe "ModelPack properties" do
    property "get_model_for_role always returns a string for non-nil roles" do
      check all(
              primary <- string(:alphanumeric, min_length: 1, max_length: 20),
              role <- string(:alphanumeric, min_length: 1, max_length: 15)
            ) do
        pack = %ModelPack{
          name: "prop-test",
          description: "Property test pack",
          roles: %{role => %RoleConfig{primary: primary}},
          default_role: role
        }

        result = ModelPack.get_model_for_role(pack, role)
        assert is_binary(result)
        assert result == primary
      end
    end

    property "get_model_for_role falls back to default_role for unknown roles" do
      check all(
              primary <- string(:alphanumeric, min_length: 1, max_length: 20),
              unknown_role <- string(:alphanumeric, min_length: 20, max_length: 30)
            ) do
        default_role = "coder"

        pack = %ModelPack{
          name: "prop-test",
          description: "Property test pack",
          roles: %{default_role => %RoleConfig{primary: primary}},
          default_role: default_role
        }

        # min_length: 20 guarantees unknown_role != "coder" (5 chars)
        result = ModelPack.get_model_for_role(pack, unknown_role)
        assert is_binary(result)
        assert result == primary
      end
    end

    property "get_fallback_chain always includes primary as first element" do
      check all(
              primary <- string(:alphanumeric, min_length: 1, max_length: 20),
              fallback_count <- integer(0..4)
            ) do
        fallbacks =
          if fallback_count > 0, do: for(i <- 1..fallback_count, do: "fallback-#{i}"), else: []

        role = "coder"

        pack = %ModelPack{
          name: "prop-test",
          description: "Property test pack",
          roles: %{role => %RoleConfig{primary: primary, fallbacks: fallbacks}},
          default_role: role
        }

        chain = ModelPack.get_fallback_chain(pack, role)
        assert hd(chain) == primary
      end
    end
  end

  # ── Default Pack Invariants ────────────────────────────────────────────

  describe "default pack invariants" do
    test "all default packs have at least one role" do
      for name <- ["single", "coding", "economical", "capacity"] do
        pack = ModelPacks.get_pack(name)
        assert map_size(pack.roles) >= 1, "Pack '#{name}' should have at least one role"
      end
    end

    test "all default packs have a valid default_role" do
      for name <- ["single", "coding", "economical", "capacity"] do
        pack = ModelPacks.get_pack(name)

        assert Map.has_key?(pack.roles, pack.default_role),
               "Pack '#{name}' default_role '#{pack.default_role}' not in roles"
      end
    end

    test "all default packs have string primary models in each role" do
      for name <- ["single", "coding", "economical", "capacity"] do
        pack = ModelPacks.get_pack(name)

        Enum.each(pack.roles, fn {role_name, config} ->
          assert is_binary(config.primary),
                 "Pack '#{name}' role '#{role_name}' primary should be a string"

          assert is_list(config.fallbacks),
                 "Pack '#{name}' role '#{role_name}' fallbacks should be a list"

          assert config.trigger in ["provider_failure", "context_overflow", "always"],
                 "Pack '#{name}' role '#{role_name}' trigger should be valid"
        end)
      end
    end

    test "coding pack has fallbacks for coder role" do
      coding = ModelPacks.get_pack("coding")
      assert length(coding.roles["coder"].fallbacks) > 0
    end

    test "single pack uses auto for all roles" do
      single = ModelPacks.get_pack("single")

      Enum.each(single.roles, fn {_role, config} ->
        assert config.primary == "auto"
      end)
    end
  end

  # ── Real Behavior Invariant Properties ────────────────────────────────

  describe "get_model_for_role routing invariants" do
    property "unknown role always resolves to the default_role's primary" do
      check all(
              default_primary <- string(:alphanumeric, min_length: 1, max_length: 15),
              unknown_role <- string(:alphanumeric, min_length: 20, max_length: 30),
              default_role <- member_of(["coder", "planner", "reviewer"])
            ) do
        # min_length: 20 guarantees unknown_role != any 6-char role name
        pack = %ModelPack{
          name: "route-test",
          description: "Test",
          roles: %{default_role => %RoleConfig{primary: default_primary}},
          default_role: default_role
        }

        result = ModelPack.get_model_for_role(pack, unknown_role)

        # The REAL invariant: unknown roles route through default_role logic
        assert result == default_primary,
               "unknown role '#{unknown_role}' should resolve to default_role's primary"
      end
    end

    property "nil role delegates to default_role" do
      check all(
              default_primary <- string(:alphanumeric, min_length: 1, max_length: 15),
              other_primary <- string(:alphanumeric, min_length: 1, max_length: 15),
              max_attempts: 20
            ) do
        if default_primary != other_primary do
          pack = %ModelPack{
            name: "nil-role-test",
            description: "Test",
            roles: %{
              "coder" => %RoleConfig{primary: default_primary},
              "planner" => %RoleConfig{primary: other_primary}
            },
            default_role: "coder"
          }

          # nil MUST route to the default_role, not some other role
          assert ModelPack.get_model_for_role(pack, nil) == default_primary
          # And explicitly requesting the default_role gives the same result
          assert ModelPack.get_model_for_role(pack, "coder") == default_primary
          # But a different known role gives a DIFFERENT result
          assert ModelPack.get_model_for_role(pack, "planner") == other_primary
        end
      end
    end

    property "default_role missing from roles returns 'auto'" do
      check all(
              role <- string(:alphanumeric, min_length: 1, max_length: 10),
              primary <- string(:alphanumeric, min_length: 1, max_length: 15)
            ) do
        # If default_role points to a non-existent role, get_model_for_role
        # must return "auto" as a safe fallback — NOT crash or return nil
        pack = %ModelPack{
          name: "orphan-default-test",
          description: "Test",
          roles: %{role => %RoleConfig{primary: primary}},
          default_role: "nonexistent"
        }

        # Requesting the orphan default_role directly
        assert ModelPack.get_model_for_role(pack, "nonexistent") == "auto"

        # Unknown role falls back to default_role which is also missing → "auto"
        assert ModelPack.get_model_for_role(pack, "also_missing") == "auto"
      end
    end
  end

  describe "get_fallback_chain routing invariants" do
    property "fallback chain for unknown role delegates to default_role's chain" do
      check all(
              primary <- string(:alphanumeric, min_length: 1, max_length: 15),
              fallback_count <- integer(1..4),
              unknown_role <- string(:alphanumeric, min_length: 20, max_length: 30)
            ) do
        fallbacks = for i <- 1..fallback_count, do: "fb-#{i}"

        pack = %ModelPack{
          name: "chain-route-test",
          description: "Test",
          roles: %{"coder" => %RoleConfig{primary: primary, fallbacks: fallbacks}},
          default_role: "coder"
        }

        chain = ModelPack.get_fallback_chain(pack, unknown_role)
        expected = ModelPack.get_fallback_chain(pack, "coder")

        # The REAL invariant: unknown roles get the SAME chain as default_role
        assert chain == expected
      end
    end

    property "fallback chain for orphan default_role returns [\"auto\"]" do
      check all(
              role <- string(:alphanumeric, min_length: 1, max_length: 10),
              primary <- string(:alphanumeric, min_length: 1, max_length: 15)
            ) do
        pack = %ModelPack{
          name: "orphan-chain-test",
          description: "Test",
          roles: %{role => %RoleConfig{primary: primary}},
          default_role: "nonexistent"
        }

        # When default_role doesn't exist, chain degrades to ["auto"]
        assert ModelPack.get_fallback_chain(pack, "nonexistent") == ["auto"]
        assert ModelPack.get_fallback_chain(pack, nil) == ["auto"]
      end
    end

    property "fallback chain has no duplicate models when fallbacks don't contain primary" do
      check all(
              primary <- string(:alphanumeric, min_length: 5, max_length: 15),
              fb1 <- string(:alphanumeric, min_length: 5, max_length: 15),
              fb2 <- string(:alphanumeric, min_length: 5, max_length: 15),
              max_attempts: 30
            ) do
        # Filter to ensure all three are distinct (stream_data may generate collisions)
        if primary != fb1 and primary != fb2 and fb1 != fb2 do
          pack = %ModelPack{
            name: "no-dupe-test",
            description: "Test",
            roles: %{"coder" => %RoleConfig{primary: primary, fallbacks: [fb1, fb2]}},
            default_role: "coder"
          }

          chain = ModelPack.get_fallback_chain(pack, "coder")

          # REAL invariant: no model appears twice in the chain
          assert length(chain) == length(Enum.uniq(chain)),
                 "fallback chain should have no duplicates, got: #{inspect(chain)}"
        end
      end
    end
  end

  describe "to_map round-trip invariant" do
    property "to_map preserves all role primaries and fallbacks" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 12),
              primary_a <- string(:alphanumeric, min_length: 1, max_length: 15),
              primary_b <- string(:alphanumeric, min_length: 1, max_length: 15),
              fallback_count <- integer(0..3)
            ) do
        fallbacks =
          if fallback_count > 0, do: for(i <- 1..fallback_count, do: "fb-#{i}"), else: []

        pack = %ModelPack{
          name: name,
          description: "Round-trip test",
          roles: %{
            "coder" => %RoleConfig{primary: primary_a, fallbacks: fallbacks},
            "planner" => %RoleConfig{primary: primary_b}
          },
          default_role: "coder"
        }

        mapped = ModelPack.to_map(pack)

        # to_map must preserve name, description, default_role
        assert mapped[:name] == name
        assert mapped[:description] == "Round-trip test"
        assert mapped[:default_role] == "coder"

        # to_map must preserve role primaries and fallbacks
        assert mapped[:roles]["coder"][:primary] == primary_a
        assert mapped[:roles]["coder"][:fallbacks] == fallbacks
        assert mapped[:roles]["planner"][:primary] == primary_b
      end
    end
  end

  describe "create_pack + get_model_for_role integration" do
    property "a created pack's roles are retrievable via get_model_for_role" do
      check all(
              primary <- string(:alphanumeric, min_length: 1, max_length: 15),
              fb1 <- string(:alphanumeric, min_length: 1, max_length: 15),
              max_attempts: 20
            ) do
        name = "test-pp-prop-#{:erlang.unique_integer([:positive])}"

        roles = %{
          "coder" => %{
            "primary" => primary,
            "fallbacks" => [fb1],
            "trigger" => "provider_failure"
          }
        }

        assert {:ok, _pack} = ModelPacks.create_pack(name, "Property test pack", roles, "coder")

        # Now verify the REAL behavior: the GenServer stores it and
        # get_model_for_role through the pack resolves correctly
        retrieved = ModelPacks.get_pack(name)
        assert ModelPack.get_model_for_role(retrieved, "coder") == primary
        assert ModelPack.get_fallback_chain(retrieved, "coder") == [primary, fb1]

        # And unknown role falls back to coder's primary
        assert ModelPack.get_model_for_role(retrieved, "nonexistent") == primary

        # Clean up
        ModelPacks.delete_pack(name)
      end
    end
  end

  # ── User Pack CRUD Properties ──────────────────────────────────────────

  describe "user pack operations" do
    test "create and delete user pack round-trip" do
      name = "test-pp-crud-#{:erlang.unique_integer([:positive])}"

      roles = %{
        "coder" => %{
          primary: "test-model",
          fallbacks: [],
          trigger: "provider_failure"
        }
      }

      assert {:ok, pack} = ModelPacks.create_pack(name, "Test pack", roles, "coder")
      assert pack.name == name

      retrieved = ModelPacks.get_pack(name)
      assert retrieved.name == name

      assert ModelPacks.delete_pack(name) == true

      # Falls back to single
      fallback = ModelPacks.get_pack(name)
      assert fallback.name == "single"
    end

    test "cannot create pack with built-in name" do
      for builtin <- ["single", "coding", "economical", "capacity"] do
        assert {:error, :builtin_pack} =
                 ModelPacks.create_pack(builtin, "Override", %{"coder" => %{primary: "x"}})
      end
    end

    test "cannot delete built-in packs" do
      for builtin <- ["single", "coding", "economical", "capacity"] do
        assert ModelPacks.delete_pack(builtin) == false
      end
    end
  end
end
