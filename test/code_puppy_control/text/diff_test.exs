defmodule CodePuppyControl.Text.DiffTest do
  @moduledoc """
  Tests for unified diff generation.

  Ported from Rust code_puppy_core/src/unified_diff.rs tests.
  """

  use ExUnit.Case

  alias CodePuppyControl.Text.Diff

  # Helper functions

  defp concat(parts) do
    parts
    |> Enum.join("")
    |> String.trim_trailing("\n")
    |> Kernel.<>("\n")
  end

  defp concat_line_range(start_line, end_line) do
    start_line..end_line
    |> Enum.map(&"line #{&1}\n")
    |> Enum.join("")
  end

  defp count_substring(string, substring) do
    string
    |> String.split(substring, trim: true)
    |> length()
    |> Kernel.-(1)
    |> max(0)
  end

  # ============================================================================
  # Basic functionality tests
  # ============================================================================

  describe "identical strings" do
    test "returns empty string for identical inputs" do
      old = "line 1\nline 2\nline 3"
      new = "line 1\nline 2\nline 3"
      result = Diff.unified_diff(old, new, from_file: "a/file.txt", to_file: "b/file.txt")
      assert result == ""
    end

    test "returns empty string for empty strings" do
      assert Diff.unified_diff("", "", from_file: "a", to_file: "b") == ""
    end

    test "handles content without trailing newline vs different content" do
      # Critical bug fix: split_lines used to drop content without trailing newline
      # unified_diff("hello", "world") would return "" (identical when they differ!)
      result = Diff.unified_diff("hello", "world", from_file: "a", to_file: "b")
      assert result =~ "--- a\n"
      assert result =~ "+++ b\n"
      assert result =~ "-hello"
      assert result =~ "+world"
    end

    test "handles content without trailing newline in multi-line" do
      # unified_diff("a\nb", "a\nchanged") used to silently ignore changes
      result = Diff.unified_diff("a\nb", "a\nchanged", from_file: "a", to_file: "b")
      assert result =~ "--- a\n"
      assert result =~ "+++ b\n"
      assert result =~ "-b"
      assert result =~ "+changed"
    end
  end

  describe "single line changes" do
    test "single line change exact" do
      old = "line 1\nline 2\nline 3\n"
      new = "line 1\nmodified line 2\nline 3\n"

      result = Diff.unified_diff(old, new, from_file: "a/file.txt", to_file: "b/file.txt")

      expected =
        concat([
          "--- a/file.txt\n",
          "+++ b/file.txt\n",
          "@@ -1,3 +1,3 @@\n",
          " line 1\n",
          "-line 2\n",
          "+modified line 2\n",
          " line 3\n"
        ])

      assert result == expected
    end
  end

  describe "additions" do
    test "addition at end exact" do
      old = "line 1\nline 2\n"
      new = "line 1\nline 2\nline 3\n"

      result = Diff.unified_diff(old, new, from_file: "a/file.txt", to_file: "b/file.txt")

      expected =
        concat([
          "--- a/file.txt\n",
          "+++ b/file.txt\n",
          "@@ -1,2 +1,3 @@\n",
          " line 1\n",
          " line 2\n",
          "+line 3\n"
        ])

      assert result == expected
    end

    test "addition at beginning" do
      old = "line 2\nline 3\n"
      new = "line 1\nline 2\nline 3\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "+line 1\n"
      assert result =~ " line 2\n"
      assert result =~ " line 3\n"
    end

    test "addition in middle" do
      old = "line 1\nline 3\n"
      new = "line 1\nline 2\nline 3\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -1,2 +1,3 @@\n",
          " line 1\n",
          "+line 2\n",
          " line 3\n"
        ])

      assert result == expected
    end
  end

  describe "deletions" do
    test "deletion from middle exact" do
      old = "line 1\nline 2\nline 3\n"
      new = "line 1\nline 3\n"

      result = Diff.unified_diff(old, new, from_file: "a/file.txt", to_file: "b/file.txt")

      expected =
        concat([
          "--- a/file.txt\n",
          "+++ b/file.txt\n",
          "@@ -1,3 +1,2 @@\n",
          " line 1\n",
          "-line 2\n",
          " line 3\n"
        ])

      assert result == expected
    end

    test "deletion of first line" do
      old = "line 1\nline 2\nline 3\n"
      new = "line 2\nline 3\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -1,3 +1,2 @@\n",
          "-line 1\n",
          " line 2\n",
          " line 3\n"
        ])

      assert result == expected
    end

    test "deletion of last line" do
      old = "line 1\nline 2\nline 3\n"
      new = "line 1\nline 2\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -1,3 +1,2 @@\n",
          " line 1\n",
          " line 2\n",
          "-line 3\n"
        ])

      assert result == expected
    end
  end

  describe "empty file handling" do
    test "empty old (adding to new file) exact" do
      old = ""
      new = "line 1\nline 2\n"

      result = Diff.unified_diff(old, new, from_file: "a/file.txt", to_file: "b/file.txt")

      expected =
        concat([
          "--- a/file.txt\n",
          "+++ b/file.txt\n",
          "@@ -0,0 +1,2 @@\n",
          "+line 1\n",
          "+line 2\n"
        ])

      assert result == expected
    end

    test "empty new (deleting all) exact" do
      old = "line 1\nline 2\n"
      new = ""

      result = Diff.unified_diff(old, new, from_file: "a/file.txt", to_file: "b/file.txt")

      expected =
        concat([
          "--- a/file.txt\n",
          "+++ b/file.txt\n",
          "@@ -1,2 +0,0 @@\n",
          "-line 1\n",
          "-line 2\n"
        ])

      assert result == expected
    end

    test "single line added to empty" do
      old = ""
      new = "hello\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -0,0 +1,1 @@\n",
          "+hello\n"
        ])

      assert result == expected
    end

    test "single line deleted to empty" do
      old = "hello\n"
      new = ""

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -1,1 +0,0 @@\n",
          "-hello\n"
        ])

      assert result == expected
    end
  end

  describe "complete replacement" do
    test "completely different exact" do
      old = "aaa\nbbb\nccc\n"
      new = "xxx\nyyy\nzzz\n"

      result = Diff.unified_diff(old, new, from_file: "a/file.txt", to_file: "b/file.txt")

      expected =
        concat([
          "--- a/file.txt\n",
          "+++ b/file.txt\n",
          "@@ -1,3 +1,3 @@\n",
          "-aaa\n",
          "-bbb\n",
          "-ccc\n",
          "+xxx\n",
          "+yyy\n",
          "+zzz\n"
        ])

      assert result == expected
    end
  end

  describe "multi-hunk scenarios" do
    test "multi-hunk produces separate hunks" do
      # Lines 1-20, change line 3 and line 17
      # With context=3, gap of 14 lines > 6 (2*context), so separate hunks
      old = concat_line_range(1, 20)

      new =
        "line 1\nline 2\nMODIFIED 3\n" <>
          concat_line_range(4, 15) <>
          "line 16\nMODIFIED 17\n" <>
          concat_line_range(18, 20)

      result = Diff.unified_diff(old, new, from_file: "a/file.txt", to_file: "b/file.txt")

      # Count hunk headers - should be exactly 2
      hunk_count = count_substring(result, "@@ -")

      assert hunk_count == 2,
             "Expected 2 separate hunks, but got #{hunk_count}. Output:\n#{result}"

      # Verify first hunk contains the first change
      assert result =~ "-line 3\n", "First hunk should show removal of line 3"
      assert result =~ "+MODIFIED 3\n", "First hunk should show addition of MODIFIED 3"

      # Verify second hunk contains the second change
      assert result =~ "-line 17\n", "Second hunk should show removal of line 17"
      assert result =~ "+MODIFIED 17\n", "Second hunk should show addition of MODIFIED 17"
    end

    test "nearby changes merged into single hunk" do
      # Changes at lines 3 and 7 with gap of 4 lines
      # With context=3, gap of 4 <= 6 (2*context), so single hunk
      old = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\n"
      new = "line 1\nline 2\nMODIFIED 3\nline 4\nline 5\nline 6\nMODIFIED 7\nline 8\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      hunk_count = count_substring(result, "@@ -")
      assert hunk_count == 1, "Expected 1 merged hunk, but got #{hunk_count}. Output:\n#{result}"
    end
  end

  describe "format compatibility" do
    test "parity with standard unified diff format" do
      old = "first\nsecond\nthird\n"
      new = "first\nmodified\nthird\n"

      result = Diff.unified_diff(old, new, from_file: "a/test.rs", to_file: "b/test.rs")

      expected =
        concat([
          "--- a/test.rs\n",
          "+++ b/test.rs\n",
          "@@ -1,3 +1,3 @@\n",
          " first\n",
          "-second\n",
          "+modified\n",
          " third\n"
        ])

      assert result == expected, "Output should match standard unified diff format exactly"
    end
  end

  describe "context lines parameter" do
    test "context_lines parameter respected" do
      old = "a\nb\nc\nd\ne\n"
      new = "a\nB\nc\nd\ne\n"

      result = Diff.unified_diff(old, new, context_lines: 1, from_file: "old", to_file: "new")

      assert result =~ "@@"
      assert result =~ "-b\n"
      assert result =~ "+B\n"
      # With only 1 context line, we shouldn't see 'a' or 'c' as context
      # Actually let's verify the hunk header format
      assert result =~ ~r/@@ -\d+,\d+ \+\d+,\d+ @@/
    end

    test "context_lines: 0 shows only changed lines" do
      result = Diff.unified_diff("a\nb\nc\nd\ne\n", "a\nB\nc\nd\ne\n", context_lines: 0)

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -2,1 +2,1 @@\n",
          "-b\n",
          "+B\n"
        ])

      assert result == expected
    end

    test "context_lines: 1 shows 1 line of context" do
      result = Diff.unified_diff("a\nb\nc\nd\ne\n", "a\nB\nc\nd\ne\n", context_lines: 1)

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -1,3 +1,3 @@\n",
          " a\n",
          "-b\n",
          "+B\n",
          " c\n"
        ])

      assert result == expected
    end

    test "context_lines: 2 shows 2 lines of context" do
      result = Diff.unified_diff("a\nb\nc\nd\ne\n", "a\nB\nc\nd\ne\n", context_lines: 2)

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -1,4 +1,4 @@\n",
          " a\n",
          "-b\n",
          "+B\n",
          " c\n",
          " d\n"
        ])

      assert result == expected
    end

    test "context_lines=0 (minimal context)" do
      old = "a\nb\nc\n"
      new = "a\nB\nc\n"

      result = Diff.unified_diff(old, new, context_lines: 0, from_file: "a", to_file: "b")

      assert result =~ "@@"
      assert result =~ "-b\n"
      assert result =~ "+B\n"
    end
  end

  describe "option handling" do
    test "default file labels" do
      result = Diff.unified_diff("a\n", "b\n")
      assert result =~ "--- a\n"
      assert result =~ "+++ b\n"
    end

    test "custom file labels" do
      result = Diff.unified_diff("a\n", "b\n", from_file: "original.txt", to_file: "modified.txt")
      assert result =~ "--- original.txt\n"
      assert result =~ "+++ modified.txt\n"
    end

    test "default context_lines is 3" do
      # Changes at line 8 and 16 (gap of 8)
      # With default context=3: gap 8 > 2*3=6, so should be 2 hunks
      old =
        "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nMODIFIED 8\n" <>
          "line 9\nline 10\nline 11\nline 12\nline 13\nline 14\nline 15\nMODIFIED 16\n" <>
          "line 17\n"

      new =
        "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nCHANGED 8\n" <>
          "line 9\nline 10\nline 11\nline 12\nline 13\nline 14\nline 15\nCHANGED 16\n" <>
          "line 17\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      # With default context_lines=3, these changes are 8 lines apart
      # which is > 2*3 = 6, so they should be separate hunks
      hunk_count = count_substring(result, "@@ -")
      assert hunk_count == 2
    end
  end

  describe "edge cases" do
    test "single line files" do
      old = "hello\n"
      new = "world\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      expected =
        concat([
          "--- a\n",
          "+++ b\n",
          "@@ -1,1 +1,1 @@\n",
          "-hello\n",
          "+world\n"
        ])

      assert result == expected
    end

    test "no trailing newline in original" do
      # No trailing newline
      old = "hello"
      # Has trailing newline
      new = "hello\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "--- a\n"
      assert result =~ "+++ b\n"
    end

    test "no trailing newline in modified" do
      old = "hello\n"
      # No trailing newline
      new = "hello"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "--- a\n"
      assert result =~ "+++ b\n"
    end

    test "lines with spaces" do
      old = "  indented\n"
      new = "    more indented\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "-  indented\n"
      assert result =~ "+    more indented\n"
    end

    test "empty lines" do
      old = "line 1\n\nline 3\n"
      new = "line 1\nline 2\n\nline 3\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "+line 2\n"
    end

    test "unicode content" do
      old = "日本語\n한국어\n"
      new = "日本語\n中文\n한국어\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "--- a\n"
      assert result =~ "+++ b\n"
      assert result =~ " 日本語"
      assert result =~ "+中文\n"
      assert result =~ " 한국어"
    end

    test "emoji content" do
      old = "🎉 party\n🚀 rocket\n"
      new = "🎉 party\n🌟 star\n🚀 rocket\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "+🌟 star\n"
      assert result =~ " 🎉 party\n"
      assert result =~ " 🚀 rocket\n"
    end
  end

  describe "multiple changes" do
    test "multiple additions" do
      old = "line 1\nline 4\n"
      new = "line 1\nline 2\nline 3\nline 4\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "+line 2\n"
      assert result =~ "+line 3\n"
    end

    test "multiple deletions" do
      old = "line 1\nline 2\nline 3\nline 4\n"
      new = "line 1\nline 4\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "-line 2\n"
      assert result =~ "-line 3\n"
    end

    test "mixed additions and deletions" do
      old = "keep 1\ndelete\nkeep 2\n"
      new = "keep 1\ninsert\nkeep 2\n"

      result = Diff.unified_diff(old, new, from_file: "a", to_file: "b")

      assert result =~ "-delete\n"
      assert result =~ "+insert\n"
      assert result =~ " keep 1\n"
      assert result =~ " keep 2\n"
    end
  end
end
