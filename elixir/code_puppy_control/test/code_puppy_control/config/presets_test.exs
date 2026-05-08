defmodule CodePuppyControl.Config.PresetsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Loader, Presets, Writer}

  @tmp_dir System.tmp_dir!()
  @test_cfg_dir Path.join(@tmp_dir, "presets_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@test_cfg_dir)
    test_cfg = Path.join(@test_cfg_dir, "puppy.cfg")

    # Write a default config that matches the "semi" preset
    File.write!(test_cfg, """
    [puppy]
    yolo_mode = false
    enable_pack_agents = false
    enable_universal_constructor = true
    safety_permission_level = medium
    compaction_strategy = summarization
    enable_streaming = true
    """)

    Loader.load(test_cfg)

    # Start Writer if not already running
    case GenServer.whereis(Writer) do
      nil -> {:ok, _} = Writer.start_link()
      _pid -> :ok
    end

    on_exit(fn ->
      Loader.invalidate()
      File.rm_rf!(@test_cfg_dir)
    end)

    {:ok, cfg_path: test_cfg}
  end

  describe "list_presets/0" do
    test "returns four built-in presets" do
      presets = Presets.list_presets()
      assert length(presets) == 4
    end

    test "presets are sorted by name" do
      names = Presets.list_presets() |> Enum.map(& &1.name)
      assert names == ["basic", "full", "pack", "semi"]
    end

    test "each preset has required fields" do
      for preset <- Presets.list_presets() do
        assert Map.has_key?(preset, :name)
        assert Map.has_key?(preset, :display_name)
        assert Map.has_key?(preset, :description)
        assert Map.has_key?(preset, :values)
        assert is_map(preset.values)
      end
    end

    test "each preset has exactly 6 config keys" do
      for preset <- Presets.list_presets() do
        assert map_size(preset.values) == 6,
               "Preset '#{preset.name}' should have 6 keys, got #{map_size(preset.values)}"
      end
    end
  end

  describe "get_preset/1" do
    test "returns preset by name" do
      assert %{} = Presets.get_preset("basic")
      assert Presets.get_preset("basic").display_name == "Basic"
      assert Presets.get_preset("semi").display_name == "Semi"
      assert Presets.get_preset("full").display_name == "Full"
      assert Presets.get_preset("pack").display_name == "Pack"
    end

    test "is case-insensitive" do
      assert Presets.get_preset("BASIC") != nil
      assert Presets.get_preset("Full") != nil
      assert Presets.get_preset("PACK") != nil
    end

    test "returns nil for unknown preset" do
      assert Presets.get_preset("nonexistent") == nil
      assert Presets.get_preset("") == nil
    end
  end

  describe "preset values — canonical parity" do
    test "basic preset values match canonical preset definitions" do
      basic = Presets.get_preset("basic")
      assert basic.values["yolo_mode"] == "false"
      assert basic.values["enable_pack_agents"] == "false"
      assert basic.values["enable_universal_constructor"] == "false"
      assert basic.values["safety_permission_level"] == "medium"
      assert basic.values["compaction_strategy"] == "summarization"
      assert basic.values["enable_streaming"] == "true"
    end

    test "semi preset values match canonical preset definitions" do
      semi = Presets.get_preset("semi")
      assert semi.values["yolo_mode"] == "false"
      assert semi.values["enable_pack_agents"] == "false"
      assert semi.values["enable_universal_constructor"] == "true"
      assert semi.values["safety_permission_level"] == "medium"
      assert semi.values["compaction_strategy"] == "summarization"
      assert semi.values["enable_streaming"] == "true"
    end

    test "full preset values match canonical preset definitions" do
      full = Presets.get_preset("full")
      assert full.values["yolo_mode"] == "true"
      assert full.values["enable_pack_agents"] == "true"
      assert full.values["enable_universal_constructor"] == "true"
      assert full.values["safety_permission_level"] == "low"
      assert full.values["compaction_strategy"] == "summarization"
      assert full.values["enable_streaming"] == "true"
    end

    test "pack preset values match canonical preset definitions" do
      pack = Presets.get_preset("pack")
      assert pack.values["yolo_mode"] == "false"
      assert pack.values["enable_pack_agents"] == "true"
      assert pack.values["enable_universal_constructor"] == "true"
      assert pack.values["safety_permission_level"] == "medium"
      assert pack.values["compaction_strategy"] == "summarization"
      assert pack.values["enable_streaming"] == "true"
    end
  end

  describe "apply_preset/1" do
    test "applies basic preset and returns :ok", %{cfg_path: cfg_path} do
      assert :ok = Presets.apply_preset("basic")
      Loader.load(cfg_path)
      assert Loader.get_value("yolo_mode") == "false"
      assert Loader.get_value("enable_pack_agents") == "false"
      assert Loader.get_value("enable_universal_constructor") == "false"
      assert Loader.get_value("safety_permission_level") == "medium"
    end

    test "applies full preset and returns :ok", %{cfg_path: cfg_path} do
      assert :ok = Presets.apply_preset("full")
      Loader.load(cfg_path)
      assert Loader.get_value("yolo_mode") == "true"
      assert Loader.get_value("enable_pack_agents") == "true"
      assert Loader.get_value("enable_universal_constructor") == "true"
      assert Loader.get_value("safety_permission_level") == "low"
    end

    test "applies pack preset and returns :ok", %{cfg_path: cfg_path} do
      assert :ok = Presets.apply_preset("pack")
      Loader.load(cfg_path)
      assert Loader.get_value("enable_pack_agents") == "true"
      assert Loader.get_value("yolo_mode") == "false"
    end

    test "returns error for unknown preset" do
      assert {:error, :not_found} = Presets.apply_preset("nonexistent")
    end

    test "is case-insensitive", %{cfg_path: cfg_path} do
      assert :ok = Presets.apply_preset("BASIC")
      Loader.load(cfg_path)
      assert Loader.get_value("yolo_mode") == "false"
    end
  end

  describe "current_preset_guess/0" do
    test "returns 'semi' when config matches semi preset", %{cfg_path: cfg_path} do
      # Setup wrote semi-matching config; just ensure Loader is fresh
      Loader.load(cfg_path)
      assert Presets.current_preset_guess() == "semi"
    end

    test "returns 'basic' after applying basic preset", %{cfg_path: cfg_path} do
      Presets.apply_preset("basic")
      Loader.load(cfg_path)
      assert Presets.current_preset_guess() == "basic"
    end

    test "returns 'full' after applying full preset", %{cfg_path: cfg_path} do
      Presets.apply_preset("full")
      Loader.load(cfg_path)
      assert Presets.current_preset_guess() == "full"
    end

    test "returns 'pack' after applying pack preset", %{cfg_path: cfg_path} do
      Presets.apply_preset("pack")
      Loader.load(cfg_path)
      assert Presets.current_preset_guess() == "pack"
    end

    test "returns nil for custom config", %{cfg_path: cfg_path} do
      # Write a config that doesn't match any preset
      File.write!(cfg_path, """
      [puppy]
      yolo_mode = false
      enable_pack_agents = false
      enable_universal_constructor = false
      safety_permission_level = high
      compaction_strategy = summarization
      enable_streaming = true
      """)

      Loader.load(cfg_path)
      assert Presets.current_preset_guess() == nil
    end
  end
end
