defmodule CodePuppyControl.TUI.Widgets.ModelSelectorTest do
  @moduledoc """
  Deterministic tests for ModelSelector widget.

  Fully isolates ETS state via snapshot/restore so tests never depend on
  bundled or user-loaded models from priv/models.json. Every test runs
  with ONLY the fixtures defined below, making assertions exact.

  Fixture naming convention:
  - Provider-prefixed (tests prefix stripping):  openai-fixture-*, anthropic-fixture-*, etc.
  - Non-prefixed (tests "no strip" path):       fixture-*-*
  All names include "fixture" to guarantee zero collisions with bundled models.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.TUI.Widgets.ModelSelector

  import ExUnit.CaptureIO

  # ── Test model fixtures ──────────────────────────────────────────────────
  #
  # Provider-prefixed names exercise short_name prefix stripping.
  # "fixture-" names exercise the no-strip path.

  @test_models %{
    # ── Provider-prefixed (short_name strips the prefix) ──
    "openai-fixture-alpha" => %{
      "type" => "openai",
      "name" => "fixture-alpha",
      "context_length" => 128_000
    },
    "anthropic-fixture-beta" => %{
      "type" => "anthropic",
      "name" => "fixture-beta",
      "context_length" => 200_000
    },
    "firepass-fixture-gamma-turbo" => %{
      "type" => "custom_openai",
      "provider" => "firepass",
      "name" => "fixture-gamma-turbo",
      "context_length" => 262_144
    },
    "zai-fixture-delta" => %{
      "type" => "zai_coding",
      "name" => "fixture-delta",
      "context_length" => 32_000
    },
    "firepass-fixture-prefixed" => %{
      "type" => "custom_openai",
      "provider" => "firepass",
      "name" => "fixture-prefixed"
    },
    # ── Non-prefixed (short_name leaves name unchanged) ──
    "fixture-gemini-epsilon" => %{
      "type" => "gemini",
      "name" => "fixture-epsilon",
      "context_length" => 1_048_576
    },
    "fixture-openai-plain" => %{
      "type" => "openai",
      "name" => "fixture-plain",
      "context_length" => 500
    },
    "fixture-openai-minimal" => %{
      "type" => "openai",
      "name" => "fixture-minimal"
    },
    "fixture-cerebras-zeta" => %{
      "type" => "cerebras",
      "name" => "fixture-zeta-8b",
      "context_length" => 131_072
    },
    "fixture-openrouter-eta" => %{
      "type" => "openrouter",
      "name" => "fixture-eta",
      "context_length" => 64_000
    },
    "fixture-azure-theta" => %{
      "type" => "azure_openai",
      "name" => "fixture-theta",
      "context_length" => 8_000
    },
    "fixture-zai_api-iota" => %{
      "type" => "zai_api",
      "name" => "fixture-iota",
      "context_length" => 16_000
    },
    "fixture-openai-alpha2" => %{
      "type" => "openai",
      "name" => "fixture-alpha2",
      "context_length" => 100_000
    },
    "fixture-openai-beta2" => %{
      "type" => "openai",
      "name" => "fixture-beta2"
    },
    "fixture-openai-gamma2" => %{
      "type" => "openai",
      "name" => "fixture-gamma2"
    }
  }

  # Models with unsupported provider types — these will NOT appear in list_models/0
  @unsupported_models %{
    "fixture-unsupported-weird" => %{
      "type" => "unknown_provider",
      "name" => "mystery",
      "context_length" => 999
    }
  }

  @all_fixtures Map.merge(@test_models, @unsupported_models)

  # ── Env var helpers ──────────────────────────────────────────────────────

  @env_keys [
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
    "CEREBRAS_API_KEY",
    "OPENROUTER_API_KEY",
    "AZURE_OPENAI_API_KEY"
  ]

  defp save_env_vars do
    Map.new(@env_keys, fn k -> {k, System.get_env(k)} end)
  end

  defp set_test_env_vars do
    System.put_env("OPENAI_API_KEY", "test-key-for-coverage")
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")
    System.put_env("GEMINI_API_KEY", "test-gemini-key")
    System.put_env("CEREBRAS_API_KEY", "test-cerebras-key")
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")
    System.put_env("AZURE_OPENAI_API_KEY", "test-azure-key")
  end

  defp restore_env_vars(backup) do
    for {key, val} <- backup do
      case val do
        nil -> System.delete_env(key)
        v -> System.put_env(key, v)
      end
    end
  end

  # ── ETS isolation helpers ───────────────────────────────────────────────

  defp with_model_configs(configs, fun) do
    saved = :ets.tab2list(:model_configs)

    try do
      :ets.delete_all_objects(:model_configs)

      for {name, config} <- configs do
        :ets.insert(:model_configs, {name, config})
      end

      fun.()
    after
      :ets.delete_all_objects(:model_configs)

      for {name, config} <- saved do
        :ets.insert(:model_configs, {name, config})
      end
    end
  end

  # ── Setup / Teardown ────────────────────────────────────────────────────

  setup do
    env_backup = save_env_vars()

    # Snapshot entire current ETS registry so we can restore exactly
    registry_backup = :ets.tab2list(:model_configs)

    set_test_env_vars()

    # Clear everything and insert ONLY our fixtures
    :ets.delete_all_objects(:model_configs)

    for {name, config} <- @all_fixtures do
      :ets.insert(:model_configs, {name, config})
    end

    on_exit(fn ->
      restore_env_vars(env_backup)

      # Restore original registry state exactly
      :ets.delete_all_objects(:model_configs)

      for {name, config} <- registry_backup do
        :ets.insert(:model_configs, {name, config})
      end
    end)

    :ok
  end

  # ── list_models/0 — enriched data ───────────────────────────────────────

  describe "list_models/0 with enriched data" do
    test "returns non-empty list when credentials are present" do
      models = ModelSelector.list_models()
      assert is_list(models)
      assert length(models) > 0
    end

    test "each model_info has all required keys" do
      models = ModelSelector.list_models()

      # Our injected models with known providers must appear in the results
      model_names = Enum.map(models, & &1.name)

      for {name, _config} <- @test_models do
        assert name in model_names,
               "injected model #{name} should appear in list_models/0"
      end

      # Models with unsupported provider types must NOT appear
      for {name, _config} <- @unsupported_models do
        refute name in model_names,
               "unsupported model #{name} should NOT appear in list_models/0"
      end

      # Every model entry should have the expected structure
      for model <- models do
        assert Map.has_key?(model, :name)
        assert Map.has_key?(model, :provider_type)
        assert Map.has_key?(model, :provider_module)
        assert Map.has_key?(model, :context_length)
        assert Map.has_key?(model, :display_name)
        assert is_binary(model.name)
        assert is_binary(model.provider_type)
        assert is_atom(model.provider_module)
        assert is_binary(model.display_name)
      end
    end

    test "results are sorted by name" do
      models = ModelSelector.list_models()
      names = Enum.map(models, & &1.name)
      assert names == Enum.sort(names)
    end

    test "provider_module is resolved correctly" do
      models = ModelSelector.list_models()

      for model <- models do
        assert model.provider_module != nil
      end
    end

    test "returns exactly the expected number of supported models" do
      models = ModelSelector.list_models()
      assert length(models) == map_size(@test_models)
    end
  end

  # ── short_name / strip_prefix via display_name ──────────────────────────

  describe "short_name (display_name prefix stripping)" do
    test "strips openai- prefix" do
      models = ModelSelector.list_models()
      openai = Enum.find(models, &(&1.name == "openai-fixture-alpha"))
      assert openai != nil
      assert openai.display_name == "fixture-alpha"
    end

    test "strips anthropic- prefix" do
      models = ModelSelector.list_models()
      anthropic = Enum.find(models, &(&1.name == "anthropic-fixture-beta"))
      assert anthropic != nil
      assert anthropic.display_name == "fixture-beta"
    end

    test "strips firepass- prefix" do
      models = ModelSelector.list_models()
      fp = Enum.find(models, &(&1.name == "firepass-fixture-gamma-turbo"))
      assert fp != nil
      assert fp.display_name == "fixture-gamma-turbo"
    end

    test "strips zai- prefix" do
      models = ModelSelector.list_models()
      zai = Enum.find(models, &(&1.name == "zai-fixture-delta"))
      assert zai != nil
      assert zai.display_name == "fixture-delta"
    end

    test "no provider-prefix match leaves name unchanged" do
      models = ModelSelector.list_models()
      plain = Enum.find(models, &(&1.name == "fixture-openai-plain"))
      assert plain != nil
      # "fixture-" is not a recognized prefix → name stays unchanged
      assert plain.display_name == "fixture-openai-plain"
    end

    test "display_name is never longer than original name" do
      models = ModelSelector.list_models()

      # "firepass-fixture-prefixed" strips the "firepass-" prefix
      firepass_model = Enum.find(models, &(&1.name == "firepass-fixture-prefixed"))
      assert firepass_model.display_name == "fixture-prefixed"

      # display_name should never be longer than the original name
      for model <- models do
        assert byte_size(model.display_name) <= byte_size(model.name)
      end
    end

    test "all models with known prefixes have stripped display_name" do
      models = ModelSelector.list_models()

      prefix_models =
        Enum.filter(models, fn m ->
          String.starts_with?(m.name, "openai-") or
            String.starts_with?(m.name, "anthropic-") or
            String.starts_with?(m.name, "firepass-") or
            String.starts_with?(m.name, "zai-")
        end)

      for model <- prefix_models do
        refute String.starts_with?(model.display_name, "openai-")
        refute String.starts_with?(model.display_name, "anthropic-")
        refute String.starts_with?(model.display_name, "firepass-")
        refute String.starts_with?(model.display_name, "zai-")
      end
    end

    test "zai_api- prefix is not stripped (zai_api- is not a recognized pattern)" do
      models = ModelSelector.list_models()
      zai_api = Enum.find(models, &(&1.name == "fixture-zai_api-iota"))
      assert zai_api != nil
      # "zai_api-" is NOT a stripped prefix (only "zai-" is)
      assert zai_api.display_name == "fixture-zai_api-iota"
    end
  end

  # ── context_length enrichment ──────────────────────────────────────────

  describe "context_length from ModelRegistry" do
    test "populates context_length from string-keyed config" do
      models = ModelSelector.list_models()
      gemini = Enum.find(models, &(&1.name == "fixture-gemini-epsilon"))
      assert gemini != nil
      assert gemini.context_length == 1_048_576
    end

    test "context_length is nil when not in config" do
      models = ModelSelector.list_models()
      minimal = Enum.find(models, &(&1.name == "fixture-openai-minimal"))
      assert minimal != nil
      assert minimal.context_length == nil
    end

    test "context_length is nil or a non-negative integer" do
      models = ModelSelector.list_models()

      alpha = Enum.find(models, &(&1.name == "fixture-openai-alpha2"))
      assert alpha.context_length == 100_000

      beta = Enum.find(models, &(&1.name == "fixture-openai-beta2"))
      assert beta.context_length == nil

      gamma = Enum.find(models, &(&1.name == "fixture-openai-gamma2"))
      assert gamma.context_length == nil

      for model <- models do
        assert model.context_length == nil or
                 (is_integer(model.context_length) and model.context_length >= 0)
      end
    end

    test "small context_length preserved as integer" do
      models = ModelSelector.list_models()
      plain = Enum.find(models, &(&1.name == "fixture-openai-plain"))
      assert plain != nil
      assert plain.context_length == 500
    end

    test "large context_length for gemini" do
      models = ModelSelector.list_models()
      gemini = Enum.find(models, &(&1.name == "fixture-gemini-epsilon"))
      assert gemini != nil
      assert gemini.context_length >= 1_000_000
    end
  end

  # ── maybe_filter edge cases ────────────────────────────────────────────

  describe "list_models/1 filter edge cases" do
    test "nil filter returns all models" do
      with_nil = ModelSelector.list_models(filter: nil)
      without = ModelSelector.list_models()
      assert with_nil == without
    end

    test "empty string filter matches all models" do
      all = ModelSelector.list_models()
      with_empty = ModelSelector.list_models(filter: "")
      assert length(with_empty) == length(all)
    end

    test "filter matches on provider_type (case-insensitive)" do
      models = ModelSelector.list_models(filter: "ANTHROPIC")
      assert length(models) >= 1

      for model <- models do
        assert String.downcase(model.provider_type) =~ "anthropic" or
                 String.downcase(model.name) =~ "anthropic"
      end
    end

    test "filter matches on model name substring" do
      models = ModelSelector.list_models(filter: "fixture-alpha")
      assert length(models) >= 1

      for model <- models do
        assert String.downcase(model.name) =~ "fixture-alpha" or
                 String.downcase(model.provider_type) =~ "fixture-alpha"
      end
    end

    test "filter with no matches returns empty list" do
      models = ModelSelector.list_models(filter: "zzz_no_such_model_xyz_999")
      assert models == []
    end

    test "filter is case-insensitive" do
      lower = ModelSelector.list_models(filter: "openai")
      upper = ModelSelector.list_models(filter: "OPENAI")
      lower_names = Enum.map(lower, & &1.name) |> Enum.sort()
      upper_names = Enum.map(upper, & &1.name) |> Enum.sort()
      assert lower_names == upper_names
    end

    test "filter narrows results" do
      all = ModelSelector.list_models()
      filtered = ModelSelector.list_models(filter: "fixture-alpha")
      assert length(filtered) <= length(all)
    end

    test "filter matches cerebras provider type" do
      assert length(ModelSelector.list_models(filter: "cerebras")) >= 1
    end

    test "filter matches gemini provider type" do
      assert length(ModelSelector.list_models(filter: "gemini")) >= 1
    end

    test "filter matches azure_openai provider type" do
      assert length(ModelSelector.list_models(filter: "azure_openai")) >= 1
    end

    test "filter matches openrouter provider type" do
      assert length(ModelSelector.list_models(filter: "openrouter")) >= 1
    end

    test "filter matches zai_coding provider type" do
      assert length(ModelSelector.list_models(filter: "zai_coding")) >= 1
    end

    test "filter matches custom_openai provider type" do
      assert length(ModelSelector.list_models(filter: "custom_openai")) >= 1
    end

    test "filter on exact model name returns that model" do
      models = ModelSelector.list_models(filter: "openai-fixture-alpha")
      assert length(models) >= 1
      assert Enum.any?(models, &(&1.name == "openai-fixture-alpha"))
    end
  end

  # ── select/1 — no models ───────────────────────────────────────────────

  describe "select/1 with no models" do
    test "handles empty model list" do
      with_model_configs(%{}, fn ->
        assert ModelSelector.list_models() == []
      end)
    end

    test "returns :cancelled when model list is empty" do
      with_model_configs(%{}, fn ->
        output =
          capture_io(fn ->
            result = ModelSelector.select()
            assert result == :cancelled
          end)

        assert output =~ "No models available"
      end)
    end

    test "select with label returns :cancelled when no models" do
      with_model_configs(%{}, fn ->
        output =
          capture_io(fn ->
            result = ModelSelector.select(label: "Custom prompt")
            assert result == :cancelled
          end)

        assert output =~ "No models available"
      end)
    end

    test "select with default returns :cancelled when no models available" do
      with_model_configs(%{}, fn ->
        output =
          capture_io(fn ->
            result = ModelSelector.select(default: "some-model")
            assert result == :cancelled
          end)

        assert output =~ "No models available"
      end)
    end

    test "select with filter returns :cancelled when no models match" do
      output =
        capture_io(fn ->
          result = ModelSelector.select(filter: "zzz_no_match_xyz")
          assert result == :cancelled
        end)

      assert output =~ "No models available"
    end
  end

  # ── select/1 — with models (render + interactive) ──────────────────────

  describe "select/1 with models — render path" do
    test "renders model table and returns :cancelled on blank input" do
      output =
        capture_io([input: "\n"], fn ->
          result = ModelSelector.select(label: "Pick one")
          assert result == :cancelled
        end)

      assert output =~ "Model Selector"
    end

    test "renders default model indicator when default matches a model" do
      output =
        capture_io([input: "\n"], fn ->
          result = ModelSelector.select(default: "openai-fixture-alpha")
          assert result == :cancelled
        end)

      assert output =~ "Default"
    end

    test "no default indicator when default doesn't match any model" do
      output =
        capture_io([input: "\n"], fn ->
          result = ModelSelector.select(default: "nonexistent-model")
          assert result == :cancelled
        end)

      refute output =~ "Default"
    end

    test "select with filter option narrows displayed models" do
      output =
        capture_io([input: "\n"], fn ->
          result = ModelSelector.select(filter: "fixture-alpha", label: "Filtered")
          assert result == :cancelled
        end)

      assert output =~ "Model Selector"
    end

    test "select with custom label shows that label" do
      output =
        capture_io([input: "\n"], fn ->
          result = ModelSelector.select(label: "Choose your weapon")
          assert result == :cancelled
        end)

      assert output =~ "Choose your weapon"
    end

    test "select with all options combined" do
      output =
        capture_io([input: "\n"], fn ->
          result =
            ModelSelector.select(
              filter: "openai",
              default: "openai-fixture-alpha",
              label: "Select OpenAI model"
            )

          assert result == :cancelled
        end)

      assert output =~ "Model Selector"
    end
  end

  # ── select/1 — interactive selection ────────────────────────────────────

  describe "select/1 — interactive selection" do
    test "returns {:ok, model_name} on exact name input" do
      output =
        capture_io([input: "openai-fixture-alpha\n"], fn ->
          result = ModelSelector.select()
          assert {:ok, "openai-fixture-alpha"} = result
        end)

      _ = output
    end

    test "returns model when user enters valid number" do
      models = ModelSelector.list_models()
      first = hd(models).name

      output =
        capture_io([input: "1\n"], fn ->
          result = ModelSelector.select()
          assert {:ok, ^first} = result
        end)

      _ = output
    end

    test "returns :cancelled on blank input" do
      output =
        capture_io([input: "\n"], fn ->
          result = ModelSelector.select()
          assert result == :cancelled
        end)

      _ = output
    end

    test "returns :cancelled on out-of-range number" do
      output =
        capture_io([input: "9999\n"], fn ->
          result = ModelSelector.select()
          assert result == :cancelled
        end)

      _ = output
    end

    test "returns :cancelled on non-matching string" do
      output =
        capture_io([input: "xyzzy-no-match\n"], fn ->
          result = ModelSelector.select()
          assert result == :cancelled
        end)

      _ = output
    end

    test "fuzzy match on partial model name" do
      output =
        capture_io([input: "fixture-alpha\n"], fn ->
          result = ModelSelector.select()
          # "fixture-alpha" should fuzzy-match "openai-fixture-alpha"
          assert {:ok, _} = result
        end)

      _ = output
    end

    test "fuzzy match on fixture-beta substring" do
      output =
        capture_io([input: "fixture-beta\n"], fn ->
          result = ModelSelector.select()
          # "fixture-beta" should fuzzy-match "anthropic-fixture-beta"
          assert {:ok, _} = result
        end)

      _ = output
    end

    test "numeric selection: last model by number" do
      models = ModelSelector.list_models()
      count = length(models)
      last = Enum.at(models, count - 1).name

      output =
        capture_io([input: "#{count}\n"], fn ->
          result = ModelSelector.select()
          assert {:ok, ^last} = result
        end)

      _ = output
    end
  end

  # ── format_context_length via rendered output ────────────────────────

  describe "format_context_length via rendered output" do
    test "large context (>=1M) renders as 'M'" do
      output =
        capture_io([input: "\n"], fn ->
          ModelSelector.select()
        end)

      # fixture-gemini-epsilon has context_length 1_048_576 → "1M"
      assert output =~ "1M"
    end

    test "mid-range context (>=1k) renders as 'k'" do
      output =
        capture_io([input: "\n"], fn ->
          ModelSelector.select()
        end)

      assert output =~ "k"
    end

    test "nil context renders as dash" do
      output =
        capture_io([input: "\n"], fn ->
          ModelSelector.select()
        end)

      # fixture-openai-minimal has nil context → renders as "—"
      assert output =~ "—"
    end
  end

  # ── provider_bg coverage ────────────────────────────────────────────────

  describe "provider background colors via rendered output" do
    test "renders models from multiple providers" do
      output =
        capture_io([input: "\n"], fn ->
          ModelSelector.select()
        end)

      assert output =~ "Model Selector"
    end

    test "default model highlighted with star marker" do
      output =
        capture_io([input: "\n"], fn ->
          ModelSelector.select(default: "openai-fixture-alpha")
        end)

      assert output =~ "★"
    end
  end

  # ── Regression — original test suite ────────────────────────────────────

  describe "regression — original test suite" do
    test "returns a list of model_info maps" do
      models = ModelSelector.list_models()
      assert is_list(models)

      for model <- models do
        assert is_binary(model.name)
        assert is_binary(model.provider_type)
        assert is_atom(model.provider_module)
        assert is_binary(model.display_name)
      end
    end

    test "results are sorted by name" do
      models = ModelSelector.list_models()
      names = Enum.map(models, & &1.name)
      assert names == Enum.sort(names)
    end

    test "filter with no matches returns empty list" do
      models = ModelSelector.list_models(filter: "zzz_no_such_model_xyz_999")
      assert models == []
    end
  end
end
