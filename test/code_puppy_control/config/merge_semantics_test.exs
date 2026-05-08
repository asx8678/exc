defmodule CodePuppyControl.Config.MergeSemanticsTest do
  @moduledoc """
  Tests for config merge semantics — additive dict merge, env override layering,
  and the porting plan's stated contract: "string returns concatenated, dict
  returns updated (later wins on conflict)".

  These are Wave 2 tests for porting the spirit of:
  - Python test_resolvers.py (resolve_str/bool/int/float/path merge chain)
  - Python test_typed_settings.py (config layering: env > legacy > default)
  - porting plan: "Property-test the config loader's merge semantics"
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.Loader

  @tmp_dir System.tmp_dir!()

  defp tmp_cfg_path do
    Path.join(@tmp_dir, "merge_test_#{:erlang.unique_integer([:positive])}.cfg")
  end

  setup do
    on_exit(fn ->
      Loader.invalidate()

      # Clean env vars
      for var <- [
            "PUP_MODEL",
            "PUPPY_DEFAULT_MODEL",
            "PUP_AGENT",
            "PUPPY_DEFAULT_AGENT",
            "PUP_DEBUG",
            "PUPPY_TEMPERATURE",
            "PUPPY_MESSAGE_LIMIT",
            "PUPPY_PROTECTED_TOKEN_COUNT"
          ] do
        System.delete_env(var)
      end
    end)

    :ok
  end

  # ── Merge chain: env > file > default ────────────────────────────────────

  describe "resolution priority: env var > file value > default" do
    test "file value is used when env var is absent" do
      path = tmp_cfg_path()
      File.write!(path, "model = file-model\n")

      try do
        config = Loader.load(path)
        assert config["puppy"]["model"] == "file-model"
      after
        File.rm(path)
      end
    end

    test "env var overrides file value" do
      path = tmp_cfg_path()
      File.write!(path, "model = file-model\n")
      System.put_env("PUP_MODEL", "env-model")

      try do
        config = Loader.load(path)
        assert config["puppy"]["model"] == "env-model"
      after
        File.rm(path)
        System.delete_env("PUP_MODEL")
      end
    end

    # TODO: PUP_ should win over PUPPY_, but the current
    # merge order applies PUPPY_ second, overwriting PUP_. This test
    # documents the actual behavior until the bug is fixed.
    test "PUPPY_DEFAULT_MODEL overwrites PUP_MODEL due to merge order" do
      path = tmp_cfg_path()
      File.write!(path, "")
      System.put_env("PUP_MODEL", "new-model")
      System.put_env("PUPPY_DEFAULT_MODEL", "legacy-model")

      try do
        config = Loader.load(path)
        # Current: PUPPY_ applied second overwrites PUP_
        assert config["puppy"]["model"] == "legacy-model"
      after
        File.rm(path)
        System.delete_env("PUP_MODEL")
        System.delete_env("PUPPY_DEFAULT_MODEL")
      end
    end

    test "PUPPY_DEFAULT_MODEL fills in when PUP_MODEL absent and file has no model" do
      path = tmp_cfg_path()
      File.write!(path, "")
      System.put_env("PUPPY_DEFAULT_MODEL", "legacy-model")

      try do
        config = Loader.load(path)
        assert config["puppy"]["model"] == "legacy-model"
      after
        File.rm(path)
        System.delete_env("PUPPY_DEFAULT_MODEL")
      end
    end
  end

  # ── Additive section merge ───────────────────────────────────────────────

  describe "additive section merge" do
    test "env override adds keys without removing existing ones" do
      path = tmp_cfg_path()
      File.write!(path, "model = file-model\ntemperature = 0.7\n")

      try do
        # Override only the model — temperature should survive
        System.put_env("PUP_MODEL", "env-model")
        config = Loader.load(path)

        assert config["puppy"]["model"] == "env-model"
        assert config["puppy"]["temperature"] == "0.7"
      after
        File.rm(path)
        System.delete_env("PUP_MODEL")
      end
    end

    test "multiple env overrides each apply to their respective keys" do
      path = tmp_cfg_path()
      File.write!(path, "model = file-model\ndefault_agent = file-agent\n")

      try do
        System.put_env("PUP_MODEL", "env-model")
        System.put_env("PUP_AGENT", "env-agent")
        config = Loader.load(path)

        assert config["puppy"]["model"] == "env-model"
        assert config["puppy"]["default_agent"] == "env-agent"
      after
        File.rm(path)
        System.delete_env("PUP_MODEL")
        System.delete_env("PUP_AGENT")
      end
    end

    test "env override for debug key" do
      path = tmp_cfg_path()
      File.write!(path, "")

      try do
        System.put_env("PUP_DEBUG", "true")
        config = Loader.load(path)
        assert config["puppy"]["debug"] == "true"
      after
        File.rm(path)
        System.delete_env("PUP_DEBUG")
      end
    end
  end

  # ── Empty string handling ────────────────────────────────────────────────

  describe "empty string env vars are treated as absent" do
    test "empty PUP_MODEL does not override file model" do
      path = tmp_cfg_path()
      File.write!(path, "model = file-model\n")
      System.put_env("PUP_MODEL", "")

      try do
        config = Loader.load(path)
        assert config["puppy"]["model"] == "file-model"
      after
        File.rm(path)
        System.delete_env("PUP_MODEL")
      end
    end

    test "empty PUP_AGENT does not override file default_agent" do
      path = tmp_cfg_path()
      File.write!(path, "default_agent = file-agent\n")
      System.put_env("PUP_AGENT", "")

      try do
        config = Loader.load(path)
        assert config["puppy"]["default_agent"] == "file-agent"
      after
        File.rm(path)
        System.delete_env("PUP_AGENT")
      end
    end
  end

  # ── Config key casing ────────────────────────────────────────────────────

  describe "config key casing and trimming" do
    test "keys are trimmed of whitespace" do
      path = tmp_cfg_path()
      File.write!(path, " model = test-value\n")

      try do
        config = Loader.load(path)
        assert config["puppy"]["model"] == "test-value"
      after
        File.rm(path)
      end
    end

    test "values are trimmed of whitespace" do
      path = tmp_cfg_path()
      File.write!(path, "model = test-value \n")

      try do
        config = Loader.load(path)
        assert config["puppy"]["model"] == "test-value"
      after
        File.rm(path)
      end
    end
  end

  # ── INI comment handling ─────────────────────────────────────────────────

  describe "INI comment handling" do
    test "semicolon comments are ignored" do
      path = tmp_cfg_path()
      File.write!(path, "; This is a comment\nmodel = test-model\n")

      try do
        config = Loader.load(path)
        assert config["puppy"]["model"] == "test-model"
        refute Map.has_key?(config["puppy"], "this")
      after
        File.rm(path)
      end
    end

    test "hash comments are ignored" do
      path = tmp_cfg_path()
      File.write!(path, "# This is a comment\nmodel = test-model\n")

      try do
        config = Loader.load(path)
        assert config["puppy"]["model"] == "test-model"
        refute Map.has_key?(config["puppy"], "this")
      after
        File.rm(path)
      end
    end
  end

  # ── Value with equals signs ──────────────────────────────────────────────

  describe "values with equals signs" do
    test "URLs with query parameters are preserved" do
      path = tmp_cfg_path()
      File.write!(path, "url = https://example.com?a=1&b=2\n")

      try do
        config = Loader.load(path)
        assert config["puppy"]["url"] == "https://example.com?a=1&b=2"
      after
        File.rm(path)
      end
    end

    test "base64 values with = padding are preserved" do
      path = tmp_cfg_path()
      File.write!(path, "token = abc123==\n")

      try do
        config = Loader.load(path)
        assert config["puppy"]["token"] == "abc123=="
      after
        File.rm(path)
      end
    end
  end

  # ── PUPPY_ legacy temperature/message_limit overrides ────────────────────

  describe "PUPPY_ legacy env overrides" do
    test "PUPPY_TEMPERATURE overrides temperature" do
      path = tmp_cfg_path()
      File.write!(path, "temperature = 0.5\n")
      System.put_env("PUPPY_TEMPERATURE", "0.9")

      try do
        config = Loader.load(path)
        assert config["puppy"]["temperature"] == "0.9"
      after
        File.rm(path)
        System.delete_env("PUPPY_TEMPERATURE")
      end
    end

    test "PUPPY_MESSAGE_LIMIT overrides message_limit" do
      path = tmp_cfg_path()
      File.write!(path, "message_limit = 50\n")
      System.put_env("PUPPY_MESSAGE_LIMIT", "200")

      try do
        config = Loader.load(path)
        assert config["puppy"]["message_limit"] == "200"
      after
        File.rm(path)
        System.delete_env("PUPPY_MESSAGE_LIMIT")
      end
    end

    test "PUPPY_PROTECTED_TOKEN_COUNT overrides protected_token_count" do
      path = tmp_cfg_path()
      File.write!(path, "")
      System.put_env("PUPPY_PROTECTED_TOKEN_COUNT", "100000")

      try do
        config = Loader.load(path)
        assert config["puppy"]["protected_token_count"] == "100000"
      after
        File.rm(path)
        System.delete_env("PUPPY_PROTECTED_TOKEN_COUNT")
      end
    end
  end
end
