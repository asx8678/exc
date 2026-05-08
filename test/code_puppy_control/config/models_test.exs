defmodule CodePuppyControl.Config.ModelsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Loader, Models, Writer}

  @tmp_dir System.tmp_dir!()
  @test_cfg Path.join(@tmp_dir, "models_test_#{:erlang.unique_integer([:positive])}.cfg")
  @empty_models_json Path.join(
                       @tmp_dir,
                       "empty_models_#{:erlang.unique_integer([:positive])}.json"
                     )

  setup do
    File.write!(@test_cfg, "[puppy]\nmodel = test-model\n")
    Loader.load(@test_cfg)

    # Ensure ModelRegistry is alive under its supervisor before any test.
    # We never stop the supervised registry — that destroys the :model_configs
    # ETS table and causes nondeterministic failures in later tests.
    ensure_registry_alive()

    on_exit(fn ->
      File.rm(@test_cfg)

      # Always restore registry env + reload so :model_configs is available
      # for subsequent tests (e.g. factory_test).
      restore_registry_env()
      Loader.invalidate()
    end)

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Point registry at an empty JSON so list_model_names() returns [].
  # This tests the same "no models available" code path as stopping
  # the GenServer, but deterministically and without destroying ETS.
  #
  # We must also override PUP_EX_HOME so that data_dir() (used by
  # Paths.extra_models_file etc.) resolves to a temp directory with
  # no overlay model files. AND we must redirect the legacy home dir
  # (~/.code_puppy) so that legacy overlay files (chatgpt_models.json,
  # claude_models.json, etc.) are not loaded either. Otherwise, real
  # overlay files still contribute models after reload.
  defp with_empty_registry(fun) do
    File.write!(@empty_models_json, "{}")
    original_models_env = System.get_env("PUP_BUNDLED_MODELS_PATH")
    original_home_env = System.get_env("PUP_EX_HOME")
    original_legacy_home = Application.get_env(:code_puppy_control, :legacy_home_dir)

    empty_data_dir = Path.join(@tmp_dir, "empty_data_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(empty_data_dir)

    System.put_env("PUP_BUNDLED_MODELS_PATH", @empty_models_json)
    System.put_env("PUP_EX_HOME", empty_data_dir)
    Application.put_env(:code_puppy_control, :legacy_home_dir, empty_data_dir)

    try do
      :ok = CodePuppyControl.ModelRegistry.reload()
      fun.()
    after
      # Restore env vars (saved for on_exit too, but restore immediately
      # so subsequent tests in this module see the real models).
      if original_models_env do
        System.put_env("PUP_BUNDLED_MODELS_PATH", original_models_env)
      else
        System.delete_env("PUP_BUNDLED_MODELS_PATH")
      end

      if original_home_env do
        System.put_env("PUP_EX_HOME", original_home_env)
      else
        System.delete_env("PUP_EX_HOME")
      end

      if original_legacy_home do
        Application.put_env(:code_puppy_control, :legacy_home_dir, original_legacy_home)
      else
        Application.delete_env(:code_puppy_control, :legacy_home_dir)
      end

      :ok = CodePuppyControl.ModelRegistry.reload()
      File.rm(@empty_models_json)
      File.rm_rf(empty_data_dir)
    end
  end

  # Ensure the supervised ModelRegistry is alive; never stop it.
  defp ensure_registry_alive do
    case Process.whereis(CodePuppyControl.ModelRegistry) do
      nil ->
        # Supervisor should restart it, but give a moment
        Process.sleep(50)

        case Process.whereis(CodePuppyControl.ModelRegistry) do
          nil ->
            # Last resort: reload to re-populate ETS if GenServer came back
            # but ETS was lost. Should not normally happen.
            try do
              CodePuppyControl.ModelRegistry.reload()
            catch
              :exit, _ -> :ok
            end

          _pid ->
            :ok
        end

      _pid ->
        :ok
    end
  end

  # Idempotent env restore used by on_exit.
  defp restore_registry_env do
    System.delete_env("PUP_BUNDLED_MODELS_PATH")
    System.delete_env("PUP_EX_HOME")
    Application.delete_env(:code_puppy_control, :legacy_home_dir)

    try do
      CodePuppyControl.ModelRegistry.reload()
    catch
      :exit, _ -> :ok
    end
  end

  defp ensure_writer_started do
    case Writer.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  # ── global_model_name/0 ─────────────────────────────────────────────────

  describe "global_model_name/0" do
    test "returns configured model" do
      assert Models.global_model_name() == "test-model"
    end

    test "falls back to default when not set" do
      File.write!(@test_cfg, "[puppy]\n")
      Loader.load(@test_cfg)

      assert Models.global_model_name() == Models.default_model()
    end

    test "puppy.cfg model wins over registry model" do
      # Even if registry is running, explicit config should win
      assert Models.global_model_name() == "test-model"
    end
  end

  # ── default_model/0 ─────────────────────────────────────────────────────

  describe "default_model/0" do
    test "returns gpt-5 when registry has no models (empty JSON)" do
      # Instead of stopping the supervised GenServer (which destroys
      # :model_configs ETS and races with the supervisor), we point
      # the registry at an empty JSON and reload. This exercises the
      # same nil → "gpt-5" fallback path deterministically.
      with_empty_registry(fn ->
        assert Models.default_model() == "gpt-5"
      end)
    end

    test "returns first model from ModelRegistry when available" do
      ensure_registry_alive()

      model = Models.default_model()
      assert is_binary(model)
      assert model != ""

      names = CodePuppyControl.ModelRegistry.list_model_names()

      if names != [] do
        assert model == List.first(names)
      end
    end
  end

  # ── first_registry_model/0 ──────────────────────────────────────────────

  describe "first_registry_model/0" do
    test "returns nil when registry has no models (empty JSON)" do
      # Deterministic empty-registry test — no GenServer stopping.
      with_empty_registry(fn ->
        assert Models.first_registry_model() == nil
      end)
    end

    test "returns first model name when registry is populated" do
      ensure_registry_alive()

      names = CodePuppyControl.ModelRegistry.list_model_names()

      if names != [] do
        assert Models.first_registry_model() == List.first(names)
      else
        assert Models.first_registry_model() == nil
      end
    end
  end

  # ── set_global_model/1 ──────────────────────────────────────────────────

  describe "set_global_model/1" do
    test "persists model to config" do
      ensure_writer_started()
      Models.set_global_model("claude-sonnet")

      Loader.load(@test_cfg)
      assert Models.global_model_name() == "claude-sonnet"
    end
  end

  # ── temperature/0 ───────────────────────────────────────────────────────

  describe "temperature/0" do
    test "returns nil when not set" do
      assert Models.temperature() == nil
    end

    test "parses float temperature" do
      File.write!(@test_cfg, "[puppy]\ntemperature = 0.7\n")
      Loader.load(@test_cfg)

      assert Models.temperature() == 0.7
    end

    test "clamps to 0-2 range" do
      File.write!(@test_cfg, "[puppy]\ntemperature = 5.0\n")
      Loader.load(@test_cfg)

      assert Models.temperature() == 2.0
    end
  end

  # ── set_temperature/1 ───────────────────────────────────────────────────

  describe "set_temperature/1" do
    test "sets and clears temperature" do
      ensure_writer_started()

      Models.set_temperature(1.5)
      Loader.load(@test_cfg)
      assert Models.temperature() == 1.5

      Models.set_temperature(nil)
      Loader.load(@test_cfg)
      assert Models.temperature() == nil
    end
  end

  # ── agent_pinned_model/1 ────────────────────────────────────────────────

  describe "agent_pinned_model/1" do
    test "returns nil for unpinned agent" do
      assert Models.agent_pinned_model("my-agent") == nil
    end

    test "returns pinned model" do
      File.write!(@test_cfg, "[puppy]\nagent_model_my-agent = gpt-5\n")
      Loader.load(@test_cfg)

      assert Models.agent_pinned_model("my-agent") == "gpt-5"
    end
  end

  # ── set_agent_pinned_model/2 and clear/1 ─────────────────────────────────

  describe "set_agent_pinned_model/2 and clear/1" do
    test "pins and clears agent model" do
      ensure_writer_started()

      Models.set_agent_pinned_model("agent1", "gpt-5")
      Loader.load(@test_cfg)
      assert Models.agent_pinned_model("agent1") == "gpt-5"

      Models.clear_agent_pinned_model("agent1")
      Loader.load(@test_cfg)
      assert Models.agent_pinned_model("agent1") == nil
    end
  end

  # ── all_agent_pinned_models/0 ────────────────────────────────────────────

  describe "all_agent_pinned_models/0" do
    test "returns map of all pinnings" do
      File.write!(@test_cfg, "[puppy]\nagent_model_a = m1\nagent_model_b = m2\nother = val\n")
      Loader.load(@test_cfg)

      result = Models.all_agent_pinned_models()
      assert result == %{"a" => "m1", "b" => "m2"}
    end
  end

  # ── openai_reasoning_effort/0 ────────────────────────────────────────────

  describe "openai_reasoning_effort/0" do
    test "defaults to medium" do
      assert Models.openai_reasoning_effort() == "medium"
    end

    test "returns configured value" do
      File.write!(@test_cfg, "[puppy]\nopenai_reasoning_effort = high\n")
      Loader.load(@test_cfg)

      assert Models.openai_reasoning_effort() == "high"
    end
  end

  # ── set_openai_reasoning_effort/1 ────────────────────────────────────────

  describe "set_openai_reasoning_effort/1" do
    test "validates input" do
      ensure_writer_started()

      assert {:error, _} = Models.set_openai_reasoning_effort("invalid")
      assert :ok = Models.set_openai_reasoning_effort("low")
    end
  end

  # ── openai_verbosity/0 ───────────────────────────────────────────────────

  describe "openai_verbosity/0" do
    test "defaults to medium" do
      assert Models.openai_verbosity() == "medium"
    end
  end

  # ── get_model_setting/2 ─────────────────────────────────────────────────

  describe "get_model_setting/2" do
    test "returns nil for unset setting" do
      assert Models.get_model_setting("gpt-5", "temperature") == nil
    end

    test "returns parsed value" do
      File.write!(@test_cfg, "[puppy]\nmodel_settings_gpt_5_temperature = 0.8\n")
      Loader.load(@test_cfg)

      assert Models.get_model_setting("gpt-5", "temperature") == 0.8
    end
  end

  # ── get_all_model_settings/1 ────────────────────────────────────────────

  describe "get_all_model_settings/1" do
    test "returns all settings for a model" do
      File.write!(@test_cfg, """
      [puppy]
      model_settings_gpt_5_temperature = 0.8
      model_settings_gpt_5_seed = 42
      other_key = not_this
      """)

      Loader.load(@test_cfg)

      result = Models.get_all_model_settings("gpt-5")
      assert result["temperature"] == 0.8
      assert result["seed"] == 42
      refute Map.has_key?(result, "other_key")
    end
  end
end
