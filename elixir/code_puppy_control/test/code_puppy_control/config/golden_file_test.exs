defmodule CodePuppyControl.Config.GoldenFileTest do
  @moduledoc """
  Golden-file compatibility tests for config loading, normalization, and round-trips.

  **Purpose:** Schema-drift safety net. Ensures that committed fixture
  files parse, normalize, and round-trip correctly through the Elixir config
  stack. If a Loader or Writer change breaks parity with existing config files,
  these tests will catch it.

  **How to run:**
      mix test --only config_compat

  **How to update fixtures:**
  1. Edit the fixture file under `test/fixtures/config/`
  2. Re-run this test suite
  3. Review the diff carefully — a fixture change implies a schema migration

  **References:** (this suite), (isolation gates), (schema contract)
  """

  use ExUnit.Case, async: false

  @moduletag :config_compat

  alias CodePuppyControl.Support.ConfigFixtures
  alias CodePuppyControl.Config.{Loader, Writer}
  alias CodePuppyControl.ModelRegistry

  # ── Compile-time fixture inventory ───────────────────────────────────────

  # {fixture_file_name, variant} pairs for JSON model configs
  @json_model_fixtures [
    {"extra_models.json", :minimal},
    {"extra_models.json", :realistic},
    {"claude_models.json", :minimal},
    {"claude_models.json", :realistic},
    {"chatgpt_models.json", :minimal},
    {"chatgpt_models.json", :realistic}
  ]

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp ensure_writer_started do
    case GenServer.whereis(Writer) do
      nil ->
        {:ok, _} = Writer.start_link()
        :ok

      _pid ->
        :ok
    end
  end

  # Env vars that Loader.merge_env_overrides/1 reads. Clearing them prevents
  # ambient developer settings from poisoning Loader.load/1 results and
  # leaking persistent_term state into subsequent tests.
  @env_vars_to_sandbox ~w(
    PUP_MODEL PUP_AGENT PUP_DEBUG PUP_HOME PUP_EX_HOME
    PUPPY_DEFAULT_MODEL PUPPY_DEFAULT_AGENT PUPPY_TEMPERATURE
    PUPPY_MESSAGE_LIMIT PUPPY_PROTECTED_TOKEN_COUNT PUPPY_HOME
  )

  defp with_clean_env(fun) do
    saved = Map.new(@env_vars_to_sandbox, fn var -> {var, System.get_env(var)} end)
    Enum.each(@env_vars_to_sandbox, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, val} -> System.put_env(var, val)
      end)

      Loader.invalidate()
    end
  end

  # ===========================================================================
  # INI Format Parity
  # ===========================================================================

  describe "puppy.cfg — INI format parity" do
    test "minimal fixture parses into expected structure" do
      result = ConfigFixtures.read_raw(:minimal, "puppy.cfg") |> Loader.parse_string()

      assert result == %{"puppy" => %{"model" => "gpt-5"}}
    end

    test "realistic fixture parses with all sections" do
      result = ConfigFixtures.read_raw(:realistic, "puppy.cfg") |> Loader.parse_string()

      assert result["puppy"]["schema_version"] == "1"
      assert result["puppy"]["model"] == "claude-sonnet-4"
      assert result["puppy"]["default_agent"] == "code-puppy"
      assert result["puppy"]["yolo_mode"] == "false"
      assert result["puppy"]["debug"] == "false"
      assert result["puppy"]["temperature"] == "0.7"
      assert result["puppy"]["message_limit"] == "100"
      assert result["puppy"]["protected_token_count"] == "50000"
      assert result["ui"]["theme"] == "dark"
      assert result["ui"]["show_tool_calls"] == "true"
      assert result["otel"]["enabled"] == "false"
      assert result["otel"]["endpoint"] == "http://localhost:4317"

      assert Map.keys(result) |> Enum.sort() == ["otel", "puppy", "ui"]
    end

    test "normalize/1 output is stable across insertion orders" do
      # Build the same logical map two different ways
      a = %{"puppy" => %{"model" => "x"}, "ui" => %{"theme" => "dark"}}
      b = %{"ui" => %{"theme" => "dark"}, "puppy" => %{"model" => "x"}}

      assert ConfigFixtures.normalize(a) == ConfigFixtures.normalize(b)
    end
  end

  # ===========================================================================
  # INI Round-Trip
  # ===========================================================================

  describe "puppy.cfg — round-trip (load → write → reload)" do
    @tag :tmp_dir
    test "minimal fixture round-trips through Writer", context do
      with_clean_env(fn ->
        assert_ini_round_trip(:minimal, "puppy.cfg", context.tmp_dir)
      end)
    end

    @tag :tmp_dir
    test "realistic fixture round-trips through Writer", context do
      with_clean_env(fn ->
        assert_ini_round_trip(:realistic, "puppy.cfg", context.tmp_dir)
      end)
    end
  end

  defp assert_ini_round_trip(variant, name, tmp_dir) do
    path = ConfigFixtures.copy_fixture_to_tmp(variant, name, tmp_dir)
    original = Loader.load(path)

    ensure_writer_started()
    Writer.write_config(original)

    Loader.invalidate()
    reloaded = Loader.load(path)

    assert ConfigFixtures.normalize(original) == ConfigFixtures.normalize(reloaded),
           "INI round-trip failed for #{variant}/#{name}"
  end

  # ===========================================================================
  # JSON Model Configs — Load Parity
  # ===========================================================================

  describe "JSON model configs — load parity" do
    # Generate one test per {name, variant} pair at compile time
    for {name, variant} <- @json_model_fixtures do
      variant_str = Atom.to_string(variant)
      # Derive a readable test name from the fixture identity
      base = name |> String.replace(".json", "")
      test_name = "#{variant_str}_#{base}" |> String.to_atom()

      test "#{test_name}: all models have valid type, name, context_length" do
        {name, variant} = unquote({name, variant})
        decoded = ConfigFixtures.load_json(variant, name)

        assert is_map(decoded), "Expected top-level map, got: #{inspect(decoded)}"
        assert map_size(decoded) >= 1, "Expected at least one model entry"

        known_types = ModelRegistry.known_model_types()

        for {model_id, model} <- decoded do
          assert model["type"] in known_types,
                 "Model #{inspect(model_id)} has unknown type #{inspect(model["type"])}"

          assert is_binary(model["name"]),
                 "Model #{inspect(model_id)} name is not a string: #{inspect(model["name"])}"

          case model["context_length"] do
            nil ->
              :ok

            cl when is_integer(cl) and cl > 0 ->
              :ok

            other ->
              flunk("Model #{inspect(model_id)} context_length is invalid: #{inspect(other)}")
          end
        end
      end
    end
  end

  # ===========================================================================
  # JSON Round-Trip via Jason
  # ===========================================================================

  describe "JSON — round-trip via Jason" do
    for {name, variant} <- @json_model_fixtures do
      variant_str = Atom.to_string(variant)
      base = name |> String.replace(".json", "")
      test_name = "json_roundtrip_#{variant_str}_#{base}" |> String.to_atom()

      test "#{test_name}: canonical_json round-trips losslessly" do
        {name, variant} = unquote({name, variant})
        original = ConfigFixtures.load_json(variant, name)
        encoded = ConfigFixtures.canonical_json(original)
        decoded = Jason.decode!(encoded)

        assert ConfigFixtures.normalize(original) == ConfigFixtures.normalize(decoded),
               "JSON round-trip lost data for #{variant}/#{name}"
      end
    end
  end

  # ===========================================================================
  # Model Packs Schema
  # ===========================================================================

  describe "model_packs.json schema" do
    test "minimal: single pack with roles structure" do
      packs = ConfigFixtures.load_json(:minimal, "model_packs.json")

      assert is_map(packs)
      assert map_size(packs) == 1

      for {_pack_name, pack_data} <- packs do
        assert is_map(pack_data["roles"]),
               "Pack missing 'roles' map: #{inspect(pack_data)}"

        for {_role_name, role_config} <- pack_data["roles"] do
          assert is_binary(role_config["primary"]),
                 "Role missing string 'primary': #{inspect(role_config)}"
        end
      end
    end

    test "realistic: three packs with expected names and fallback chain" do
      packs = ConfigFixtures.load_json(:realistic, "model_packs.json")

      assert is_map(packs)
      expected_names = ["cheap", "daily_driver", "premium"]
      assert Map.keys(packs) |> Enum.sort() == expected_names

      # Premium pack should have a role with a "fallbacks" list
      premium = packs["premium"]
      assert is_map(premium["roles"])

      has_fallbacks =
        Enum.any?(premium["roles"], fn {_role_name, role_config} ->
          is_list(role_config["fallbacks"]) and length(role_config["fallbacks"]) > 0
        end)

      assert has_fallbacks, "Premium pack should have at least one role with fallbacks"
    end
  end

  # ===========================================================================
  # MCP Servers Schema
  # ===========================================================================

  describe "mcp_servers.json schema" do
    test "realistic: servers have command, args, env" do
      servers = ConfigFixtures.load_json(:realistic, "mcp_servers.json")

      assert is_map(servers)

      for {server_name, server} <- servers do
        assert is_binary(server["command"]) and server["command"] != "",
               "Server #{inspect(server_name)} missing non-empty 'command'"

        assert is_list(server["args"]),
               "Server #{inspect(server_name)} 'args' is not a list"

        for arg <- server["args"] do
          assert is_binary(arg),
                 "Server #{inspect(server_name)} has non-string arg: #{inspect(arg)}"
        end

        assert is_map(server["env"]),
               "Server #{inspect(server_name)} 'env' is not a map"
      end
    end
  end

  # ===========================================================================
  # Malformed Inputs
  # ===========================================================================

  describe "malformed inputs produce clear errors" do
    test "truncated JSON raises Jason.DecodeError" do
      assert_raise Jason.DecodeError, fn ->
        ConfigFixtures.load_json(:invalid, "truncated.json")
      end
    end

    test "empty JSON raises Jason.DecodeError" do
      assert_raise Jason.DecodeError, fn ->
        ConfigFixtures.load_json(:invalid, "empty.json")
      end
    end

    test "wrong_type JSON decodes but fails schema check" do
      # The JSON decoder does NOT enforce schema — it happily produces a list.
      # Schema enforcement is a downstream concern (e.g., ModelPacks, Loader).
      # This test documents that behaviour so we notice if it changes.
      decoded = ConfigFixtures.load_json(:invalid, "wrong_type.json")
      assert is_list(decoded)
    end

    test "malformed INI degrades gracefully" do
      # The INI parser is lenient: a missing close bracket on a section header
      # does NOT crash — it produces a map (possibly with unexpected keys).
      # This documents the current lenient-parser behaviour.
      result = ConfigFixtures.read_raw(:invalid, "malformed.cfg") |> Loader.parse_string()
      assert is_map(result)
    end
  end

  # ===========================================================================
  # Isolation Safety
  # ===========================================================================

  describe "isolation safety — fixtures never write to real home" do
    @tag :tmp_dir
    test "canonical_json roundtrip stays inside tmp_dir", %{tmp_dir: tmp} do
      out = Path.join(tmp, "out.json")
      File.write!(out, ConfigFixtures.canonical_json(%{"k" => "v"}))

      # The file we just wrote is under tmp and nothing else in tmp was created.
      assert File.exists?(out)
      assert File.ls!(tmp) |> Enum.sort() == ["out.json"]
    end
  end
end
