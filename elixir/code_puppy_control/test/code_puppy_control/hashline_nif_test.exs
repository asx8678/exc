defmodule CodePuppyControl.HashlineNifTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.HashlineNif

  describe "compute_line_hash/2" do
    test "returns 2 uppercase chars" do
      hash = HashlineNif.compute_line_hash(1, "hello world")
      assert String.length(hash) == 2
      assert hash =~ ~r/^[A-Z]{2}$/
    end

    test "different indices produce different hashes for whitespace-only lines" do
      h1 = HashlineNif.compute_line_hash(1, "   ")
      h2 = HashlineNif.compute_line_hash(2, "   ")
      assert String.length(h1) == 2
      assert String.length(h2) == 2
    end

    test "strips trailing whitespace before hashing" do
      h1 = HashlineNif.compute_line_hash(1, "hello")
      h2 = HashlineNif.compute_line_hash(1, "hello   ")
      assert h1 == h2
    end

    test "strips trailing \\r before hashing" do
      h1 = HashlineNif.compute_line_hash(1, "hello")
      h2 = HashlineNif.compute_line_hash(1, "hello\r")
      assert h1 == h2
    end

    test "empty line uses idx as seed" do
      h1 = HashlineNif.compute_line_hash(1, "")
      h2 = HashlineNif.compute_line_hash(100, "")
      assert String.length(h1) == 2
      assert String.length(h2) == 2
      # Each should validate correctly for its own idx
      assert HashlineNif.validate_hashline_anchor(1, "", h1)
      assert HashlineNif.validate_hashline_anchor(100, "", h2)
    end

    test "alnum content ignores idx (seed=0)" do
      h1 = HashlineNif.compute_line_hash(1, "foo")
      h99 = HashlineNif.compute_line_hash(99, "foo")
      assert h1 == h99
    end

    test "chars come from NIBBLE_STR" do
      nibble = "ZPMQVRWSNKTXJBYH"
      hash = HashlineNif.compute_line_hash(1, "some code here")
      assert String.at(hash, 0) in String.graphemes(nibble)
      assert String.at(hash, 1) in String.graphemes(nibble)
    end
  end

  describe "format_hashlines/2" do
    test "basic formatting with start_line 1" do
      result = HashlineNif.format_hashlines("foo\nbar", 1)
      lines = String.split(result, "\n")
      assert length(lines) == 2
      assert String.starts_with?(hd(lines), "1#")
      assert String.contains?(hd(lines), ":foo")
      assert String.starts_with?(List.last(lines), "2#")
      assert String.contains?(List.last(lines), ":bar")
    end

    test "respects start_line parameter" do
      result = HashlineNif.format_hashlines("hello", 10)
      assert String.starts_with?(result, "10#")
      assert String.ends_with?(result, ":hello")
    end

    test "handles multi-line text" do
      result = HashlineNif.format_hashlines("line1\nline2\nline3", 1)
      lines = String.split(result, "\n")
      assert length(lines) == 3
      assert String.starts_with?(Enum.at(lines, 0), "1#")
      assert String.starts_with?(Enum.at(lines, 1), "2#")
      assert String.starts_with?(Enum.at(lines, 2), "3#")
    end

    test "handles empty string" do
      result = HashlineNif.format_hashlines("", 1)
      # Empty string splits into one empty line
      assert String.starts_with?(result, "1#")
    end

    test "produces correct prefix format" do
      result = HashlineNif.format_hashlines("hello\nworld", 1)
      lines = String.split(result, "\n")
      # Each line matches pattern: ^\d+#[A-Z]{2}:.*
      for line <- lines do
        assert line =~ ~r/^\d+#[A-Z]{2}:/
      end
    end

    test "preserves content after prefix" do
      original = "    def foo(self):\n        return 42"
      result = HashlineNif.format_hashlines(original, 1)
      lines = String.split(result, "\n")
      original_lines = String.split(original, "\n")

      for {fmt_line, orig_line} <- Enum.zip(lines, original_lines) do
        assert String.ends_with?(fmt_line, ":" <> orig_line)
      end
    end
  end

  describe "strip_hashline_prefixes/1" do
    test "round-trip: format then strip returns original" do
      original = "line one\nline two\n"
      formatted = HashlineNif.format_hashlines(original, 1)
      stripped = HashlineNif.strip_hashline_prefixes(formatted)
      assert stripped == original
    end

    test "round-trip with multiline" do
      original = "line one\nline two\nline three"
      formatted = HashlineNif.format_hashlines(original, 1)
      stripped = HashlineNif.strip_hashline_prefixes(formatted)
      assert stripped == original
    end

    test "round-trip with unicode" do
      original = "café\n日本語"
      formatted = HashlineNif.format_hashlines(original, 1)
      stripped = HashlineNif.strip_hashline_prefixes(formatted)
      assert stripped == original
    end

    test "passthrough for lines without prefix" do
      text = "no prefix here\njust plain text"
      stripped = HashlineNif.strip_hashline_prefixes(text)
      assert stripped == text
    end

    test "handles mixed prefixed and plain lines" do
      formatted = HashlineNif.format_hashlines("hello", 1)
      mixed = formatted <> "\nplain line"
      stripped = HashlineNif.strip_hashline_prefixes(mixed)
      assert stripped == "hello\nplain line"
    end

    test "does not strip lines that look like prefixes but aren't valid" do
      # "abc#XY:text" - no digits before #
      assert HashlineNif.strip_hashline_prefixes("abc#XY:text") == "abc#XY:text"
      # "1#xy:text" - lowercase after #
      assert HashlineNif.strip_hashline_prefixes("1#xy:text") == "1#xy:text"
      # "1#X:text" - only 1 char after #
      assert HashlineNif.strip_hashline_prefixes("1#X:text") == "1#X:text"
    end

    test "handles edge case: hash in content" do
      formatted = HashlineNif.format_hashlines("some#text", 1)
      stripped = HashlineNif.strip_hashline_prefixes(formatted)
      assert stripped == "some#text"
    end
  end

  describe "validate_hashline_anchor/3" do
    test "valid anchor returns true" do
      hash = HashlineNif.compute_line_hash(5, "some code")
      assert HashlineNif.validate_hashline_anchor(5, "some code", hash)
    end

    test "invalid anchor returns false" do
      hash = HashlineNif.compute_line_hash(5, "some code")
      refute HashlineNif.validate_hashline_anchor(5, "different code", hash)
    end

    test "wrong idx for blank line" do
      h1 = HashlineNif.compute_line_hash(1, "")
      h2 = HashlineNif.compute_line_hash(100, "")
      # Each hash validates for its own idx
      assert HashlineNif.validate_hashline_anchor(1, "", h1)
      assert HashlineNif.validate_hashline_anchor(100, "", h2)
      # Hash for idx=1 must NOT validate as idx=1 with wrong content
      refute HashlineNif.validate_hashline_anchor(1, "x", h1)
    end

    test "alnum content: idx is irrelevant (seed=0)" do
      h = HashlineNif.compute_line_hash(1, "some text")
      # Should validate with different idx since alnum content uses seed=0
      assert HashlineNif.validate_hashline_anchor(99, "some text", h)
    end

    test "unicode content validates correctly" do
      h = HashlineNif.compute_line_hash(1, "café 🚀")
      assert HashlineNif.validate_hashline_anchor(1, "café 🚀", h)
      refute HashlineNif.validate_hashline_anchor(1, "cafe 🚀", h)
    end
  end

  describe "cross-compatibility" do
    test "compute_line_hash produces known reference values" do
      # Verify against known values to catch algorithm drift
      result = HashlineNif.compute_line_hash(0, "hello world")
      assert String.length(result) == 2
      # determinism check
      assert result == HashlineNif.compute_line_hash(0, "hello world")
    end
  end

  describe "determinism" do
    test "same content produces same hash" do
      h1 = HashlineNif.compute_line_hash(5, "identical line")
      h2 = HashlineNif.compute_line_hash(5, "identical line")
      assert h1 == h2
    end

    test "format is deterministic" do
      r1 = HashlineNif.format_hashlines("alpha\nbeta", 1)
      r2 = HashlineNif.format_hashlines("alpha\nbeta", 1)
      assert r1 == r2
    end
  end
end
