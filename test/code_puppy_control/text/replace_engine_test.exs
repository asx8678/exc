defmodule CodePuppyControl.Text.ReplaceEngineTest do
  @moduledoc """
  Comprehensive tests for CodePuppyControl.Text.ReplaceEngine.

  All 17 test cases ported from the Rust implementation (replace_engine.rs)
  to verify exact behavior parity.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Text.ReplaceEngine

  # Match the Rust fuzzy threshold constant
  @fuzzy_threshold 0.95

  describe "exact match tests" do
    test "exact_match_single: single replacement works" do
      content = "hello world\nfoo bar\n"
      replacements = [{"world", "universe"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified == "hello universe\nfoo bar\n"
      assert diff != ""
      assert jw_score == nil
    end

    test "exact_match_multiple: multiple replacements work" do
      content = "hello world\nfoo bar\nbaz qux\n"
      replacements = [{"world", "universe"}, {"foo", "FOO"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified == "hello universe\nFOO bar\nbaz qux\n"
      assert diff != ""
      assert jw_score == nil
    end

    test "exact_match_only_first_occurrence: only first occurrence is replaced" do
      content = "foo foo foo\n"
      replacements = [{"foo", "bar"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified == "bar foo foo\n"
      assert diff != ""
      assert jw_score == nil
    end
  end

  describe "fuzzy match tests" do
    test "fuzzy_match_close_but_not_exact: similar text matches with fuzzy" do
      content = "def foo():\n    pass\ndef bar():\n    return 1\n"
      replacements = [{"def baz():", "def qux():"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert jw_score >= @fuzzy_threshold
      assert modified =~ "def qux():"
      refute modified =~ "def bar():"
      assert diff != ""
    end

    test "fuzzy_match_fails_below_threshold: dissimilar text fails fuzzy match" do
      content = "completely different text\nthat has no similarity\n"
      replacements = [{"xyz123-nomatch", "replacement"}]

      assert {:error, %{reason: reason, jw_score: jw_score, original: original}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert jw_score < @fuzzy_threshold
      assert reason =~ "JW"
      assert reason =~ "0.95"
      assert original == content
    end

    test "fuzzy_single_line: single line fuzzy match works" do
      content = "def foo():\n    pass\ndef bar():\n    return 1\n"
      replacements = [{"def baz():", "def qux():"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert jw_score >= @fuzzy_threshold
      assert modified =~ "def qux():"
      refute modified =~ "def bar():"
      assert diff != ""
    end
  end

  describe "edge case tests" do
    test "empty_replacements: empty list returns unchanged content" do
      content = "hello world\n"
      replacements = []

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified == content
      assert diff == ""
      assert jw_score == nil
    end

    test "empty_content: empty content with replacements fails" do
      content = ""
      replacements = [{"foo", "bar"}]

      assert {:error, %{reason: _reason, jw_score: jw_score, original: original}} =
               ReplaceEngine.replace_in_content(content, replacements)

      # Empty content has no lines, so fuzzy match returns 0.0
      assert jw_score == 0.0
      assert original == ""
    end

    test "trailing_newline_preserved: trailing newline is preserved when present" do
      content = "line1\nline2\n"
      replacements = [{"line1", "LINE1"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert String.ends_with?(modified, "\n"), "Trailing newline should be preserved"
      assert modified == "LINE1\nline2\n"
      assert diff != ""
      assert jw_score == nil
    end

    test "no_trailing_newline_added_if_not_present: no newline added when not present" do
      content = "line1\nline2"
      replacements = [{"line1", "LINE1"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      refute String.ends_with?(modified, "\n"), "Should not add trailing newline"
      assert modified == "LINE1\nline2"
      assert diff != ""
      assert jw_score == nil
    end

    test "empty_old_str_skipped: empty old_str is ignored" do
      content = "hello world\n"
      replacements = [{"", "ignored"}, {"world", "universe"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified == "hello universe\n"
      assert diff != ""
      assert jw_score == nil
    end
  end

  describe "multiline and mixed tests" do
    test "fuzzy_multiline_replacement: multiline text replacement works" do
      content = "def func():\n    x = 1\n    return x\n"
      replacements = [{"    x = 1\n    return x", "    y = 2\n    return y"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      # Exact multiline match
      assert jw_score == nil
      assert modified =~ "y = 2"
      assert diff != ""
    end

    test "mixed_exact_and_fuzzy: combines exact and fuzzy matches" do
      content = "hello world\ndef bar():\n    pass\n"
      replacements = [{"world", "universe"}, {"def baz():", "def qux():"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified =~ "hello universe"
      assert modified =~ "def qux():"
      refute modified =~ "def bar():"
      # jw_score is the last fuzzy match score (from the second replacement)
      assert jw_score >= @fuzzy_threshold
      assert diff != ""
    end

    test "fuzzy_then_exact: fuzzy match followed by exact match works" do
      content = "hello world\ndef baz():\n    pass\n"
      replacements = [{"def bar():", "def qux():"}, {"world", "universe"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified =~ "hello universe"
      assert modified =~ "def qux():"
      refute modified =~ "def baz():"
      # The fuzzy match happens first, so jw_score is from that match
      assert jw_score >= @fuzzy_threshold
      assert diff != ""
    end
  end

  describe "diff and behavior tests" do
    test "diff_format: diff contains expected markers" do
      content = "line1\nline2\nline3\n"
      replacements = [{"line2", "MODIFIED"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified =~ "MODIFIED"
      assert diff =~ "--- original"
      assert diff =~ "+++ modified"
      assert diff =~ "-line2"
      assert diff =~ "+MODIFIED"
      assert diff =~ "@@"
      assert jw_score == nil
    end

    test "no_changes_when_replacement_same: same replacement results in no diff" do
      content = "hello world\n"
      replacements = [{"world", "world"}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert modified == content
      assert diff == ""
      assert jw_score == nil
    end

    test "empty_new_str_fuzzy_deletion: empty new_str deletes fuzzy-matched content" do
      content = "def foo():\n    pass\ndef bar():\n    return 1\n"
      replacements = [{"def baz():", ""}]

      assert {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} =
               ReplaceEngine.replace_in_content(content, replacements)

      assert jw_score >= @fuzzy_threshold
      refute modified =~ "def bar():"
      assert modified =~ "def foo():"
      assert modified =~ "return 1"
      assert diff != ""
    end
  end
end
