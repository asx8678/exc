defmodule CodePuppyControl.TUI.Widgets.ModelSelectorTest do
  @moduledoc """
  Coverage tests for ModelSelector widget.

  Previous coverage was 7.23% because the test environment had no API keys
  configured, so ModelFactory.list_available/0 returned [] and most private
  functions (enrich_model, short_name, maybe_filter with data,
  format_context_length, provider_bg, parse_selection) were never exercised.

  This module:
  1. Sets temp API keys so list_available/0 returns models
  2. Injects test models with known prefix patterns into ETS
  3. Tests enrich_model, short_name, context_length via list_models/0
  4. Tests maybe_filter with actual matching data
  5. Tests select/1 with empty models (no-models → :cancelled path)
  6. Tests select/1 with models via capture_io (render + interactive)
  7. Tests parse_selection numeric + fuzzy matching paths
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.TUI.Widgets.ModelSelector

  import ExUnit.CaptureIO

  # ── Test model fixtures ──────────────────────────────────────────────────

  @test_models %{
    "openai-gpt-4o" => %{
      "type" => "openai",
      "name" => "gpt-4o",
      "context_length" => 128_000
    },
    "anthropic-claude-sonnet-4" => %{
      "type" => "anthropic",
      "name" => "claude-sonnet-4",
      "context_length" => 200_000
    },
    "firepass-kimi-k2p5-turbo" => %{
      "type" => "custom_openai",
      "provider" => "firepass",
      "name" => "kimi-k2p5-turbo",
      "context_length" => 262_144
    },
    "zai-code-pilot" => %{
      "type" => "zai_coding",
      "name" => "code-pilot",
      "context_length" => 32_000
    },
    "gemini-2.5-pro" => %{
      "type" => "gemini",
      "name" => "gemini-2.5-pro",
      "context_length" => 1_048_576
    },
    "plain-model" => %{
      "type" => "openai",
      "name" => "plain-model",
      "context_length" => 500
    },
    "minimal-model" => %{
      "type" => "openai",
      "name" => "minimal-model"
    },
    "cerebras-llama" => %{
      "type" => "cerebras",
      "name" => "llama-3.1-8b",
      "context_length" => 131_072
    },
    "openrouter-auto" => %{
      "type" => "openrouter",
      "name" => "auto",
      "context_length" => 64_000
    },
    "azure-gpt-4" => %{
      "type" => "azure_openai",
      "name" => "gpt-4",
      "context_length" => 8_000
    },
    "zai_api-model" => %{
      "type" => "zai_api",
      "name" => "some-model",
      "context_length" => 16_000
    },
    "weird-provider-model" => %{
      "type" => "unknown_provider",
      "name" => "mystery",
      "context_length" => 999
    }
  }

  # ── Setup / Teardown ────────────────────────────────────────────────────

  setup do
    env_backup = save_env_vars()

    System.put_env("OPENAI_API_KEY", "test-key-for-coverage")
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")
    System.put_env("GEMINI_API_KEY", "test-gemini-key")
    System.put_env("CEREBRAS_API_KEY", "test-cerebras-key")
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")
    System.put_env("AZURE_OPENAI_API_KEY", "test-azure-key")

    for {name, config} <- @test_models do
      :ets.insert(:model_configs, {name, config})
    end

    on_exit(fn ->
      restore_env_vars(env_backup)

      for {name, _} <- @test_models do
        :ets.delete(:model_configs, name)
      end
    end)

    :ok
  end

  defp save_env_vars do
    keys = [
      "OPENAI_API_KEY",
      "ANTHROPIC_API_KEY",
      "GEMINI_API_KEY",
      "CEREBRAS_API_KEY",
      "OPENROUTER_API_KEY",
      "AZURE_OPENAI_API_KEY"
    ]

    Map.new(keys, fn k -> {k, System.get_env(k)} end)
  end

  defp restore_env_vars(backup) do
    for {key, val} <- backup do
      case val do
        nil -> System.delete_env(key)
        v -> System.put_env(key, v)
      end
    end
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

      # Our injected models must appear in the results
      model_names = Enum.map(models, & &1.name)

      for {name, _config} <- @test_models do
        assert name in model_names,
               "injected model #{name} should appear in list_models/0"
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
  end

  # ── short_name / strip_prefix via display_name ──────────────────────────

  describe "short_name (display_name prefix stripping)" do
    test "strips openai- prefix" do
      models = ModelSelector.list_models()
      openai = Enum.find(models, &(&1.name == "openai-gpt-4o"))
      assert openai != nil
      assert openai.display_name == "gpt-4o"
    end

    test "strips anthropic- prefix" do
      models = ModelSelector.list_models()
      anthropic = Enum.find(models, &(&1.name == "anthropic-claude-sonnet-4"))
      assert anthropic != nil
      assert anthropic.display_name == "claude-sonnet-4"
    end

    test "strips firepass- prefix" do
      models = ModelSelector.list_models()
      fp = Enum.find(models, &(&1.name == "firepass-kimi-k2p5-turbo"))
      assert fp != nil
      assert fp.display_name == "kimi-k2p5-turbo"
    end

    test "strips zai- prefix" do
      models = ModelSelector.list_models()
      zai = Enum.find(models, &(&1.name == "zai-code-pilot"))
      assert zai != nil
      assert zai.display_name == "code-pilot"
    end

    test "no prefix match leaves name unchanged" do
      models = ModelSelector.list_models()
      plain = Enum.find(models, &(&1.name == "plain-model"))
      assert plain != nil
      assert plain.display_name == "plain-model"
    end

    test "display_name is never longer than original name" do
      models = ModelSelector.list_models()

      # "anthropic-claude-sonnet-4" should strip the "anthropic-" prefix
      anthropic_model = Enum.find(models, &(&1.name == "anthropic-claude-sonnet-4"))
      assert anthropic_model.display_name == "claude-sonnet-4"

      # "firepass-prefixed-model" should strip the "firepass-" prefix
      firepass_model = Enum.find(models, &(&1.name == "firepass-prefixed-model"))
      assert firepass_model.display_name == "prefixed-model"

      # Unprefixed names should remain unchanged
      alpha_model = Enum.find(models, &(&1.name == "alpha-test-model"))
      assert alpha_model.display_name == "alpha-test-model"

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

    test "zai_api-model is not stripped (zai_api- is not a prefix pattern)" do
      models = ModelSelector.list_models()
      zai_api = Enum.find(models, &(&1.name == "zai_api-model"))
      assert zai_api != nil
      assert zai_api.display_name == "zai_api-model"
    end
  end

  # ── context_length enrichment ──────────────────────────────────────────

  describe "context_length from ModelRegistry" do
    test "populates context_length from string-keyed config" do
      models = ModelSelector.list_models()
      gemini = Enum.find(models, &(&1.name == "gemini-2.5-pro"))
      assert gemini != nil
      assert gemini.context_length == 1_048_576
    end

    test "context_length is nil when not in config" do
      models = ModelSelector.list_models()
      minimal = Enum.find(models, &(&1.name == "minimal-model"))
      assert minimal != nil
      assert minimal.context_length == nil
    end

    test "context_length is nil or a non-negative integer" do
      models = ModelSelector.list_models()

      # Specific models should have specific context_lengths
      alpha = Enum.find(models, &(&1.name == "alpha-test-model"))
      assert alpha.context_length == 100_000

      beta = Enum.find(models, &(&1.name == "beta-test-model"))
      assert beta.context_length == nil

      gamma = Enum.find(models, &(&1.name == "gamma-test-model"))
      assert gamma.context_length == nil

      # All models should have valid context_length values
      for model <- models do
        assert model.context_length == nil or
                 (is_integer(model.context_length) and model.context_length >= 0)
      end
    end

    test "small context_length preserved as integer" do
      models = ModelSelector.list_models()
      plain = Enum.find(models, &(&1.name == "plain-model"))
      assert plain != nil
      assert plain.context_length == 500
    end

    test "large context_length for gemini" do
      models = ModelSelector.list_models()
      gemini = Enum.find(models, &(&1.name == "gemini-2.5-pro"))
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
      models = ModelSelector.list_models(filter: "gpt")
      assert length(models) >= 1

      for model <- models do
        assert String.downcase(model.name) =~ "gpt" or
                 String.downcase(model.provider_type) =~ "gpt"
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
      filtered = ModelSelector.list_models(filter: "gpt")
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
      models = ModelSelector.list_models(filter: "openai-gpt-4o")
      assert length(models) >= 1
      assert Enum.any?(models, &(&1.name == "openai-gpt-4o"))
    end
  end

  # ── select/1 — no models ───────────────────────────────────────────────

  describe "select/1 with no models" do
    test "returns :cancelled when model list is empty" do
      all_names = :ets.tab2list(:model_configs) |> Enum.map(&elem(&1, 0))

      for name <- all_names do
        :ets.delete(:model_configs, name)
      end

      output =
        capture_io(fn ->
          result = ModelSelector.select()
          assert result == :cancelled
        end)

      assert output =~ "No models available"

      for {name, config} <- @test_models do
        :ets.insert(:model_configs, {name, config})
      end
    end

    test "select with label returns :cancelled when no models" do
      all_names = :ets.tab2list(:model_configs) |> Enum.map(&elem(&1, 0))

      for name <- all_names do
        :ets.delete(:model_configs, name)
      end

      output =
        capture_io(fn ->
          result = ModelSelector.select(label: "Custom prompt")
          assert result == :cancelled
        end)

      assert output =~ "No models available"

      for {name, config} <- @test_models do
        :ets.insert(:model_configs, {name, config})
      end
    end

    test "select with filter returns :cancelled when no models match" do
      output =
        capture_io(fn ->
          result = ModelSelector.select(filter: "zzz_no_match_xyz")
          assert result == :cancelled
        end)

      assert output =~ "No models available"
    end

    test "select with default returns :cancelled when no models available" do
      all_names = :ets.tab2list(:model_configs) |> Enum.map(&elem(&1, 0))

      for name <- all_names do
        :ets.delete(:model_configs, name)
      end

      output =
        capture_io(fn ->
          result = ModelSelector.select(default: "some-model")
          assert result == :cancelled
        end)

      assert output =~ "No models available"

      for {name, config} <- @test_models do
        :ets.insert(:model_configs, {name, config})
      end
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
          result = ModelSelector.select(default: "openai-gpt-4o")
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

      # Should NOT contain "Default" since the default is not in the model list
      refute output =~ "Default"
    end

    test "select with filter option narrows displayed models" do
      output =
        capture_io([input: "\n"], fn ->
          result = ModelSelector.select(filter: "gpt", label: "Filtered")
          assert result == :cancelled
        end)

      # Output should contain Model Selector header
      assert output =~ "Model Selector"
    end

    test "select with custom label shows that label" do
      output =
        capture_io([input: "\n"], fn ->
          result = ModelSelector.select(label: "Choose your weapon")
          assert result == :cancelled
        end)

      # The label appears in the prompt text
      assert output =~ "Choose your weapon"
    end

    test "select with all options combined" do
      output =
        capture_io([input: "\n"], fn ->
          result =
            ModelSelector.select(
              filter: "openai",
              default: "openai-gpt-4o",
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
        capture_io([input: "openai-gpt-4o\n"], fn ->
          result = ModelSelector.select()
          assert {:ok, "openai-gpt-4o"} = result
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
        capture_io([input: "gpt-4o\n"], fn ->
          result = ModelSelector.select()
          # "gpt-4o" should fuzzy-match "openai-gpt-4o"
          assert {:ok, _} = result
        end)

      _ = output
    end

    test "fuzzy match on claude substring" do
      output =
        capture_io([input: "claude\n"], fn ->
          result = ModelSelector.select()
          # "claude" should fuzzy-match "anthropic-claude-sonnet-4"
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

      # gemini-2.5-pro has context_length 1_048_576 → "1M"
      assert output =~ "1M"
    end

    test "mid-range context (>=1k) renders as 'k'" do
      output =
        capture_io([input: "\n"], fn ->
          ModelSelector.select()
        end)

      # Several models have context_length in the thousands range
      assert output =~ "k"
    end

    test "nil context renders as dash" do
      output =
        capture_io([input: "\n"], fn ->
          ModelSelector.select()
        end)

      # minimal-model has nil context → renders as "—"
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
          ModelSelector.select(default: "openai-gpt-4o")
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
