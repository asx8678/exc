defmodule CodePuppyControl.Text.EOLWhitespaceTest do
  @moduledoc "Tests for EOL.strip_added_blank_lines — whitespace stripping."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Text.EOL

  describe "strip_added_blank_lines/2" do
    test "strips surplus leading blank lines" do
      original = "line1\nline2"
      updated = "\n\n\nline1\nline2"

      result = EOL.strip_added_blank_lines(original, updated)
      # Original had 0 leading blank lines, updated had 3 → strip 3
      assert result == "line1\nline2"
    end

    test "preserves original leading blank lines" do
      original = "\n\nline1\nline2"
      updated = "\n\nmodified line1\nline2"

      result = EOL.strip_added_blank_lines(original, updated)
      # Both have 2 leading blank lines → no change
      assert String.starts_with?(result, "\n\n")
    end

    test "strips surplus trailing blank lines" do
      original = "line1\nline2"
      updated = "line1\nline2\n\n\n"

      result = EOL.strip_added_blank_lines(original, updated)
      # Original had 0 trailing blank lines, updated had 3 → strip 3
      refute String.ends_with?(result, "\n\n\n")
    end

    test "preserves original trailing blank lines" do
      original = "line1\nline2\n\n"
      updated = "line1\nmodified\n\n"

      result = EOL.strip_added_blank_lines(original, updated)
      # Both have 2 trailing blank lines → no change
      assert String.ends_with?(result, "\n\n")
    end

    test "no change when blank line counts match" do
      original = "line1\nline2"
      updated = "modified1\nmodified2"

      result = EOL.strip_added_blank_lines(original, updated)
      assert result == updated
    end

    test "handles empty original" do
      original = ""
      updated = "\n\n\ncontent"

      result = EOL.strip_added_blank_lines(original, updated)
      # Original "" splits to [""], which counts as 1 blank line
      # So 3 - 1 = 2 surplus lines stripped, leaving 1
      assert result == "\ncontent"
    end

    test "handles both empty" do
      result = EOL.strip_added_blank_lines("", "")
      assert result == ""
    end

    test "handles whitespace-only blank lines" do
      # Lines with only spaces/tabs are considered blank
      original = "line1\nline2"
      updated = "   \n   \nline1\nline2"

      result = EOL.strip_added_blank_lines(original, updated)
      # Surplus whitespace-only lines should be stripped
      refute String.starts_with?(result, "   \n   \n")
    end
  end
end
