defmodule CodePuppyControl.Config.TUITest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Loader, TUI}

  @tmp_dir System.tmp_dir!()
  @test_cfg Path.join(@tmp_dir, "tui_test_#{:erlang.unique_integer([:positive])}.cfg")

  setup do
    File.write!(@test_cfg, "[puppy]\n")
    Loader.load(@test_cfg)

    on_exit(fn ->
      File.rm(@test_cfg)
      Loader.invalidate()
    end)

    :ok
  end

  describe "banner_color/1" do
    test "returns default for known banners" do
      assert TUI.banner_color("thinking") == "deep_sky_blue4"
      assert TUI.banner_color("agent_response") == "medium_purple4"
    end

    test "returns blue for unknown banners" do
      assert TUI.banner_color("nonexistent") == "blue"
    end

    test "returns configured override" do
      File.write!(@test_cfg, "[puppy]\nbanner_color_thinking = red\n")
      Loader.load(@test_cfg)

      assert TUI.banner_color("thinking") == "red"
    end
  end

  describe "all_banner_colors/0" do
    test "returns map with all known banners" do
      colors = TUI.all_banner_colors()
      assert is_map(colors)
      assert Map.has_key?(colors, "thinking")
      assert Map.has_key?(colors, "agent_response")
      assert Map.has_key?(colors, "shell_command")
    end
  end

  describe "diff_addition_color/0" do
    test "returns default green" do
      assert TUI.diff_addition_color() == "#0b1f0b"
    end

    test "returns configured color" do
      File.write!(@test_cfg, "[puppy]\nhighlight_addition_color = bright_green\n")
      Loader.load(@test_cfg)

      assert TUI.diff_addition_color() == "bright_green"
    end
  end

  describe "diff_deletion_color/0" do
    test "returns default wine" do
      assert TUI.diff_deletion_color() == "#390e1a"
    end
  end

  describe "suppress_thinking?/0" do
    test "defaults to false" do
      assert TUI.suppress_thinking?() == false
    end

    test "respects config value" do
      File.write!(@test_cfg, "[puppy]\nsuppress_thinking_messages = true\n")
      Loader.load(@test_cfg)

      assert TUI.suppress_thinking?() == true
    end
  end

  describe "suppress_informational?/0" do
    test "defaults to false" do
      assert TUI.suppress_informational?() == false
    end
  end

  describe "grep_output_verbose?/0" do
    test "defaults to false" do
      assert TUI.grep_output_verbose?() == false
    end
  end

  describe "diff_context_lines/0" do
    test "defaults to 6" do
      assert TUI.diff_context_lines() == 6
    end

    test "returns configured value" do
      File.write!(@test_cfg, "[puppy]\ndiff_context_lines = 10\n")
      Loader.load(@test_cfg)

      assert TUI.diff_context_lines() == 10
    end

    test "clamps to max 50" do
      File.write!(@test_cfg, "[puppy]\ndiff_context_lines = 100\n")
      Loader.load(@test_cfg)

      # Out of range, returns default
      assert TUI.diff_context_lines() == 6
    end
  end

  describe "auto_save_session?/0" do
    test "defaults to true" do
      assert TUI.auto_save_session?() == true
    end
  end

  describe "max_saved_sessions/0" do
    test "defaults to 20" do
      assert TUI.max_saved_sessions() == 20
    end
  end

  describe "default_banner_colors/0" do
    test "returns a map" do
      colors = TUI.default_banner_colors()
      assert is_map(colors)
      assert map_size(colors) > 10
    end
  end
end
