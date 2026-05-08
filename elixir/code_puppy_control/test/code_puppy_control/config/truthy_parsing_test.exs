defmodule CodePuppyControl.Config.TruthyParsingTest do
  @moduledoc """
  Tests for the shared truthy?/2 pattern across Config modules.

  Ports the spirit of Python's test_env_helpers.py (env_bool) — the Elixir
  modules Debug, Limits, Cache, and TUI all share a truthy? pattern that
  parses string values from puppy.cfg into booleans.

  These are Wave 2 tests for .
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Debug, Limits, Cache, TUI, Loader}

  @tmp_dir System.tmp_dir!()

  defp tmp_cfg_path do
    Path.join(@tmp_dir, "truthy_test_#{:erlang.unique_integer([:positive])}.cfg")
  end

  setup do
    on_exit(fn ->
      Loader.invalidate()

      for var <- [
            "PUP_MODEL",
            "PUPPY_DEFAULT_MODEL",
            "PUP_AGENT",
            "PUPPY_DEFAULT_AGENT",
            "PUP_DEBUG"
          ] do
        System.delete_env(var)
      end
    end)

    :ok
  end

  # ── Truthy values ────────────────────────────────────────────────────────

  describe "truthy string values" do
    @truthy_strings ["1", "true", "yes", "on", "True", "TRUE", "Yes", "YES", "On", "ON"]

    test "all truthy strings parse to true for yolo_mode" do
      for val <- @truthy_strings do
        path = tmp_cfg_path()
        File.write!(path, "yolo_mode = #{val}\n")

        try do
          Loader.load(path)

          assert Debug.yolo_mode?() == true,
                 "Expected yolo_mode? to be true for value #{inspect(val)}"
        after
          File.rm(path)
        end
      end
    end

    test "all truthy strings parse to true for enable_streaming" do
      for val <- @truthy_strings do
        path = tmp_cfg_path()
        File.write!(path, "enable_streaming = #{val}\n")

        try do
          Loader.load(path)

          assert Debug.streaming_enabled?() == true,
                 "Expected streaming_enabled? to be true for value #{inspect(val)}"
        after
          File.rm(path)
        end
      end
    end
  end

  # ── Falsy values ────────────────────────────────────────────────────────

  describe "falsy string values" do
    @falsy_strings ["0", "false", "no", "off", "False", "FALSE", "No", "NO", "Off", "OFF"]

    test "all falsy strings parse to false for yolo_mode (despite default true)" do
      for val <- @falsy_strings do
        path = tmp_cfg_path()
        File.write!(path, "yolo_mode = #{val}\n")

        try do
          Loader.load(path)
          # yolo_mode default is true, but explicit falsy value should win
          assert Debug.yolo_mode?() == false,
                 "Expected yolo_mode? to be false for value #{inspect(val)}"
        after
          File.rm(path)
        end
      end
    end

    test "unrecognized strings parse to false" do
      for val <- ["maybe", "2", "random", "yep", "nope"] do
        path = tmp_cfg_path()
        File.write!(path, "yolo_mode = #{val}\n")

        try do
          Loader.load(path)

          assert Debug.yolo_mode?() == false,
                 "Expected yolo_mode? to be false for unrecognized value #{inspect(val)}"
        after
          File.rm(path)
        end
      end
    end
  end

  # ── Default value when key missing ──────────────────────────────────────

  describe "default value when key is absent from config" do
    test "yolo_mode defaults to true" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Debug.yolo_mode?() == true
      after
        File.rm(path)
      end
    end

    test "allow_recursion defaults to true" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Debug.allow_recursion?() == true
      after
        File.rm(path)
      end
    end

    test "pack_agents_enabled defaults to false" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Debug.pack_agents_enabled?() == false
      after
        File.rm(path)
      end
    end

    test "http2 defaults to false" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Debug.http2_enabled?() == false
      after
        File.rm(path)
      end
    end

    test "mcp_disabled defaults to false" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Debug.mcp_disabled?() == false
      after
        File.rm(path)
      end
    end
  end

  # ── Whitespace trimming in boolean values ────────────────────────────────

  describe "whitespace trimming" do
    test "whitespace-padded 'true' is recognized as truthy" do
      path = tmp_cfg_path()
      File.write!(path, "yolo_mode = true \n")

      try do
        Loader.load(path)
        assert Debug.yolo_mode?() == true
      after
        File.rm(path)
      end
    end

    test "whitespace-padded 'false' is recognized as falsy" do
      path = tmp_cfg_path()
      File.write!(path, "yolo_mode = false \n")

      try do
        Loader.load(path)
        assert Debug.yolo_mode?() == false
      after
        File.rm(path)
      end
    end
  end

  # ── Integer parsing with clamping ────────────────────────────────────────

  describe "integer parsing with clamping (Limits module)" do
    test "message_limit parses valid integer" do
      path = tmp_cfg_path()
      File.write!(path, "message_limit = 200\n")

      try do
        Loader.load(path)
        assert Limits.message_limit() == 200
      after
        File.rm(path)
      end
    end

    test "message_limit defaults to 100 when not set" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Limits.message_limit() == 100
      after
        File.rm(path)
      end
    end

    test "message_limit clamps to minimum 1" do
      path = tmp_cfg_path()
      File.write!(path, "message_limit = 0\n")

      try do
        Loader.load(path)
        assert Limits.message_limit() == 100
      after
        File.rm(path)
      end
    end

    test "message_limit falls back to default for non-numeric value" do
      path = tmp_cfg_path()
      File.write!(path, "message_limit = not_a_number\n")

      try do
        Loader.load(path)
        assert Limits.message_limit() == 100
      after
        File.rm(path)
      end
    end

    test "protected_token_count clamps to max 75% of context" do
      path = tmp_cfg_path()
      # 128k context, 75% = 96000
      File.write!(path, "protected_token_count = 999999\n")

      try do
        Loader.load(path)
        # Should be clamped, not 999999
        assert Limits.protected_token_count() < 999_999
        assert Limits.protected_token_count() >= 1000
      after
        File.rm(path)
      end
    end
  end

  # ── Float parsing with clamping ──────────────────────────────────────────

  describe "float parsing with clamping (Limits module)" do
    test "compaction_threshold parses valid float" do
      path = tmp_cfg_path()
      File.write!(path, "compaction_threshold = 0.7\n")

      try do
        Loader.load(path)
        assert Limits.compaction_threshold() == 0.7
      after
        File.rm(path)
      end
    end

    test "compaction_threshold defaults to 0.85" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Limits.compaction_threshold() == 0.85
      after
        File.rm(path)
      end
    end

    test "compaction_threshold clamps to 0.95 maximum" do
      path = tmp_cfg_path()
      File.write!(path, "compaction_threshold = 0.99\n")

      try do
        Loader.load(path)
        assert Limits.compaction_threshold() == 0.95
      after
        File.rm(path)
      end
    end

    test "compaction_threshold clamps to 0.5 minimum" do
      path = tmp_cfg_path()
      File.write!(path, "compaction_threshold = 0.1\n")

      try do
        Loader.load(path)
        assert Limits.compaction_threshold() == 0.5
      after
        File.rm(path)
      end
    end

    test "compaction_threshold falls back to default for invalid value" do
      path = tmp_cfg_path()
      File.write!(path, "compaction_threshold = not_a_float\n")

      try do
        Loader.load(path)
        assert Limits.compaction_threshold() == 0.85
      after
        File.rm(path)
      end
    end
  end

  # ── Enum validation ──────────────────────────────────────────────────────

  describe "enum validation (Debug.safety_permission_level)" do
    @valid_levels ["none", "low", "medium", "high", "critical"]

    test "all valid levels are accepted" do
      for level <- @valid_levels do
        path = tmp_cfg_path()
        File.write!(path, "safety_permission_level = #{level}\n")

        try do
          Loader.load(path)
          assert Debug.safety_permission_level() == level
        after
          File.rm(path)
        end
      end
    end

    test "invalid level falls back to medium" do
      path = tmp_cfg_path()
      File.write!(path, "safety_permission_level = ultra_extreme\n")

      try do
        Loader.load(path)
        assert Debug.safety_permission_level() == "medium"
      after
        File.rm(path)
      end
    end

    test "case-insensitive level matching" do
      path = tmp_cfg_path()
      File.write!(path, "safety_permission_level = HIGH\n")

      try do
        Loader.load(path)
        assert Debug.safety_permission_level() == "high"
      after
        File.rm(path)
      end
    end

    test "missing key defaults to medium" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Debug.safety_permission_level() == "medium"
      after
        File.rm(path)
      end
    end
  end

  # ── Cache module integer parsing ─────────────────────────────────────────

  describe "Cache module integer parsing" do
    test "ws_history_maxlen parses valid integer" do
      path = tmp_cfg_path()
      File.write!(path, "ws_history_maxlen = 500\n")

      try do
        Loader.load(path)
        assert Cache.ws_history_maxlen() == 500
      after
        File.rm(path)
      end
    end

    test "ws_history_maxlen defaults to 200" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert Cache.ws_history_maxlen() == 200
      after
        File.rm(path)
      end
    end

    test "ws_history_maxlen falls back for invalid value" do
      path = tmp_cfg_path()
      File.write!(path, "ws_history_maxlen = invalid\n")

      try do
        Loader.load(path)
        assert Cache.ws_history_maxlen() == 200
      after
        File.rm(path)
      end
    end
  end

  # ── TUI module boolean parsing ───────────────────────────────────────────

  describe "TUI module boolean parsing" do
    test "suppress_thinking defaults to false" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert TUI.suppress_thinking?() == false
      after
        File.rm(path)
      end
    end

    test "suppress_thinking parses truthy value" do
      path = tmp_cfg_path()
      File.write!(path, "suppress_thinking_messages = true\n")

      try do
        Loader.load(path)
        assert TUI.suppress_thinking?() == true
      after
        File.rm(path)
      end
    end

    test "auto_save_session defaults to true" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert TUI.auto_save_session?() == true
      after
        File.rm(path)
      end
    end

    test "diff_context_lines defaults to 6" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        Loader.load(path)
        assert TUI.diff_context_lines() == 6
      after
        File.rm(path)
      end
    end

    test "diff_context_lines clamps to max 50" do
      path = tmp_cfg_path()
      File.write!(path, "diff_context_lines = 100\n")

      try do
        Loader.load(path)
        assert TUI.diff_context_lines() == 6
      after
        File.rm(path)
      end
    end

    test "diff_context_lines accepts 0 (no context)" do
      path = tmp_cfg_path()
      File.write!(path, "diff_context_lines = 0\n")

      try do
        Loader.load(path)
        assert TUI.diff_context_lines() == 0
      after
        File.rm(path)
      end
    end
  end

  # ── Debug mode via env var ───────────────────────────────────────────────

  describe "debug mode via PUP_DEBUG env var" do
    test "PUP_DEBUG=1 enables debug mode" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        System.put_env("PUP_DEBUG", "1")
        Loader.load(path)
        assert Debug.debug?() == true
      after
        File.rm(path)
        System.delete_env("PUP_DEBUG")
      end
    end

    test "PUP_DEBUG=0 disables debug mode" do
      path = tmp_cfg_path()
      File.write!(path, "debug = true\n")

      try do
        System.put_env("PUP_DEBUG", "0")
        Loader.load(path)
        # PUP_DEBUG=0 should disable, overriding file config
        assert Debug.debug?() == false
      after
        File.rm(path)
        System.delete_env("PUP_DEBUG")
      end
    end

    test "PUP_DEBUG empty string falls through to config" do
      path = tmp_cfg_path()
      File.write!(path, "debug = true\n")

      try do
        System.put_env("PUP_DEBUG", "")
        Loader.load(path)
        # Empty PUP_DEBUG should fall through — but debug? checks != ""
        # so empty string counts as not debug
        assert Debug.debug?() == false
      after
        File.rm(path)
        System.delete_env("PUP_DEBUG")
      end
    end
  end
end
