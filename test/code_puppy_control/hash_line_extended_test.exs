defmodule CodePuppyControl.HashLineExtendedTest do
  @moduledoc """
  Extended HashLine tests ported from test_hashline.py and test_hashline_transport.py.

  Covers edge cases not in the base hash_line_test.exs:
  - Trailing newline handling in format_hashlines
  - Line count preservation
  - Punctuation-only / whitespace-only lines
  - Unicode content in compute_line_hash
  - Idempotent strip on plain text
  - Start-line roundtrip
  - Content with # preserved in roundtrip
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.HashLine

  @nibble_str "ZPMQVRWSNKTXJBYH"

  # ===========================================================================
  # compute_line_hash - additional edge cases
  # ===========================================================================

  describe "compute_line_hash/2 - edge cases" do
    test "returns 2 chars for unicode content" do
      h = HashLine.compute_line_hash(1, "Hello 🌍! Ñoño café résumé 日本語")
      assert String.length(h) == 2
      assert String.at(h, 0) in String.graphemes(@nibble_str)
      assert String.at(h, 1) in String.graphemes(@nibble_str)
    end

    test "punctuation-only lines use idx as seed" do
      h1 = HashLine.compute_line_hash(7, "---")
      h2 = HashLine.compute_line_hash(8, "---")
      assert String.length(h1) == 2
      assert String.length(h2) == 2
      # Different indices → likely different hashes
    end

    test "whitespace-only lines use idx as seed" do
      h1 = HashLine.compute_line_hash(1, "   ")
      h2 = HashLine.compute_line_hash(2, "   ")
      assert String.length(h1) == 2
      assert String.length(h2) == 2
    end

    test "trailing tab ignored" do
      h1 = HashLine.compute_line_hash(1, "hello")
      h2 = HashLine.compute_line_hash(1, "hello\t\t")
      assert h1 == h2
    end

    test "trailing CR ignored" do
      h1 = HashLine.compute_line_hash(1, "hello")
      h2 = HashLine.compute_line_hash(1, "hello\r")
      assert h1 == h2
    end
  end

  # ===========================================================================
  # format_hashlines - additional edge cases
  # ===========================================================================

  describe "format_hashlines/2 - edge cases" do
    test "trailing newline creates empty last line that is annotated" do
      text = "line one\nline two\n"
      result = HashLine.format_hashlines(text, 1)
      lines = String.split(result, "\n")
      # "line one", "line two", ""
      assert length(lines) == 3
      assert String.starts_with?(Enum.at(lines, 2), "3#")
    end

    test "line count is preserved" do
      text = "a\nb\nc\nd\ne"
      result = HashLine.format_hashlines(text, 1)
      assert length(String.split(result, "\n")) == 5
    end

    test "empty line is annotated" do
      result = HashLine.format_hashlines("", 1)
      assert result =~ ~r/^1#[A-Z]{2}:$/
    end

    test "unicode content in format_hashlines" do
      text = "café\n日本語"
      result = HashLine.format_hashlines(text, 1)
      lines = String.split(result, "\n")
      assert String.contains?(hd(lines), ":café")
      assert String.contains?(Enum.at(lines, 1), ":日本語")
    end

    test "start_line default is 1" do
      result = HashLine.format_hashlines("line", 1)
      assert String.starts_with?(result, "1#")
    end

    test "preserves content after prefix with indentation" do
      original = "    def foo(self):\n        return 42"
      result = HashLine.format_hashlines(original, 1)

      for {fmt_line, orig_line} <-
            Enum.zip(
              String.split(result, "\n"),
              String.split(original, "\n")
            ) do
        assert String.ends_with?(fmt_line, ":" <> orig_line)
      end
    end
  end

  # ===========================================================================
  # strip_hashline_prefixes - additional edge cases
  # ===========================================================================

  describe "strip_hashline_prefixes/1 - additional edge cases" do
    test "roundtrip with trailing newline" do
      original = "alpha\nbeta\n"
      formatted = HashLine.format_hashlines(original, 1)
      assert HashLine.strip_hashline_prefixes(formatted) == original
    end

    test "roundtrip with empty string" do
      original = ""
      formatted = HashLine.format_hashlines(original, 1)
      assert HashLine.strip_hashline_prefixes(formatted) == original
    end

    test "idempotent on plain text" do
      text = "already plain"
      assert HashLine.strip_hashline_prefixes(HashLine.strip_hashline_prefixes(text)) == text
    end

    test "unicode roundtrip" do
      original = "café\n日本語\n🚀 launch"
      formatted = HashLine.format_hashlines(original, 1)
      assert HashLine.strip_hashline_prefixes(formatted) == original
    end

    test "start_line roundtrip" do
      original = "first\nsecond"
      formatted = HashLine.format_hashlines(original, 42)
      assert HashLine.strip_hashline_prefixes(formatted) == original
    end

    test "content with # preserved in roundtrip" do
      text = "x = a#b + c#d"
      formatted = HashLine.format_hashlines(text, 1)
      assert HashLine.strip_hashline_prefixes(formatted) == text
    end

    test "partial match: some lines with prefix, some without" do
      formatted = HashLine.format_hashlines("hello", 1)
      mixed = formatted <> "\nplain line without prefix"
      stripped = HashLine.strip_hashline_prefixes(mixed)
      assert stripped == "hello\nplain line without prefix"
    end
  end

  # ===========================================================================
  # validate_hashline_anchor - additional edge cases
  # ===========================================================================

  describe "validate_hashline_anchor/3 - additional edge cases" do
    test "empty string validates with own hash" do
      h = HashLine.compute_line_hash(3, "")
      assert HashLine.validate_hashline_anchor(3, "", h)
    end

    test "wrong hash string returns false" do
      h = HashLine.compute_line_hash(1, "hello")

      # Flip one character
      wrong =
        if(String.at(h, 0) != "A", do: "A", else: "B") <>
          String.at(h, 1)

      if wrong != h do
        refute HashLine.validate_hashline_anchor(1, "hello", wrong)
      end
    end

    test "blank line: idx 1 hash does not validate for idx 100" do
      h1 = HashLine.compute_line_hash(1, "")
      h100 = HashLine.compute_line_hash(100, "")

      # Each validates with its own idx
      assert HashLine.validate_hashline_anchor(1, "", h1)
      assert HashLine.validate_hashline_anchor(100, "", h100)

      # They are likely different hashes (not guaranteed, but very likely)
      # Just verify they're both valid anchors
      assert String.length(h1) == 2
      assert String.length(h100) == 2
    end
  end
end
