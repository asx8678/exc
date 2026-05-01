defmodule CodePuppyControl.TUI.Widgets.ModelSelectorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.TUI.Widgets.ModelSelector

  @test_models [
    {"alpha-test-model",
     %{"type" => "claude_code", "name" => "alpha-test-model", "context_length" => 100_000}},
    {"anthropic-claude-sonnet-4",
     %{
       "type" => "claude_code",
       "name" => "anthropic-claude-sonnet-4",
       "context_length" => 200_000
     }},
    {"beta-test-model",
     %{"type" => "claude_code", "name" => "beta-test-model", "context_length" => nil}},
    {"firepass-prefixed-model",
     %{"type" => "claude_code", "name" => "firepass-prefixed-model", "context_length" => 50_000}},
    {"gamma-test-model",
     %{"type" => "claude_code", "name" => "gamma-test-model", "context_length" => nil}}
  ]

  setup do
    # Inject deterministic test models into the shared ETS table so that
    # ModelFactory.list_available/0 and ModelRegistry.get_config/1 find them.
    # We use the "claude_code" provider type because Credentials.validate/2
    # always returns :ok for OAuth types — no env vars required.
    Enum.each(@test_models, fn {name, config} ->
      :ets.insert(:model_configs, {name, config})
    end)

    on_exit(fn ->
      Enum.each(@test_models, fn {name, _config} ->
        :ets.delete(:model_configs, name)
      end)
    end)

    :ok
  end

  describe "list_models/1" do
    test "returns a list of model_info maps with required keys" do
      models = ModelSelector.list_models()

      assert is_list(models)

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

    test "filter narrows results by name substring (case-insensitive)" do
      # "alpha" should match "alpha-test-model" by name
      filtered = ModelSelector.list_models(filter: "alpha")

      assert is_list(filtered)
      assert length(filtered) >= 1

      for model <- filtered do
        assert String.downcase(model.name) =~ "alpha" or
                 String.downcase(model.provider_type) =~ "alpha"
      end

      # Filtered results should be a subset of all models
      all = ModelSelector.list_models()
      filtered_names = MapSet.new(Enum.map(filtered, & &1.name))
      all_names = MapSet.new(Enum.map(all, & &1.name))
      assert MapSet.subset?(filtered_names, all_names)
    end

    test "filter with no matches returns empty list" do
      models = ModelSelector.list_models(filter: "zzz_no_such_model_xyz_999")
      assert models == []
    end

    test "filter is case-insensitive" do
      lower = ModelSelector.list_models(filter: "alpha")
      upper = ModelSelector.list_models(filter: "ALPHA")
      mixed = ModelSelector.list_models(filter: "AlPhA")

      assert length(lower) >= 1
      assert length(lower) == length(upper)
      assert length(lower) == length(mixed)
    end
  end

  describe "model_info structure" do
    test "display_name strips common provider prefixes" do
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
  end
end
