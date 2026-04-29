defmodule CodePuppyControl.TUI.ThemeTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Theme

  # ── color/1 ─────────────────────────────────────────────────────────────

  describe "color/1" do
    test "returns known semantic colours" do
      assert Theme.color(:brand) == :cyan
      assert Theme.color(:success) == :green
      assert Theme.color(:error) == :red
      assert Theme.color(:warning) == :yellow
      assert Theme.color(:thinking) == :faint
      assert Theme.color(:keyword) == :magenta
      assert Theme.color(:string) == :green
      assert Theme.color(:comment) == :faint
    end

    test "returns :default_color for unknown keys" do
      assert Theme.color(:nonexistent_key_xyz) == :default_color
      assert Theme.color(:foo_bar) == :default_color
    end

    test "all colors are valid Owl.Data.tag atoms" do
      # Every value in the colour map should be an atom
      Theme.all_colors()
      |> Map.values()
      |> Enum.each(fn c ->
        assert is_atom(c), "Expected atom, got: #{inspect(c)}"
      end)
    end
  end

  # ── icon/1 ──────────────────────────────────────────────────────────────

  describe "icon/1" do
    test "returns known icons as strings" do
      assert Theme.icon(:puppy) == "🐶"
      assert Theme.icon(:success) == "✔"
      assert Theme.icon(:error) == "✖"
      assert Theme.icon(:config) == "⚙️"
      assert Theme.icon(:help) == "❓"
    end

    test "returns bullet for unknown keys" do
      assert Theme.icon(:nonexistent) == "•"
    end

    test "all icons are non-empty strings" do
      Theme.all_icons()
      |> Map.values()
      |> Enum.each(fn icon ->
        assert is_binary(icon), "Expected string, got: #{inspect(icon)}"
        assert String.length(icon) > 0, "Icon should not be empty"
      end)
    end
  end

  # ── tag/2 ────────────────────────────────────────────────────────────────

  describe "tag/2" do
    test "tags text with a semantic colour" do
      result = Theme.tag("Hello", :brand)
      assert result == Owl.Data.tag("Hello", :cyan)
    end

    test "tags with unknown key uses :default_color" do
      result = Theme.tag("Hello", :unknown_key)
      assert result == Owl.Data.tag("Hello", :default_color)
    end
  end

  # ── brand/1 ─────────────────────────────────────────────────────────────

  describe "brand/1" do
    test "produces tagged text with puppy icon prefix" do
      result = Theme.brand("Welcome")
      assert result == Owl.Data.tag("🐶 Welcome", :cyan)
    end
  end

  # ── separator/1 ─────────────────────────────────────────────────────────

  describe "separator/1" do
    test "returns a faint line at default width" do
      result = Theme.separator()
      # Should be a tagged string of dashes
      assert result == Owl.Data.tag(String.duplicate("─", 60), :faint)
    end

    test "respects custom width" do
      result = Theme.separator(width: 20)
      assert result == Owl.Data.tag(String.duplicate("─", 20), :faint)
    end

    test "respects custom style" do
      result = Theme.separator(style: :cyan)
      assert result == Owl.Data.tag(String.duplicate("─", 60), :cyan)
    end
  end

  # ── Layout constants ───────────────────────────────────────────────────

  describe "layout constants" do
    test "min_box_width returns a positive integer" do
      w = Theme.min_box_width()
      assert is_integer(w)
      assert w > 0
    end

    test "default_bar_width returns a positive integer" do
      w = Theme.default_bar_width()
      assert is_integer(w)
      assert w > 0
    end
  end

  # ── tool_banner/1 ────────────────────────────────────────────────────────

  describe "tool_banner/1" do
    test "returns Owl.Data for known tools" do
      banner = Theme.tool_banner("read_file")
      # Should produce tagged content (a tuple/list), not a plain string
      refute is_binary(banner)
    end

    test "handles unknown tools gracefully" do
      banner = Theme.tool_banner("some_unknown_tool")
      refute is_binary(banner)
    end

    test "all standard tool names produce non-crashing banners" do
      tools = ~w(read_file write_file replace_in_file create_file delete_file
                delete_snippet list_files grep run_shell_command agent_run mcp_tool_call)

      Enum.each(tools, fn tool ->
        result = Theme.tool_banner(tool)
        refute result == nil
      end)
    end
  end
end
