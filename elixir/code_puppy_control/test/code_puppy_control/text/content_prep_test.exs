defmodule CodePuppyControl.Text.ContentPrepTest do
  @moduledoc """
  Tests for ContentPrep module.

  Ported from Rust `code_puppy_core/src/content_prep.rs` tests.
  """

  use ExUnit.Case

  alias CodePuppyControl.Text.ContentPrep

  # ============================================================================
  # looks_textish/1 tests (ported from Rust)
  # ============================================================================

  describe "looks_textish/1" do
    test "empty content is text" do
      assert ContentPrep.looks_textish("") == true
    end

    test "pure ASCII text is text" do
      assert ContentPrep.looks_textish("Hello, World!") == true
    end

    test "multiple lines is text" do
      assert ContentPrep.looks_textish("Line 1\nLine 2\nLine 3") == true
    end

    test "content with CRLF is text" do
      assert ContentPrep.looks_textish("Line 1\r\nLine 2\r\n") == true
    end

    test "content with tabs is text" do
      assert ContentPrep.looks_textish("Column1\tColumn2\tColumn3") == true
    end

    test "NUL byte indicates binary" do
      assert ContentPrep.looks_textish("Hello\x00World") == false
      assert ContentPrep.looks_textish(<<0>>) == false
    end

    test "binary with low printable ratio is detected" do
      # Content with < 90% printable chars (1 control, 9 printable = 90% threshold)
      binary_like = String.duplicate(<<0x01>>, 91) <> String.duplicate("a", 9)
      assert ContentPrep.looks_textish(binary_like) == false
    end

    test "binary with high control chars is detected" do
      # Mix of control chars and some text
      content = <<0x01, 0x02, 0x03, 0x04, 0x05>> <> "Hello" <> <<0x06, 0x07, 0x08, 0x09, 0x10>>
      assert ContentPrep.looks_textish(content) == false
    end

    test "exactly 90 percent printable is text" do
      # 9 printable, 1 control = exactly 90% (threshold is >= 0.90)
      input = String.duplicate("a", 9) <> <<0x01>>
      assert ContentPrep.looks_textish(input) == true
    end

    test "just below 90 percent is binary" do
      # 89 printable, 11 control = ~89% (below threshold)
      input = String.duplicate("a", 89) <> String.duplicate(<<0x01>>, 11)
      assert ContentPrep.looks_textish(input) == false
    end
  end

  # ============================================================================
  # normalize_eol/1 tests (ported from Rust)
  # ============================================================================

  describe "normalize_eol/1" do
    test "no CRLF returns unchanged" do
      input = "Line 1\nLine 2\n"
      assert ContentPrep.normalize_eol(input) == "Line 1\nLine 2\n"
    end

    test "CRLF is normalized to LF" do
      input = "Line 1\r\nLine 2\r\n"
      assert ContentPrep.normalize_eol(input) == "Line 1\nLine 2\n"
    end

    test "orphan CR is normalized to LF" do
      input = "Line 1\rLine 2\r"
      assert ContentPrep.normalize_eol(input) == "Line 1\nLine 2\n"
    end

    test "mixed line endings are normalized" do
      input = "Line 1\r\nLine 2\rLine 3\n"
      assert ContentPrep.normalize_eol(input) == "Line 1\nLine 2\nLine 3\n"
    end

    test "binary content is unchanged" do
      binary = <<0x00, 0x01, 0x02, 0x03>>
      assert ContentPrep.normalize_eol(binary) == binary
    end

    test "content with NUL is unchanged" do
      content_with_nul = "hello\r\nworld\x00test"
      assert ContentPrep.normalize_eol(content_with_nul) == content_with_nul
    end

    test "content below printable threshold is unchanged" do
      # 80% printable, below 90% threshold
      low_printable = String.duplicate("a", 8) <> <<0x01, 0x02>>
      assert ContentPrep.normalize_eol(low_printable) == low_printable
    end
  end

  # ============================================================================
  # strip_bom/1 tests (ported from Rust)
  # ============================================================================

  describe "strip_bom/1" do
    test "strips UTF-8 BOM" do
      input = <<0xEF, 0xBB, 0xBF, "Hello World">>
      {result, had_bom, original_bom} = ContentPrep.strip_bom(input)
      assert result == "Hello World"
      assert had_bom == true
      assert original_bom == <<0xEF, 0xBB, 0xBF>>
    end

    test "returns no BOM when absent" do
      input = "Hello World"
      {result, had_bom, original_bom} = ContentPrep.strip_bom(input)
      assert result == "Hello World"
      assert had_bom == false
      assert original_bom == nil
    end

    test "handles empty content" do
      assert ContentPrep.strip_bom("") == {"", false, nil}
    end

    test "only strips leading BOM" do
      # BOM in the middle should not be stripped
      content_middle_bom = <<"hello", 0xEF, 0xBB, 0xBF, "world">>
      {result, had_bom, original_bom} = ContentPrep.strip_bom(content_middle_bom)
      assert result == content_middle_bom
      assert had_bom == false
      assert original_bom == nil
    end

    test "handles partial BOM bytes" do
      # Only first byte of BOM
      partial1 = <<0xEF, "hello">>
      assert ContentPrep.strip_bom(partial1) == {partial1, false, nil}

      # First two bytes of BOM
      partial2 = <<0xEF, 0xBB, "hello">>
      assert ContentPrep.strip_bom(partial2) == {partial2, false, nil}
    end
  end

  # ============================================================================
  # restore_bom/2 tests
  # ============================================================================

  describe "restore_bom/2" do
    test "restores BOM when present" do
      content = "hello world"
      bom = <<0xEF, 0xBB, 0xBF>>
      assert ContentPrep.restore_bom(content, bom) == <<0xEF, 0xBB, 0xBF, "hello world">>
    end

    test "does not modify content when BOM is nil" do
      content = "hello world"
      assert ContentPrep.restore_bom(content, nil) == "hello world"
    end

    test "handles empty content with BOM" do
      assert ContentPrep.restore_bom("", <<0xEF, 0xBB, 0xBF>>) == <<0xEF, 0xBB, 0xBF>>
      assert ContentPrep.restore_bom("", nil) == ""
    end
  end

  # ============================================================================
  # prepare_content/1 tests (ported from Rust)
  # ============================================================================

  describe "prepare_content/1" do
    test "empty content" do
      result = ContentPrep.prepare_content("")
      assert result.content == ""
      assert result.is_text == true
      assert result.had_bom == false
      assert result.had_crlf == false
      assert result.original_bom == nil
    end

    test "pure text" do
      result = ContentPrep.prepare_content("Hello, World!")
      assert result.content == "Hello, World!"
      assert result.is_text == true
      assert result.had_bom == false
      assert result.had_crlf == false
      assert result.original_bom == nil
    end

    test "content with CRLF" do
      result = ContentPrep.prepare_content("Line 1\r\nLine 2\r\n")
      assert result.content == "Line 1\nLine 2\n"
      assert result.is_text == true
      assert result.had_bom == false
      assert result.had_crlf == true
      assert result.original_bom == nil
    end

    test "content with BOM" do
      input = <<0xEF, 0xBB, 0xBF, "Hello World">>
      result = ContentPrep.prepare_content(input)
      assert result.content == "Hello World"
      assert result.is_text == true
      assert result.had_bom == true
      assert result.had_crlf == false
      assert result.original_bom == <<0xEF, 0xBB, 0xBF>>
    end

    test "content with BOM and CRLF" do
      input = <<0xEF, 0xBB, 0xBF, "Line 1\r\nLine 2">>
      result = ContentPrep.prepare_content(input)
      assert result.content == "Line 1\nLine 2"
      assert result.is_text == true
      assert result.had_bom == true
      assert result.had_crlf == true
      assert result.original_bom == <<0xEF, 0xBB, 0xBF>>
    end

    test "binary with NUL byte" do
      # NUL byte anywhere in content marks it as binary
      input = <<"Hello", 0, "World">>
      result = ContentPrep.prepare_content(input)
      assert result.is_text == false
      assert result.had_bom == false
      assert result.had_crlf == false
    end

    test "binary with low printable ratio" do
      # Create content that passes NUL check but fails printable ratio
      # 9 printable, 91 control = 9% printable (well below 90%)
      input = String.duplicate("a", 9) <> String.duplicate(<<0x01>>, 91)
      result = ContentPrep.prepare_content(input)
      assert result.is_text == false
      assert result.had_bom == false
      assert result.had_crlf == false
    end

    test "Unicode content" do
      input = "Hello 世界 🌍"
      result = ContentPrep.prepare_content(input)
      assert result.content == "Hello 世界 🌍"
      assert result.is_text == true
      assert result.had_bom == false
      assert result.had_crlf == false
    end

    test "Unicode with CRLF" do
      input = "Line 1\r\n世界\r\n🌍"
      result = ContentPrep.prepare_content(input)
      assert result.content == "Line 1\n世界\n🌍"
      assert result.is_text == true
      assert result.had_bom == false
      assert result.had_crlf == true
    end

    test "orphan CR (not part of CRLF)" do
      # Orphan CR (not part of CRLF) should be normalized too
      input = "Line 1\rLine 2"
      result = ContentPrep.prepare_content(input)
      assert result.content == "Line 1\nLine 2"
      assert result.is_text == true
      # had_crlf tracks CRLF sequences; orphan CRs don't set this
      assert result.had_crlf == false
    end

    test "binary with BOM" do
      # Binary content (NUL byte) with BOM - BOM should be stripped
      input = <<0xEF, 0xBB, 0xBF, "Hello", 0, "World">>
      result = ContentPrep.prepare_content(input)
      assert result.is_text == false
      assert result.had_bom == true
      # Content should NOT start with BOM after stripping
      refute String.starts_with?(result.content, "\uFEFF")
    end

    test "prepare_content with normalize: false option" do
      input = "Line 1\r\nLine 2"
      result = ContentPrep.prepare_content(input, normalize: false)
      assert result.content == "Line 1\r\nLine 2"
      assert result.is_text == true
      assert result.had_crlf == true
    end

    test "prepare_content with strip_bom: false option" do
      input = <<0xEF, 0xBB, 0xBF, "Hello">>
      result = ContentPrep.prepare_content(input, strip_bom: false)
      assert result.content == <<0xEF, 0xBB, 0xBF, "Hello">>
      assert result.is_text == true
      # We didn't strip, so we didn't "have" one for tracking
      assert result.had_bom == false
    end
  end

  # ============================================================================
  # Edge cases
  # ============================================================================

  describe "edge cases" do
    test "BOM-only content" do
      bom_only = <<0xEF, 0xBB, 0xBF>>
      result = ContentPrep.prepare_content(bom_only)
      assert result.content == ""
      assert result.is_text == true
      assert result.had_bom == true
      assert result.had_crlf == false
      assert result.original_bom == <<0xEF, 0xBB, 0xBF>>
    end

    test "round-trip: strip -> restore preserves original with BOM" do
      original = <<0xEF, 0xBB, 0xBF, "content\r\nmore">>
      result = ContentPrep.prepare_content(original)
      restored = ContentPrep.restore_bom(result.content, result.original_bom)
      assert restored == <<0xEF, 0xBB, 0xBF, "content\nmore">>
    end

    test "round-trip on content without BOM" do
      original = "content\r\nmore"
      result = ContentPrep.prepare_content(original)
      assert result.original_bom == nil
      restored = ContentPrep.restore_bom(result.content, result.original_bom)
      assert restored == "content\nmore"
    end

    test "complex file with BOM, CRLF, and mixed endings" do
      complex = <<0xEF, 0xBB, 0xBF, "Header\r\nLine1\rLine2\nLine3\r\n">>
      result = ContentPrep.prepare_content(complex)

      assert result.original_bom == <<0xEF, 0xBB, 0xBF>>
      assert result.content == "Header\nLine1\nLine2\nLine3\n"
      assert result.is_text == true
      assert result.had_bom == true
      assert result.had_crlf == true
    end

    test "very long lines are handled efficiently" do
      long_line = String.duplicate("a", 10_000)
      content = "#{long_line}\r\n#{long_line}"
      result = ContentPrep.prepare_content(content)
      assert result.content == "#{long_line}\n#{long_line}"
      assert result.is_text == true
      assert result.had_crlf == true
    end

    test "many lines are handled efficiently" do
      many_lines = String.duplicate("line\r\n", 1000)
      expected = String.duplicate("line\n", 1000)
      result = ContentPrep.prepare_content(many_lines)
      assert result.content == expected
      assert result.is_text == true
      assert result.had_crlf == true
    end

    test "JSON content" do
      json = ~s({"key": "value", "number": 42, "nested": {"array": [1, 2, 3]}})
      result = ContentPrep.prepare_content(json)
      assert result.content == json
      assert result.is_text == true
      assert result.had_bom == false
      assert result.had_crlf == false
    end

    test "Elixir source code" do
      code = """
      defmodule Test do
        def hello do
          :world
        end
      end
      """

      result = ContentPrep.prepare_content(code)
      assert result.is_text == true
      assert result.had_bom == false
      assert result.had_crlf == false
    end

    test "PNG image header (binary detection)" do
      # PNG signature with high bytes
      png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
      result = ContentPrep.prepare_content(png_header)
      assert result.is_text == false
      assert result.content == png_header
    end

    test "GIF image header (binary detection)" do
      # GIF89a signature
      gif_header = "GIF89a" <> <<0x01, 0x00, 0x01>>
      result = ContentPrep.prepare_content(gif_header)
      assert result.is_text == false
    end

    test "invalid UTF-8 is treated as binary" do
      # Invalid UTF-8 sequence (incomplete multi-byte)
      invalid_utf8 = <<0xC0, 0x80>>
      result = ContentPrep.prepare_content(invalid_utf8)
      assert result.is_text == false
    end
  end

  # ============================================================================
  # Property-like tests (idempotency, invariants)
  # ============================================================================

  describe "property tests" do
    test "idempotent normalization" do
      content = "line1\r\nline2\rline3"
      result1 = ContentPrep.prepare_content(content)
      result2 = ContentPrep.prepare_content(result1.content)
      assert result1.content == result2.content
      # Already normalized
      assert result2.had_crlf == false
    end

    test "normalization preserves non-EOL content" do
      content = "preserve this content exactly"
      result = ContentPrep.prepare_content(content)
      assert result.content == content
    end

    test "strip_bom is idempotent" do
      content = <<0xEF, 0xBB, 0xBF, "hello">>
      result1 = ContentPrep.prepare_content(content)
      result2 = ContentPrep.prepare_content(result1.content)

      assert result1.original_bom == <<0xEF, 0xBB, 0xBF>>
      assert result2.original_bom == nil
      assert result1.content == "hello"
      assert result2.content == "hello"
    end

    test "empty content after stripping BOM" do
      result = ContentPrep.prepare_content(<<0xEF, 0xBB, 0xBF>>)
      assert result.content == ""
      assert result.is_text == true
      assert result.had_bom == true
    end

    test "had_crlf tracks only actual CRLF sequences" do
      # Content with only orphan CR
      result = ContentPrep.prepare_content("line1\rline2")
      assert result.had_crlf == false
      assert result.content == "line1\nline2"

      # Content with CRLF
      result = ContentPrep.prepare_content("line1\r\nline2")
      assert result.had_crlf == true
    end

    test "is_text invariant: NUL bytes always mean binary" do
      inputs = [
        <<0>>,
        <<"text", 0, "text">>,
        <<0, 0, 0>>,
        # BOM followed by NUL
        <<0xEF, 0xBB, 0xBF, 0>>
      ]

      for input <- inputs do
        result = ContentPrep.prepare_content(input)
        assert result.is_text == false, "Expected binary for input with NUL"
      end
    end

    test "had_bom invariant: true means BOM was stripped from content" do
      input = <<0xEF, 0xBB, 0xBF, "content">>
      result = ContentPrep.prepare_content(input)
      assert result.had_bom == true
      refute String.starts_with?(result.content, "\uFEFF")
    end

    test "binary content: had_crlf may still be detected" do
      # Binary content with embedded CRLF
      input = <<0x00, "\r\n", 0x01>>
      result = ContentPrep.prepare_content(input)
      assert result.is_text == false
      # Still detected even in binary
      assert result.had_crlf == true
    end
  end

  # ============================================================================
  # Windows and legacy Mac file handling
  # ============================================================================

  describe "OS-specific line endings" do
    test "Windows-style files (CRLF)" do
      windows_file = "First line\r\nSecond line\r\nThird line"
      result = ContentPrep.prepare_content(windows_file)
      assert result.content == "First line\nSecond line\nThird line"
      assert result.is_text == true
      assert result.had_crlf == true
    end

    test "Classic Mac-style files (CR only)" do
      mac_file = "First line\rSecond line\rThird line"
      result = ContentPrep.prepare_content(mac_file)
      assert result.content == "First line\nSecond line\nThird line"
      assert result.is_text == true
      # No CRLF sequences, just orphan CRs
      assert result.had_crlf == false
    end

    test "Unix-style files (LF only)" do
      unix_file = "First line\nSecond line\nThird line"
      result = ContentPrep.prepare_content(unix_file)
      assert result.content == "First line\nSecond line\nThird line"
      assert result.is_text == true
      assert result.had_crlf == false
    end

    test "mixed OS-style file" do
      mixed = "Windows\r\nMac\rUnix\n"
      result = ContentPrep.prepare_content(mixed)
      assert result.content == "Windows\nMac\nUnix\n"
      assert result.is_text == true
      assert result.had_crlf == true
    end
  end

  # ============================================================================
  # Large file handling
  # ============================================================================

  describe "large file handling" do
    test "large text file with consistent CRLF" do
      large = String.duplicate("Some content here\r\n", 5000)
      result = ContentPrep.prepare_content(large)
      expected = String.duplicate("Some content here\n", 5000)
      assert result.content == expected
      assert result.is_text == true
      assert result.had_crlf == true
    end

    test "large text file with mixed endings" do
      lines =
        for i <- 1..1000 do
          case rem(i, 3) do
            0 -> "Line #{i}\r\n"
            1 -> "Line #{i}\r"
            2 -> "Line #{i}\n"
          end
        end
        |> Enum.join()

      result = ContentPrep.prepare_content(lines)
      assert result.is_text == true
      # At least some CRLF present
      assert result.had_crlf == true
      # All lines should end with \n now
      refute String.contains?(result.content, "\r\n")
      refute String.contains?(result.content, "\r")
    end

    test "large binary file (NUL bytes distributed)" do
      # Create binary with NUL every 100 bytes
      chunks = for _ <- 1..100, do: String.duplicate("a", 99) <> <<0>>
      large_binary = Enum.join(chunks)

      result = ContentPrep.prepare_content(large_binary)
      assert result.is_text == false
      assert result.had_bom == false
    end
  end
end
