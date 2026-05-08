defmodule CodePuppyControl.Config.DebugTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Debug, Loader}

  @tmp_dir System.tmp_dir!()
  @test_cfg Path.join(@tmp_dir, "debug_test_#{:erlang.unique_integer([:positive])}.cfg")

  setup do
    File.write!(@test_cfg, "[puppy]\n")
    Loader.load(@test_cfg)

    on_exit(fn ->
      File.rm(@test_cfg)
      Loader.invalidate()
      System.delete_env("PUP_DEBUG")
    end)

    :ok
  end

  describe "yolo_mode?/0" do
    test "defaults to true" do
      assert Debug.yolo_mode?() == true
    end

    test "respects config" do
      File.write!(@test_cfg, "[puppy]\nyolo_mode = false\n")
      Loader.load(@test_cfg)

      assert Debug.yolo_mode?() == false
    end
  end

  describe "allow_recursion?/0" do
    test "defaults to true" do
      assert Debug.allow_recursion?() == true
    end
  end

  describe "dbos_enabled?/0" do
    test "defaults to true" do
      assert Debug.dbos_enabled?() == true
    end
  end

  describe "pack_agents_enabled?/0" do
    test "defaults to false" do
      assert Debug.pack_agents_enabled?() == false
    end
  end

  describe "universal_constructor_enabled?/0" do
    test "defaults to true" do
      assert Debug.universal_constructor_enabled?() == true
    end
  end

  describe "streaming_enabled?/0" do
    test "defaults to true" do
      assert Debug.streaming_enabled?() == true
    end
  end

  describe "gitignore_filtering_enabled?/0" do
    test "defaults to false" do
      assert Debug.gitignore_filtering_enabled?() == false
    end
  end

  describe "http2_enabled?/0" do
    test "defaults to false" do
      assert Debug.http2_enabled?() == false
    end
  end

  describe "mcp_disabled?/0" do
    test "defaults to false" do
      assert Debug.mcp_disabled?() == false
    end
  end

  describe "subagent_verbose?/0" do
    test "defaults to false" do
      assert Debug.subagent_verbose?() == false
    end
  end

  describe "safety_permission_level/0" do
    test "defaults to medium" do
      assert Debug.safety_permission_level() == "medium"
    end

    test "reads configured level" do
      File.write!(@test_cfg, "[puppy]\nsafety_permission_level = high\n")
      Loader.load(@test_cfg)

      assert Debug.safety_permission_level() == "high"
    end

    test "returns default for invalid level" do
      File.write!(@test_cfg, "[puppy]\nsafety_permission_level = invalid\n")
      Loader.load(@test_cfg)

      assert Debug.safety_permission_level() == "medium"
    end
  end

  describe "debug?/0" do
    test "defaults to false" do
      assert Debug.debug?() == false
    end

    test "respects PUP_DEBUG env var" do
      System.put_env("PUP_DEBUG", "1")
      assert Debug.debug?() == true
    end

    test "respects config key" do
      File.write!(@test_cfg, "[puppy]\ndebug = true\n")
      Loader.load(@test_cfg)

      assert Debug.debug?() == true
    end
  end

  describe "puppy_token/0" do
    test "defaults to nil" do
      assert Debug.puppy_token() == nil
    end

    test "reads configured token" do
      File.write!(@test_cfg, "[puppy]\npuppy_token = abc123\n")
      Loader.load(@test_cfg)

      assert Debug.puppy_token() == "abc123"
    end
  end

  describe "memory config" do
    test "memory_debounce_seconds defaults to 30" do
      assert Debug.memory_debounce_seconds() == 30
    end

    test "memory_max_facts defaults to 50" do
      assert Debug.memory_max_facts() == 50
    end

    test "memory_token_budget defaults to 500" do
      assert Debug.memory_token_budget() == 500
    end
  end

  describe "agent_memory_enabled?/0" do
    test "defaults to false" do
      assert Debug.agent_memory_enabled?() == false
    end
  end

  describe "load_api_keys_to_environment/0" do
    test "runs without error" do
      assert Debug.load_api_keys_to_environment() == :ok
    end

    test "promotes wafer_api_key from config to WAFER_API_KEY env" do
      # Ensure env is clean
      System.delete_env("WAFER_API_KEY")

      File.write!(@test_cfg, "[puppy]\nwafer_api_key = wfr_test_value_123\n")
      Loader.load(@test_cfg)

      assert :ok = Debug.load_api_keys_to_environment()
      assert System.get_env("WAFER_API_KEY") == "wfr_test_value_123"

      # Cleanup
      System.delete_env("WAFER_API_KEY")
    end
  end
end
