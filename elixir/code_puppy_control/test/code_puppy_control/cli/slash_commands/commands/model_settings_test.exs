defmodule CodePuppyControl.CLI.SlashCommands.Commands.ModelSettingsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.ModelSettings
  alias ModelSettings.Interactive

  # async: false because Registry is a named singleton.

  setup do
    # Start the Registry GenServer if not already running
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()

    # Register /model_settings and /ms
    :ok =
      Registry.register(
        CommandInfo.new(
          name: "model_settings",
          description: "Configure per-model settings",
          handler: &ModelSettings.handle_model_settings/2,
          usage: "/model_settings [--show] [model_name]",
          aliases: ["ms"],
          category: "config"
        )
      )

    state = %{session_id: "test-session", running: true}
    {:ok, state: state}
  end

  # ── Registration & Dispatch ──────────────────────────────────────────────

  describe "registration" do
    test "/model_settings is registered and dispatchable" do
      assert {:ok, cmd} = Registry.get("model_settings")
      assert cmd.name == "model_settings"
    end

    test "/ms alias resolves to model_settings" do
      assert {:ok, cmd} = Registry.get("ms")
      assert cmd.name == "model_settings"
    end

    test "dispatching /model_settings --show returns continue" do
      assert {:ok, {:continue, _}} = Dispatcher.dispatch("/model_settings --show", nil)
    end

    test "dispatching /ms --show returns continue" do
      assert {:ok, {:continue, _}} = Dispatcher.dispatch("/ms --show", nil)
    end
  end

  # ── Pure formatting (config-isolated) ────────────────────────────────────

  describe "format_summary/2 — pure function" do
    test "shows 'no custom settings' when settings map is empty" do
      output = ModelSettings.format_summary("gpt-5", %{})
      assert output =~ "No custom settings configured"
      assert output =~ "gpt-5"
      assert output =~ "using model defaults"
    end

    test "shows settings header when settings present" do
      output = ModelSettings.format_summary("claude-opus-4", %{"temperature" => 0.7})
      assert output =~ "Settings for claude-opus-4"
      assert output =~ "Temperature"
      assert output =~ "0.70"
    end

    test "shows multiple settings sorted by key" do
      settings = %{
        "seed" => 42,
        "temperature" => 0.5,
        "top_p" => 0.9
      }

      output = ModelSettings.format_summary("test-model", settings)

      assert output =~ "Temperature"
      assert output =~ "Seed"
      assert output =~ "Top-P"
    end

    test "handles nil setting value without crashing" do
      output = ModelSettings.format_summary("test-model", %{"temperature" => nil})
      assert output =~ "Temperature"
      assert output =~ "not set"
    end

    test "handles blank string setting value without crashing" do
      output = ModelSettings.format_summary("test-model", %{"seed" => ""})
      assert output =~ "Seed"
      assert output =~ "not set"
    end

    test "shows boolean settings as Enabled/Disabled" do
      output =
        ModelSettings.format_summary("test-model", %{
          "interleaved_thinking" => true,
          "clear_thinking" => false
        })

      assert output =~ "Interleaved Thinking"
      assert output =~ "Enabled"
      assert output =~ "Clear Thinking"
      assert output =~ "Disabled"
    end

    test "shows choice settings as string values" do
      output =
        ModelSettings.format_summary("test-model", %{
          "reasoning_effort" => "high",
          "verbosity" => "low"
        })

      assert output =~ "Reasoning Effort"
      assert output =~ "high"
      assert output =~ "Verbosity"
      assert output =~ "low"
    end

    test "handles model names with special characters" do
      output = ModelSettings.format_summary("gpt-4.1-mini", %{})
      assert output =~ "gpt-4.1-mini"
    end

    test "shows OpenAI global controls when included in settings" do
      output =
        ModelSettings.format_summary("test-openai-model", %{
          "reasoning_effort" => "medium",
          "summary" => "auto",
          "verbosity" => "high"
        })

      assert output =~ "Reasoning Effort"
      assert output =~ "medium"
      assert output =~ "Reasoning Summary"
      assert output =~ "auto"
      assert output =~ "Verbosity"
      assert output =~ "high"
    end
  end

  # ── /model_settings --show (IO integration, no config mutation) ─────────

  describe "/model_settings --show (no model name)" do
    test "does not crash and returns continue" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} =
                   ModelSettings.handle_model_settings("/model_settings --show", %{})
        end)

      # Should produce some output (the model name from config)
      assert is_binary(output)
      assert output != ""
    end
  end

  describe "/model_settings --show <model_name>" do
    test "shows model name in output" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} =
                   ModelSettings.handle_model_settings(
                     "/model_settings --show claude-opus-4",
                     %{}
                   )
        end)

      assert output =~ "claude-opus-4"
    end

    test "shows no custom settings for unconfigured model" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} =
                   ModelSettings.handle_model_settings(
                     "/model_settings --show some-random-model",
                     %{}
                   )
        end)

      # Either "No custom settings" or settings from global controls
      assert is_binary(output)
    end
  end

  # ── /ms alias ─────────────────────────────────────────────────────────────

  describe "/ms alias" do
    test "/ms --show works like /model_settings --show" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = ModelSettings.handle_model_settings("/ms --show", %{})
        end)

      assert is_binary(output)
    end

    test "/ms --show <model> works like /model_settings --show <model>" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} =
                   ModelSettings.handle_model_settings("/ms --show gemini-pro", %{})
        end)

      assert output =~ "gemini-pro"
    end
  end

  # ── Without --show flag (interactive editor) ─────────────────────────────

  describe "/model_settings without --show — interactive mode" do
    test "enters interactive editor for current model" do
      # The interactive editor reads from IO.gets, so we simulate
      # an immediate 'q' to quit.
      output =
        ExUnit.CaptureIO.capture_io([input: "q\n"], fn ->
          assert {:continue, _} = ModelSettings.handle_model_settings("/model_settings", %{})
        end)

      # Should show the editor header
      assert output =~ "Model Settings Editor"
    end

    test "/model_settings <model_name> enters interactive editor for that model" do
      output =
        ExUnit.CaptureIO.capture_io([input: "q\n"], fn ->
          assert {:continue, _} =
                   ModelSettings.handle_model_settings("/model_settings gpt-5", %{})
        end)

      assert output =~ "Model Settings Editor"
      assert output =~ "gpt-5"
    end

    test "/ms without --show enters interactive editor" do
      output =
        ExUnit.CaptureIO.capture_io([input: "q\n"], fn ->
          assert {:continue, _} = ModelSettings.handle_model_settings("/ms", %{})
        end)

      assert output =~ "Model Settings Editor"
    end
  end

  # ── Format helpers ────────────────────────────────────────────────────────

  describe "format_setting_value/2" do
    test "formats nil as not set" do
      assert ModelSettings.format_setting_value(nil, %{type: :numeric, format: "{:.2f}"}) ==
               "— (not set)"
    end

    test "formats blank string as not set" do
      assert ModelSettings.format_setting_value("", %{type: :choice}) == "— (not set)"
    end

    test "formats boolean true as Enabled" do
      assert ModelSettings.format_setting_value(true, %{type: :boolean}) == "Enabled"
    end

    test "formats boolean false as Disabled" do
      assert ModelSettings.format_setting_value(false, %{type: :boolean}) == "Disabled"
    end

    test "formats choice value as string" do
      assert ModelSettings.format_setting_value("medium", %{type: :choice}) == "medium"
    end

    test "formats numeric value with 2 decimal places" do
      result = ModelSettings.format_setting_value(0.75, %{type: :numeric, format: "{:.2f}"})
      assert result == "0.75"
    end

    test "formats numeric value as integer when format is {:.0f}" do
      result = ModelSettings.format_setting_value(42, %{type: :numeric, format: "{:.0f}"})
      assert result == "42"
    end

    test "formats unknown type as string" do
      assert ModelSettings.format_setting_value("hello", %{type: :unknown}) == "hello"
    end

    test "formats with fallback when no format key" do
      assert ModelSettings.format_setting_value(99, %{type: :numeric}) == "99"
    end

    test "nil with boolean definition shows not set (not Enabled/Disabled)" do
      assert ModelSettings.format_setting_value(nil, %{type: :boolean}) == "— (not set)"
    end

    test "nil with choice definition shows not set" do
      assert ModelSettings.format_setting_value(nil, %{type: :choice}) == "— (not set)"
    end
  end

  # ── Setting definitions coverage ──────────────────────────────────────────

  describe "setting_definitions/0" do
    test "contains expected setting keys" do
      defs = ModelSettings.setting_definitions()

      expected_keys = [
        "temperature",
        "seed",
        "top_p",
        "reasoning_effort",
        "summary",
        "verbosity",
        "extended_thinking",
        "budget_tokens",
        "interleaved_thinking",
        "clear_thinking",
        "thinking_enabled",
        "thinking_level",
        "effort"
      ]

      Enum.each(expected_keys, fn key ->
        assert Map.has_key?(defs, key), "Expected key #{key} in setting_definitions"
      end)
    end

    test "each definition has name and type" do
      defs = ModelSettings.setting_definitions()

      Enum.each(defs, fn {key, defn} ->
        assert Map.has_key?(defn, :name), "Definition for #{key} missing :name"
        assert Map.has_key?(defn, :type), "Definition for #{key} missing :type"
      end)
    end
  end

  # ── Edge cases ────────────────────────────────────────────────────────────

  describe "edge cases" do
    test "handles model names with special characters" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} =
                   ModelSettings.handle_model_settings(
                     "/model_settings --show gpt-4.1-mini",
                     %{}
                   )
        end)

      assert output =~ "gpt-4.1-mini"
    end

    test "always returns {:continue, state}" do
      result = ModelSettings.handle_model_settings("/model_settings --show", %{foo: "bar"})
      assert result == {:continue, %{foo: "bar"}}
    end

    test "handles /ms without --show (enters interactive)" do
      output =
        ExUnit.CaptureIO.capture_io([input: "q\n"], fn ->
          assert {:continue, _} = ModelSettings.handle_model_settings("/ms", %{})
        end)

      assert output =~ "Model Settings Editor"
    end
  end

  # ── Capability-based display (Python parity) ─────────────────────────────

  describe "get_display_settings/1 — capability-based gating" do
    # ── Settings shown when supported_settings explicitly includes them ───

    test "includes reasoning_effort when model metadata lists it in supported_settings" do
      # Inject a test model into ETS that explicitly supports reasoning controls
      test_model = "bd270-test-openai-reasoning"

      :ets.insert(
        :model_configs,
        {test_model, %{"supported_settings" => ["reasoning_effort", "summary", "verbosity"]}}
      )

      on_exit(fn -> :ets.delete(:model_configs, test_model) end)

      result = ModelSettings.get_display_settings(test_model)

      assert Map.has_key?(result, "reasoning_effort"),
             "Expected reasoning_effort in display settings for model with explicit support"

      assert Map.has_key?(result, "summary"),
             "Expected summary in display settings for model with explicit support"

      assert Map.has_key?(result, "verbosity"),
             "Expected verbosity in display settings for model with explicit support"
    end

    # ── Settings absent when supported_settings does NOT include them ──

    test "excludes reasoning_effort when model supported_settings omits it" do
      # firepass-kimi-k2p5-turbo has supported_settings: ["temperature", "seed", "top_p"]
      # — no reasoning/summary/verbosity controls.
      result = ModelSettings.get_display_settings("firepass-kimi-k2p5-turbo")

      refute Map.has_key?(result, "reasoning_effort"),
             "reasoning_effort should NOT appear for models without it in supported_settings"

      refute Map.has_key?(result, "summary"),
             "summary should NOT appear for models without it in supported_settings"

      refute Map.has_key?(result, "verbosity"),
             "verbosity should NOT appear for models without it in supported_settings"
    end

    # ── Settings absent when model metadata is missing entirely ─────────

    test "excludes OpenAI global controls for unknown models (no metadata)" do
      result = ModelSettings.get_display_settings("nonexistent-model-xyz")

      refute Map.has_key?(result, "reasoning_effort"),
             "reasoning_effort should NOT appear for models without any metadata"

      refute Map.has_key?(result, "summary"),
             "summary should NOT appear for models without any metadata"

      refute Map.has_key?(result, "verbosity"),
             "verbosity should NOT appear for models without any metadata"
    end

    test "returns empty map for unknown model with no per-model settings" do
      result = ModelSettings.get_display_settings("nonexistent-model-xyz")
      assert result == %{}
    end

    test "does not crash for known models with supported_settings" do
      result = ModelSettings.get_display_settings("firepass-kimi-k2p5-turbo")
      assert is_map(result)
    end
  end

  # ── Interactive editor ──────────────────────────────────────────

  describe "Interactive.init/1" do
    test "initializes with model name and settings" do
      assert {:ok, state} = Interactive.init(%{model_name: "gpt-5"})
      assert state.model_name == "gpt-5"
      assert is_map(state.settings)
    end
  end

  describe "Interactive.render/1" do
    test "shows the editor header with model name" do
      {:ok, state} = Interactive.init(%{model_name: "gpt-5"})
      rendered = Interactive.render(state)
      assert rendered =~ "Model Settings Editor"
      assert rendered =~ "gpt-5"
    end

    test "shows numbered setting options" do
      {:ok, state} = Interactive.init(%{model_name: "gpt-5"})
      rendered = Interactive.render(state)
      assert rendered =~ "1."
      assert rendered =~ "Temperature"
      assert rendered =~ "2."
      assert rendered =~ "Seed"
      assert rendered =~ "3."
      assert rendered =~ "Top-P"
    end

    test "shows input instructions" do
      {:ok, state} = Interactive.init(%{model_name: "gpt-5"})
      rendered = Interactive.render(state)
      assert rendered =~ "q to quit"
      assert rendered =~ "r <number>"
    end

    test "shows transient message when present" do
      {:ok, state} = Interactive.init(%{model_name: "gpt-5"})
      state = %{state | message: " ✓ Test message"}
      rendered = Interactive.render(state)
      assert rendered =~ "Test message"
    end
  end

  describe "Interactive.handle_input/2" do
    setup do
      {:ok, state} = Interactive.init(%{model_name: "gpt-5"})
      {:ok, state: state}
    end

    test "'q' returns :quit", %{state: state} do
      assert Interactive.handle_input("q", state) == :quit
    end

    test "'Q' returns :quit", %{state: state} do
      assert Interactive.handle_input("Q", state) == :quit
    end

    test "invalid input shows warning", %{state: state} do
      assert {:ok, new_state} = Interactive.handle_input("xyz", state)
      assert new_state.message =~ "Invalid input"
    end

    test "out-of-range option number shows warning", %{state: state} do
      assert {:ok, new_state} = Interactive.handle_input("99 blah", state)
      assert new_state.message =~ "Invalid option number"
    end

    test "reset out-of-range shows warning", %{state: state} do
      assert {:ok, new_state} = Interactive.handle_input("r 99", state)
      assert new_state.message =~ "Invalid option number"
    end

    test "set temperature with valid value", %{state: state} do
      assert {:ok, new_state} = Interactive.handle_input("1 0.7", state)
      assert new_state.message =~ "Set Temperature"
    end

    test "set temperature with out-of-range value shows error", %{state: state} do
      assert {:ok, new_state} = Interactive.handle_input("1 3.0", state)
      assert new_state.message =~ "out of range"
    end

    test "set seed with valid value", %{state: state} do
      assert {:ok, new_state} = Interactive.handle_input("2 42", state)
      assert new_state.message =~ "Set Seed"
    end

    test "set top_p with valid value", %{state: state} do
      assert {:ok, new_state} = Interactive.handle_input("3 0.9", state)
      assert new_state.message =~ "Set Top-P"
    end

    test "set invalid choice shows error", %{state: state} do
      assert {:ok, new_state} = Interactive.handle_input("4 invalid", state)
      assert new_state.message =~ "Invalid choice"
    end

    test "reset a setting", %{state: state} do
      # First set, then reset
      {:ok, state} = Interactive.handle_input("1 0.5", state)
      assert {:ok, new_state} = Interactive.handle_input("r 1", state)
      assert new_state.message =~ "Reset Temperature"
    end
  end

  describe "Interactive.editable_fields/0" do
    test "has 6 editable fields" do
      fields = Interactive.editable_fields()
      assert length(fields) == 6
    end

    test "fields have expected keys" do
      fields = Interactive.editable_fields()

      keys = Enum.map(fields, & &1.key)
      assert keys == ["temperature", "seed", "top_p", "reasoning_effort", "summary", "verbosity"]
    end
  end
end
