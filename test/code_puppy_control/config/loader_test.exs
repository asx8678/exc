defmodule CodePuppyControl.Config.LoaderTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.Loader

  @tmp_dir System.tmp_dir!()
  @test_cfg Path.join(@tmp_dir, "test_puppy_#{:erlang.unique_integer([:positive])}.cfg")

  setup do
    # Clean up before and after
    File.rm(@test_cfg)
    Loader.invalidate()

    on_exit(fn ->
      File.rm(@test_cfg)
      Loader.invalidate()
    end)

    :ok
  end

  describe "parse_string/1" do
    test "parses empty string into default section" do
      result = Loader.parse_string("")
      assert result == %{"puppy" => %{}}
    end

    test "parses key-value pairs in default section" do
      input = """
      model = gpt-5
      yolo_mode = true
      """

      result = Loader.parse_string(input)
      assert result["puppy"]["model"] == "gpt-5"
      assert result["puppy"]["yolo_mode"] == "true"
    end

    test "parses section headers" do
      input = """
      model = gpt-5

      [custom_section]
      key1 = value1
      """

      result = Loader.parse_string(input)
      assert result["puppy"]["model"] == "gpt-5"
      assert result["custom_section"]["key1"] == "value1"
    end

    test "ignores comment lines" do
      input = """
      ; This is a comment
      model = gpt-5
      # Another comment
      yolo_mode = true
      """

      result = Loader.parse_string(input)
      assert map_size(result["puppy"]) == 2
      assert result["puppy"]["model"] == "gpt-5"
    end

    test "handles values with equals signs" do
      input = "url = https://example.com?a=1&b=2"
      result = Loader.parse_string(input)
      assert result["puppy"]["url"] == "https://example.com?a=1&b=2"
    end

    test "trims whitespace from keys and values" do
      input = "  model   =   gpt-5  "
      result = Loader.parse_string(input)
      assert result["puppy"]["model"] == "gpt-5"
    end

    test "handles blank lines" do
      input = """

      model = gpt-5

      yolo_mode = true

      """

      result = Loader.parse_string(input)
      assert result["puppy"]["model"] == "gpt-5"
      assert result["puppy"]["yolo_mode"] == "true"
    end
  end

  describe "parse_file/1" do
    test "returns empty config for non-existent file" do
      result = Loader.parse_file("/nonexistent/path/puppy.cfg")
      assert result == %{"puppy" => %{}}
    end

    test "parses real file" do
      File.write!(@test_cfg, "model = claude-sonnet\nyolo_mode = false\n")

      result = Loader.parse_file(@test_cfg)
      assert result["puppy"]["model"] == "claude-sonnet"
      assert result["puppy"]["yolo_mode"] == "false"
    end
  end

  describe "load/1" do
    test "loads and caches config in persistent_term" do
      File.write!(@test_cfg, "model = test-model\n")

      result = Loader.load(@test_cfg)
      assert result["puppy"]["model"] == "test-model"

      # Should be cached
      cached = Loader.get_cached()
      assert cached["puppy"]["model"] == "test-model"
    end
  end

  describe "get_value/1" do
    test "returns value from cached config" do
      File.write!(@test_cfg, "model = my-model\n")
      Loader.load(@test_cfg)

      assert Loader.get_value("model") == "my-model"
    end

    test "returns nil for missing key" do
      File.write!(@test_cfg, "model = my-model\n")
      Loader.load(@test_cfg)

      assert Loader.get_value("nonexistent") == nil
    end
  end

  describe "merge_env_overrides/1" do
    test "PUP_MODEL overrides model key" do
      System.put_env("PUP_MODEL", "env-model")

      config = %{"puppy" => %{"model" => "file-model"}}
      result = Loader.merge_env_overrides(config)
      assert result["puppy"]["model"] == "env-model"

      System.delete_env("PUP_MODEL")
    end

    test "does not override when env var is empty" do
      System.put_env("PUP_MODEL", "")

      config = %{"puppy" => %{"model" => "file-model"}}
      result = Loader.merge_env_overrides(config)
      assert result["puppy"]["model"] == "file-model"

      System.delete_env("PUP_MODEL")
    end

    test "PUP_AGENT overrides default_agent" do
      System.put_env("PUP_AGENT", "test-agent")

      config = %{"puppy" => %{}}
      result = Loader.merge_env_overrides(config)
      assert result["puppy"]["default_agent"] == "test-agent"

      System.delete_env("PUP_AGENT")
    end
  end

  describe "invalidate/0" do
    test "clears persistent_term cache" do
      File.write!(@test_cfg, "model = my-model\n")
      Loader.load(@test_cfg)

      assert Loader.get_value("model") == "my-model"

      Loader.invalidate()

      # After invalidation, get_cached should reload
      # Since file still exists, it should load fresh
      Loader.load(@test_cfg)
      assert Loader.get_value("model") == "my-model"
    end
  end

  describe "keys/0" do
    test "returns sorted list of keys in default section" do
      input = """
      zebra = last
      alpha = first
      model = middle
      """

      File.write!(@test_cfg, input)
      Loader.load(@test_cfg)

      keys = Loader.keys()
      assert keys == ["alpha", "model", "zebra"]
    end
  end
end
