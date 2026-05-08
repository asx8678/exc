defmodule CodePuppyControl.Text.LineNumbersTest do
  @moduledoc """
  Tests for LineNumbers formatting module.

  Ported from `code_puppy_core/src/line_numbers.rs` tests.
  """

  use ExUnit.Case

  alias CodePuppyControl.Text.LineNumbers

  # ============================================================================
  # Basic functionality tests
  # ============================================================================

  describe "format_line_numbers/2" do
    test "simple content with two lines" do
      result = LineNumbers.format_line_numbers("hello\nworld")
      assert result == "     1\thello\n     2\tworld"
    end

    test "single line content" do
      result = LineNumbers.format_line_numbers("hello")
      assert result == "     1\thello"
    end

    test "start_line offset" do
      result = LineNumbers.format_line_numbers("hello\nworld", start_line: 10)
      assert result == "    10\thello\n    11\tworld"
    end

    test "empty content produces one empty line" do
      # Empty content produces one empty line numbered (like Python's split('\n'))
      result = LineNumbers.format_line_numbers("")
      assert result == "     1\t"
    end

    test "empty lines (just newlines)" do
      result = LineNumbers.format_line_numbers("\n\n")
      assert result == "     1\t\n     2\t\n     3\t"
    end

    test "trailing newline produces empty line at end" do
      # Content ending with \n should have an empty line numbered
      result = LineNumbers.format_line_numbers("hello\n")
      assert result == "     1\thello\n     2\t"
    end

    test "content with tabs" do
      result = LineNumbers.format_line_numbers("hello\tworld")
      assert result == "     1\thello\tworld"
    end

    test "custom line_number_width" do
      result = LineNumbers.format_line_numbers("hello", line_number_width: 4)
      assert result == "   1\thello"

      result = LineNumbers.format_line_numbers("hello", line_number_width: 8)
      assert result == "       1\thello"
    end
  end

  # ============================================================================
  # Long line continuation tests
  # ============================================================================

  describe "long line continuation" do
    test "long line splits into 3 chunks at 5000 char boundary" do
      # Create a line of 12000 'a' characters
      long_line = String.duplicate("a", 12000)
      result = LineNumbers.format_line_numbers(long_line)

      # Should have 3 chunks: 5000, 5000, 2000
      assert String.contains?(result, "     1\t")

      assert String.contains?(result, "   1.1\t"),
             "Second chunk should have .1 continuation marker"

      assert String.contains?(result, "   1.2\t"),
             "Third chunk should have .2 continuation marker"

      # Verify the structure
      lines = String.split(result, "\n")
      assert length(lines) == 3, "Should have 3 chunks for 12000 chars with 5000 limit"

      # First chunk: regular format
      assert List.first(lines) |> String.starts_with?("     1\t")

      # Second chunk: continuation marker .1
      assert Enum.at(lines, 1) |> String.starts_with?("   1.1\t")

      # Third chunk: continuation marker .2
      assert Enum.at(lines, 2) |> String.starts_with?("   1.2\t")
    end

    test "long line exact boundary - no continuation" do
      # Line exactly at boundary - no continuation needed
      line = String.duplicate("a", 5000)
      result = LineNumbers.format_line_numbers(line)

      # Should have only 1 line, no continuation
      refute String.contains?(result, ".1\t"), "Should not have continuation for exact boundary"
      assert result == "     1\t" <> line
    end

    test "long line just over boundary - 2 chunks" do
      # Line just over boundary (5001 chars) -> 2 chunks
      line = String.duplicate("a", 5001)
      result = LineNumbers.format_line_numbers(line)

      lines = String.split(result, "\n")
      assert length(lines) == 2, "5001 chars with 5000 limit should split into 2 chunks"

      # First chunk regular
      assert List.first(lines) |> String.starts_with?("     1\t")
      # Second chunk has continuation
      assert Enum.at(lines, 1) |> String.starts_with?("   1.1\t")
    end

    test "multiple long lines with continuations" do
      line1 = String.duplicate("x", 7500)
      line2 = String.duplicate("y", 6000)
      content = "#{line1}\n#{line2}"
      result = LineNumbers.format_line_numbers(content)

      lines = String.split(result, "\n")
      assert length(lines) == 4, "Two lines with continuations = 4 output lines"

      # Line 1 chunks
      assert Enum.at(lines, 0) |> String.starts_with?("     1\t")
      assert Enum.at(lines, 1) |> String.starts_with?("   1.1\t")

      # Line 2 chunks
      assert Enum.at(lines, 2) |> String.starts_with?("     2\t")
      assert Enum.at(lines, 3) |> String.starts_with?("   2.1\t")
    end

    test "continuation marker formatting with large line number" do
      # Test continuation marker with line 100
      line = String.duplicate("a", 10000)
      result = LineNumbers.format_line_numbers(line, start_line: 100)

      # "100.1" marker (6 chars width: " 100.1")
      assert String.contains?(result, " 100.1\t"), "Continuation marker should be right-aligned"
    end
  end

  # ============================================================================
  # UTF-8 and multibyte character tests
  # ============================================================================

  describe "UTF-8 content" do
    test "unicode content with accents" do
      result = LineNumbers.format_line_numbers("héllo\nwörld")
      assert result == "     1\théllo\n     2\twörld"
    end

    test "long line with multibyte UTF-8 - char based chunking" do
      # CHARACTER-BASED chunking: é counts as 1 character (like Python's len())
      # 5001 é chars = 5001 chars > 5000 limit → should trigger continuation
      line = String.duplicate("é", 5001)
      result = LineNumbers.format_line_numbers(line)

      assert String.contains?(result, "     1\t"), "First chunk should have regular line number"
      assert String.contains?(result, "   1.1\t"), "Should have continuation marker for overflow"
    end

    test "multibyte at chunk boundary - under limit" do
      # CHARACTER-BASED chunking: £ counts as 1 character
      # 3000 £ chars = 3000 chars < 5000 limit → NO continuation (unlike byte-based)
      # Even though 3000 £ = 6000 bytes in UTF-8, Python counts chars, not bytes
      line = String.duplicate("£", 3000)
      result = LineNumbers.format_line_numbers(line)

      refute String.contains?(result, "   1.1\t"),
             "3000 £ chars (3000 < 5000 limit) should NOT have continuation - char-based chunking"

      assert String.contains?(result, "     1\t")
    end

    test "multibyte chars chunked by char count" do
      # 3000 '£' chars = 3000 chars < 5000 limit → no continuation
      # Python: len('£' * 3000) == 3000, so no chunking needed
      line = String.duplicate("£", 3000)
      result = LineNumbers.format_line_numbers(line)

      refute String.contains?(result, ".1\t"),
             "Should not chunk by bytes (3000 chars < 5000 limit)"

      assert result |> String.split("\n") |> length() == 1
      assert String.starts_with?(result, "     1\t")
      assert String.ends_with?(result, String.duplicate("£", 3000))
    end

    test "multibyte chars over char limit" do
      # 5001 '£' chars > 5000 limit → should get continuation
      line = String.duplicate("£", 5001)
      result = LineNumbers.format_line_numbers(line)

      assert String.contains?(result, "   1.1\t"), "Should chunk at 5000 chars"

      lines = String.split(result, "\n")
      assert length(lines) == 2, "5001 chars should split into 2 chunks"

      # First chunk: 5000 chars
      first_chunk_content =
        Enum.at(lines, 0)
        |> String.replace_prefix("     1\t", "")

      assert String.length(first_chunk_content) == 5000

      # Second chunk: 1 char
      second_chunk_content =
        Enum.at(lines, 1)
        |> String.replace_prefix("   1.1\t", "")

      assert String.length(second_chunk_content) == 1
    end

    test "mixed multibyte and ASCII chunked by char count" do
      # Mix of ASCII and multibyte: all count as 1 char each
      # 2500 é + 2501 a = 5001 chars > 5000 limit
      line = String.duplicate("é", 2500) <> String.duplicate("a", 2501)
      result = LineNumbers.format_line_numbers(line)

      assert String.contains?(result, "   1.1\t"), "Mixed content should chunk at char boundary"

      lines = String.split(result, "\n")
      assert length(lines) == 2

      # First chunk ends with 'a' chars (position 5000)
      first_chunk =
        Enum.at(lines, 0)
        |> String.replace_prefix("     1\t", "")

      assert String.length(first_chunk) == 5000
      assert String.last(first_chunk) == "a"
    end

    test "character count parity with Python len()" do
      # Verify character-based length matches Python len()
      # Python: len('£' * 1000) == 1000 (chars, not bytes)
      pound_line = String.duplicate("£", 1000)
      byte_len = byte_size(pound_line)
      char_len = String.length(pound_line)

      assert byte_len == 2000, "£ is 2 bytes in UTF-8"
      assert char_len == 1000, "But Python/Rust char count is 1000"

      # At limit 1500, byte-based would chunk (2000 > 1500)
      # Char-based should NOT chunk (1000 < 1500)
      result = LineNumbers.format_line_numbers(pound_line, max_line_length: 1500)

      refute String.contains?(result, ".1\t"),
             "1000 chars at 1500 limit should NOT chunk"
    end

    test "emoji content" do
      # Emoji are single graphemes but multiple bytes
      result = LineNumbers.format_line_numbers("🎉 Emoji test 🚀")
      assert result == "     1\t🎉 Emoji test 🚀"
    end

    test "CJK characters" do
      # CJK characters are 3 bytes in UTF-8 but 1 grapheme
      result = LineNumbers.format_line_numbers("Hello, 世界!")
      assert result == "     1\tHello, 世界!"
    end

    test "combining characters counted as graphemes (diverges from Python codepoints)" do
      # e + combining grave = 1 grapheme (Elixir) vs 2 codepoints (Python)
      # This is intentional Elixir-native behavior - combining chars are rare in source code
      combining = "e" <> <<0xCC, 0x80>>
      assert String.length(combining) == 1
      assert byte_size(combining) == 3

      # Verify the line is formatted correctly (single grapheme = no continuation)
      result = LineNumbers.format_line_numbers(combining, max_line_length: 1)
      # At limit 1, 1 grapheme should NOT trigger continuation
      refute String.contains?(result, ".1\t")
      assert String.contains?(result, "     1\t" <> combining)
    end
  end

  # ============================================================================
  # Line endings and special content
  # ============================================================================

  describe "line endings" do
    test "CRLF line endings preserved in content" do
      # Windows line endings should be handled like Python's split('\n')
      # The \r stays as part of the line content
      result = LineNumbers.format_line_numbers("hello\r\nworld")
      # The \r is part of the first line content
      assert String.contains?(result, "     1\thello\r"), "CR should be preserved from CRLF"
      assert String.contains?(result, "     2\tworld")
    end

    test "multiple empty lines" do
      result = LineNumbers.format_line_numbers("\n\n\n")
      lines = String.split(result, "\n")
      assert length(lines) == 4

      assert Enum.at(lines, 0) == "     1\t"
      assert Enum.at(lines, 1) == "     2\t"
      assert Enum.at(lines, 2) == "     3\t"
      assert Enum.at(lines, 3) == "     4\t"
    end
  end

  # ============================================================================
  # Line range selection (start_line + num_lines)
  # ============================================================================

  describe "line range selection" do
    test "num_limits limits output lines" do
      content = "line1\nline2\nline3\nline4\nline5"
      result = LineNumbers.format_line_numbers(content, num_lines: 3)

      lines = String.split(result, "\n")
      assert length(lines) == 3
      assert List.first(lines) == "     1\tline1"
      assert List.last(lines) == "     3\tline3"
    end

    test "start_line with num_lines" do
      content = "line1\nline2\nline3\nline4\nline5"
      result = LineNumbers.format_line_numbers(content, start_line: 10, num_lines: 2)

      lines = String.split(result, "\n")
      assert length(lines) == 2
      assert List.first(lines) == "    10\tline1"
      assert List.last(lines) == "    11\tline2"
    end

    test "num_lines larger than content returns all lines" do
      content = "line1\nline2"
      result = LineNumbers.format_line_numbers(content, num_lines: 100)

      lines = String.split(result, "\n")
      assert length(lines) == 2
    end
  end

  # ============================================================================
  # Custom max_line_length
  # ============================================================================

  describe "custom max_line_length" do
    test "smaller max_line_length creates more chunks" do
      line = String.duplicate("a", 25)
      # With max_line_length 10, we get 3 chunks
      result = LineNumbers.format_line_numbers(line, max_line_length: 10)

      lines = String.split(result, "\n")
      assert length(lines) == 3

      assert Enum.at(lines, 0) |> String.starts_with?("     1\t")
      assert Enum.at(lines, 1) |> String.starts_with?("   1.1\t")
      assert Enum.at(lines, 2) |> String.starts_with?("   1.2\t")
    end

    test "larger max_line_length reduces chunks" do
      line = String.duplicate("a", 100)
      result = LineNumbers.format_line_numbers(line, max_line_length: 100)

      assert result == "     1\t" <> line
    end
  end

  # ============================================================================
  # Edge cases
  # ============================================================================

  describe "edge cases" do
    test "large start line numbers" do
      # Test with large line numbers that might affect alignment
      result = LineNumbers.format_line_numbers("hello", start_line: 1_000_000)
      # 1000000 is 7 digits, but width is 6, so it overflows
      assert String.starts_with?(result, "1000000\t"), "Large line numbers should not truncate"
    end

    test "continuation with large line number" do
      # Test continuation marker with line 1000
      line = String.duplicate("a", 7500)
      result = LineNumbers.format_line_numbers(line, start_line: 1000)

      # "1000.1" is 6 chars, with width 6 it fits exactly
      assert String.contains?(result, "1000.1\t")
    end

    test "content with only whitespace" do
      result = LineNumbers.format_line_numbers("   \n  \t  \n")
      lines = String.split(result, "\n")
      assert length(lines) == 3

      assert Enum.at(lines, 0) == "     1\t   "
      assert Enum.at(lines, 1) == "     2\t  \t  "
      assert Enum.at(lines, 2) == "     3\t"
    end

    test "single character lines" do
      result = LineNumbers.format_line_numbers("a\nb\nc")
      assert result == "     1\ta\n     2\tb\n     3\tc"
    end

    test "mix of short and long lines" do
      short = "short"
      long = String.duplicate("x", 6000)
      content = "#{short}\n#{long}\n#{short}"

      result = LineNumbers.format_line_numbers(content)
      lines = String.split(result, "\n")

      # Should have: short, long chunk 1, long chunk 2, short = 4 lines
      assert length(lines) == 4

      assert Enum.at(lines, 0) == "     1\tshort"
      assert Enum.at(lines, 1) |> String.starts_with?("     2\t")
      assert Enum.at(lines, 2) |> String.starts_with?("   2.1\t")
      assert Enum.at(lines, 3) == "     3\tshort"
    end

    test "very long continuation markers don't overflow too badly" do
      # Line 9999999.99 would be 9 digits total, with width 6 we overflow
      line = String.duplicate("a", 10000)
      result = LineNumbers.format_line_numbers(line, start_line: 9_999_999)

      # The marker itself may overflow, but content should still be correct
      lines = String.split(result, "\n")
      assert length(lines) == 2

      # Both chunks should have the long line number
      assert Enum.at(lines, 0) |> String.contains?("9999999\t")
      assert Enum.at(lines, 1) |> String.contains?("9999999.1\t")
    end
  end

  # ============================================================================
  # Property-based style tests
  # ============================================================================

  describe "properties" do
    test "single line without continuation is exact length" do
      content = "hello world"
      result = LineNumbers.format_line_numbers(content)
      # 6 chars line number + 1 tab + content
      assert String.length(result) == 6 + 1 + String.length(content)
    end

    test "empty line produces just line number and tab" do
      result = LineNumbers.format_line_numbers("")
      assert result == "     1\t"
    end

    test "chunk boundaries preserve total character count" do
      # A line of 5001 characters split at 5000 should preserve all chars
      line = String.duplicate("a", 5001)
      result = LineNumbers.format_line_numbers(line)

      # Extract just the content parts
      lines = String.split(result, "\n")

      chunk1 = Enum.at(lines, 0) |> String.replace_prefix("     1\t", "")
      chunk2 = Enum.at(lines, 1) |> String.replace_prefix("   1.1\t", "")

      total_content = String.length(chunk1) + String.length(chunk2)
      assert total_content == 5001
    end

    test "num_lines=0 produces empty result" do
      content = "line1\nline2\nline3"
      result = LineNumbers.format_line_numbers(content, num_lines: 0)
      assert result == ""
    end

    test "default parameters match explicit defaults" do
      content = "hello\nworld"

      default_result = LineNumbers.format_line_numbers(content)

      explicit_result =
        LineNumbers.format_line_numbers(content,
          max_line_length: 5000,
          start_line: 1,
          line_number_width: 6
        )

      assert default_result == explicit_result
    end
  end
end
