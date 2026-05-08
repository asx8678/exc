defmodule CodePuppyControl.Config.WriterTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Loader, Writer}

  @tmp_dir System.tmp_dir!()
  @test_cfg_dir Path.join(@tmp_dir, "writer_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@test_cfg_dir)
    test_cfg = Path.join(@test_cfg_dir, "puppy.cfg")

    # Stub Paths.config_file to return our test path
    # We do this by loading into the test path directly
    File.write!(test_cfg, "[puppy]\nmodel = test-model\nyolo_mode = true\n")
    Loader.load(test_cfg)

    on_exit(fn ->
      Loader.invalidate()
      File.rm_rf!(@test_cfg_dir)
    end)

    {:ok, cfg_path: test_cfg, cfg_dir: @test_cfg_dir}
  end

  describe "atomic_write/2 via serialize" do
    test "writes config map to INI file", %{cfg_path: cfg_path} do
      ensure_writer_started()

      config = %{
        "puppy" => %{"model" => "gpt-5", "yolo_mode" => "false"},
        "other" => %{"key" => "val"}
      }

      # Write directly via the writer's serialize logic
      Writer.write_config(config)

      # Read back
      content = File.read!(cfg_path)
      assert content =~ "model = gpt-5"
      assert content =~ "yolo_mode = false"
      assert content =~ "[other]"
      assert content =~ "key = val"
    end
  end

  describe "set_value/2" do
    test "updates a single key and persists", %{cfg_path: cfg_path} do
      # Start Writer GenServer if not already started
      ensure_writer_started()

      Writer.set_value("model", "claude-sonnet")

      content = File.read!(cfg_path)
      assert content =~ "model = claude-sonnet"

      # Loader cache should be invalidated
      Loader.load(cfg_path)
      assert Loader.get_value("model") == "claude-sonnet"
    end
  end

  describe "set_values/1" do
    test "updates multiple keys atomically", %{cfg_path: cfg_path} do
      ensure_writer_started()

      Writer.set_values(%{"alpha" => "1", "beta" => "2"})

      Loader.load(cfg_path)
      assert Loader.get_value("alpha") == "1"
      assert Loader.get_value("beta") == "2"
    end
  end

  describe "delete_value/1" do
    test "removes a key from config", %{cfg_path: cfg_path} do
      ensure_writer_started()

      Writer.set_value("temp_key", "temp_value")
      Loader.load(cfg_path)
      assert Loader.get_value("temp_key") == "temp_value"

      Writer.delete_value("temp_key")
      Loader.load(cfg_path)
      assert Loader.get_value("temp_key") == nil
    end
  end

  describe "regression: consecutive writes without explicit reload" do
    test "consecutive writes stay in the originally loaded file", %{cfg_path: cfg_path} do
      ensure_writer_started()

      unique_timeout = "writer_timeout_#{System.unique_integer([:positive])}"

      # First write
      assert :ok = Writer.set_value("model", "first_write")
      # Second write WITHOUT calling Loader.load/1 in between
      assert :ok = Writer.set_value("timeout", unique_timeout)

      # Both writes should be in the originally loaded file
      content = File.read!(cfg_path)
      assert content =~ "first_write", "Expected first_write in #{cfg_path}"
      assert content =~ unique_timeout, "Expected timeout=#{unique_timeout} in #{cfg_path}"

      # Default config file should NOT contain our test values
      default_path = CodePuppyControl.Config.Paths.config_file()

      if File.exists?(default_path) do
        default_content = File.read!(default_path)

        refute default_content =~ "first_write",
               "Test value leaked into default config at #{default_path}"

        refute default_content =~ unique_timeout,
               "Test value leaked into default config at #{default_path}"
      end
    end
  end

  describe "roundtrip" do
    test "set then get returns same value", %{cfg_path: cfg_path} do
      ensure_writer_started()

      for {key, value} <- [
            {"model", "gpt-5"},
            {"yolo_mode", "false"},
            {"custom_key", "hello world"}
          ] do
        Writer.set_value(key, value)
        Loader.load(cfg_path)
        assert Loader.get_value(key) == value, "Roundtrip failed for #{key}"
      end
    end
  end

  defp ensure_writer_started do
    case GenServer.whereis(Writer) do
      nil ->
        {:ok, _} = Writer.start_link()
        :ok

      _pid ->
        :ok
    end
  end
end
