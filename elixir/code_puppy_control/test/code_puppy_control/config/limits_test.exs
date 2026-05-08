defmodule CodePuppyControl.Config.LimitsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Limits, Loader}

  @tmp_dir System.tmp_dir!()
  @test_cfg Path.join(@tmp_dir, "limits_test_#{:erlang.unique_integer([:positive])}.cfg")

  setup do
    File.write!(@test_cfg, "[puppy]\n")
    Loader.load(@test_cfg)

    on_exit(fn ->
      File.rm(@test_cfg)
      Loader.invalidate()
    end)

    :ok
  end

  describe "protected_token_count/0" do
    test "defaults to 50000" do
      assert Limits.protected_token_count() == 50_000
    end

    test "reads configured value" do
      File.write!(@test_cfg, "[puppy]\nprotected_token_count = 80000\n")
      Loader.load(@test_cfg)

      assert Limits.protected_token_count() == 80_000
    end

    test "enforces minimum of 1000" do
      File.write!(@test_cfg, "[puppy]\nprotected_token_count = 100\n")
      Loader.load(@test_cfg)

      assert Limits.protected_token_count() == 1000
    end
  end

  describe "compaction_threshold/0" do
    test "defaults to 0.85" do
      assert Limits.compaction_threshold() == 0.85
    end

    test "reads configured value" do
      File.write!(@test_cfg, "[puppy]\ncompaction_threshold = 0.9\n")
      Loader.load(@test_cfg)

      assert Limits.compaction_threshold() == 0.9
    end

    test "clamps to max 0.95" do
      File.write!(@test_cfg, "[puppy]\ncompaction_threshold = 0.99\n")
      Loader.load(@test_cfg)

      assert Limits.compaction_threshold() == 0.95
    end

    test "clamps to min 0.5" do
      File.write!(@test_cfg, "[puppy]\ncompaction_threshold = 0.1\n")
      Loader.load(@test_cfg)

      assert Limits.compaction_threshold() == 0.5
    end
  end

  describe "compaction_strategy/0" do
    test "defaults to summarization" do
      assert Limits.compaction_strategy() == "summarization"
    end

    test "returns truncation when configured" do
      File.write!(@test_cfg, "[puppy]\ncompaction_strategy = truncation\n")
      Loader.load(@test_cfg)

      assert Limits.compaction_strategy() == "truncation"
    end
  end

  describe "message_limit/0" do
    test "defaults to 100" do
      assert Limits.message_limit() == 100
    end

    test "reads configured value" do
      File.write!(@test_cfg, "[puppy]\nmessage_limit = 200\n")
      Loader.load(@test_cfg)

      assert Limits.message_limit() == 200
    end
  end

  describe "resume_message_count/0" do
    test "defaults to 50" do
      assert Limits.resume_message_count() == 50
    end

    test "clamps to max 100" do
      File.write!(@test_cfg, "[puppy]\nresume_message_count = 200\n")
      Loader.load(@test_cfg)

      assert Limits.resume_message_count() == 100
    end
  end

  describe "max_session_tokens/0" do
    test "defaults to 0 (disabled)" do
      assert Limits.max_session_tokens() == 0
    end
  end

  describe "max_run_tokens/0" do
    test "defaults to 0 (disabled)" do
      assert Limits.max_run_tokens() == 0
    end
  end

  describe "bus_request_timeout_seconds/0" do
    test "defaults to 300.0" do
      assert Limits.bus_request_timeout_seconds() == 300.0
    end

    test "clamps to max 3600" do
      File.write!(@test_cfg, "[puppy]\nbus_request_timeout_seconds = 5000\n")
      Loader.load(@test_cfg)

      assert Limits.bus_request_timeout_seconds() == 3600.0
    end

    test "clamps to min 10" do
      File.write!(@test_cfg, "[puppy]\nbus_request_timeout_seconds = 1\n")
      Loader.load(@test_cfg)

      assert Limits.bus_request_timeout_seconds() == 10.0
    end
  end

  describe "summarization settings" do
    test "trigger_fraction defaults to 0.85" do
      assert Limits.summarization_trigger_fraction() == 0.85
    end

    test "keep_fraction defaults to 0.10" do
      assert Limits.summarization_keep_fraction() == 0.10
    end

    test "pretruncate_enabled defaults to true" do
      assert Limits.summarization_pretruncate_enabled?() == true
    end

    test "arg_max_length defaults to 500" do
      assert Limits.summarization_arg_max_length() == 500
    end

    test "return_max_length defaults to 5000" do
      assert Limits.summarization_return_max_length() == 5000
    end
  end

  describe "context_length/0" do
    test "returns a positive integer" do
      assert Limits.context_length() > 0
    end
  end
end
