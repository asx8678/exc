defmodule CodePuppyControl.Text.EOLTest do
  @moduledoc """
  Tests for EOL normalization module.

  Ported from legacy Python code_puppy/utils/eol.py tests.
  """

  use ExUnit.Case

  alias CodePuppyControl.Text.EOL

  # ============================================================================
  # looks_textish/1 tests
  # ============================================================================

  describe "looks_textish/1" do
    test "empty content is text" do
      assert EOL.looks_textish("") == true
    end

    test "plain ASCII text is text" do
      assert EOL.looks_textish("hello world") == true
      assert EOL.looks_textish("Hello, World!\n") == true
    end

    test "source code is text" do
      code = """
      defmodule Test do
        def hello do
          :world
        end
      end
      """

      assert EOL.looks_textish(code) == true
    end

    test "NUL byte indicates binary" do
      assert EOL.looks_textish(<<0>>) == false
      assert EOL.looks_textish(<<"hello", 0, "world">>) == false
      assert EOL.looks_textish(<<0, 1, 2, 3>>) == false
    end

    test "binary content is detected as binary" do
      # Simulate binary content (like an image header)
      binary_content = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
      assert EOL.looks_textish(binary_content) == false
    end

    test "invalid UTF-8 is treated as binary" do
      # Invalid UTF-8 sequence
      invalid_utf8 = <<0x80, 0x81, 0x82>>
      assert EOL.looks_textish(invalid_utf8) == false
    end

    test "90% printable threshold" do
      # Exactly 90% printable (9 printable, 1 control) - threshold is >= 0.90, so this is text
      text_90 = String.duplicate("a", 9) <> <<0x01>>
      assert EOL.looks_textish(text_90) == true

      # Above 90% printable (10 printable, 0 control)
      text_100 = String.duplicate("a", 10)
      assert EOL.looks_textish(text_100) == true

      # Just below threshold (9 printable, 2 control = 9/11 = ~81.8%)
      text_82 = String.duplicate("a", 9) <> <<0x01, 0x02>>
      assert EOL.looks_textish(text_82) == false
    end

    test "whitespace counts as printable" do
      # Tab, newline, carriage return are considered printable
      assert EOL.looks_textish("\t\n\r") == true
      assert EOL.looks_textish("line1\nline2\tindent") == true
    end

    test "mixed content with high printable ratio" do
      # Mostly text with some control chars but still > 90% printable
      mixed = String.duplicate("a", 95) <> <<0x01>>
      assert EOL.looks_textish(mixed) == true
    end

    test "Unicode content is text" do
      assert EOL.looks_textish("Hello, 世界!") == true
      assert EOL.looks_textish("🎉 Emoji test 🚀") == true
      assert EOL.looks_textish("Café résumé naïve") == true
    end

    test "JSON content is text" do
      json = ~s({"key": "value", "number": 42, "nested": {"array": [1, 2, 3]}})
      assert EOL.looks_textish(json) == true
    end
  end

  # ============================================================================
  # normalize_eol/1 tests
  # ============================================================================

  describe "normalize_eol/1" do
    test "empty content returns empty" do
      assert EOL.normalize_eol("") == ""
    end

    test "CRLF is normalized to LF" do
      assert EOL.normalize_eol("line1\r\nline2") == "line1\nline2"
      assert EOL.normalize_eol("a\r\nb\r\nc") == "a\nb\nc"
    end

    test "orphan CR is normalized to LF" do
      assert EOL.normalize_eol("line1\rline2") == "line1\nline2"
      assert EOL.normalize_eol("a\rb\rc") == "a\nb\nc"
    end

    test "mixed line endings are normalized" do
      mixed = "line1\r\nline2\rline3\nline4"
      assert EOL.normalize_eol(mixed) == "line1\nline2\nline3\nline4"
    end

    test "already normalized content unchanged" do
      normalized = "line1\nline2\nline3"
      assert EOL.normalize_eol(normalized) == normalized
    end

    test "binary content is unchanged" do
      binary = <<0x00, 0x01, 0x02, 0x03>>
      assert EOL.normalize_eol(binary) == binary
    end

    test "content with NUL is unchanged" do
      content_with_nul = "hello\r\nworld\x00test"
      assert EOL.normalize_eol(content_with_nul) == content_with_nul
    end

    test "content below printable threshold is unchanged" do
      # 80% printable, below 90% threshold
      low_printable = String.duplicate("a", 8) <> <<0x01, 0x02>>
      assert EOL.normalize_eol(low_printable) == low_printable
    end

    test "preserves content without line endings" do
      assert EOL.normalize_eol("no line endings here") == "no line endings here"
    end

    test "handles Windows-style files" do
      windows_file = "First line\r\nSecond line\r\nThird line"
      assert EOL.normalize_eol(windows_file) == "First line\nSecond line\nThird line"
    end

    test "handles classic Mac-style files (CR only)" do
      mac_file = "First line\rSecond line\rThird line"
      assert EOL.normalize_eol(mac_file) == "First line\nSecond line\nThird line"
    end
  end

  # ============================================================================
  # strip_bom/1 tests
  # ============================================================================

  describe "strip_bom/1" do
    test "strips UTF-8 BOM" do
      content_with_bom = <<0xEF, 0xBB, 0xBF, "hello world">>
      assert EOL.strip_bom(content_with_bom) == {"hello world", <<0xEF, 0xBB, 0xBF>>}
    end

    test "returns nil BOM when no BOM present" do
      assert EOL.strip_bom("hello world") == {"hello world", nil}
    end

    test "handles empty content" do
      assert EOL.strip_bom("") == {"", nil}
    end

    test "only strips leading BOM" do
      # BOM in the middle should not be stripped
      content_middle_bom = <<"hello", 0xEF, 0xBB, 0xBF, "world">>
      assert EOL.strip_bom(content_middle_bom) == {content_middle_bom, nil}
    end

    test "handles partial BOM bytes" do
      # Only first byte of BOM
      partial1 = <<0xEF, "hello">>
      assert EOL.strip_bom(partial1) == {partial1, nil}

      # First two bytes of BOM
      partial2 = <<0xEF, 0xBB, "hello">>
      assert EOL.strip_bom(partial2) == {partial2, nil}
    end
  end

  # ============================================================================
  # restore_bom/2 tests
  # ============================================================================

  describe "restore_bom/2" do
    test "restores BOM when present" do
      content = "hello world"
      bom = <<0xEF, 0xBB, 0xBF>>
      assert EOL.restore_bom(content, bom) == <<0xEF, 0xBB, 0xBF, "hello world">>
    end

    test "does not modify content when BOM is nil" do
      content = "hello world"
      assert EOL.restore_bom(content, nil) == "hello world"
    end

    test "handles empty content" do
      assert EOL.restore_bom("", <<0xEF, 0xBB, 0xBF>>) == <<0xEF, 0xBB, 0xBF>>
      assert EOL.restore_bom("", nil) == ""
    end
  end

  # ============================================================================
  # normalize_with_bom/1 tests
  # ============================================================================

  describe "normalize_with_bom/1" do
    test "normalizes content and returns BOM" do
      content = <<0xEF, 0xBB, 0xBF, "line1\r\nline2">>
      assert EOL.normalize_with_bom(content) == {"line1\nline2", <<0xEF, 0xBB, 0xBF>>}
    end

    test "handles content without BOM" do
      content = "line1\r\nline2"
      assert EOL.normalize_with_bom(content) == {"line1\nline2", nil}
    end

    test "handles binary content" do
      binary = <<0xEF, 0xBB, 0xBF, 0x00, 0x01, 0x02>>
      # BOM is stripped but binary content is not normalized
      assert EOL.normalize_with_bom(binary) == {<<0x00, 0x01, 0x02>>, <<0xEF, 0xBB, 0xBF>>}
    end

    test "handles empty content" do
      assert EOL.normalize_with_bom("") == {"", nil}
    end
  end

  # ============================================================================
  # Edge cases and integration tests
  # ============================================================================

  describe "edge cases" do
    test "round-trip: strip -> restore preserves original with BOM" do
      original = <<0xEF, 0xBB, 0xBF, "content\r\nmore">>
      {stripped, bom} = EOL.strip_bom(original)
      restored = EOL.restore_bom(stripped, bom)
      assert restored == original
    end

    test "round-trip: strip -> restore on content without BOM" do
      original = "content\r\nmore"
      {stripped, bom} = EOL.strip_bom(original)
      assert bom == nil
      restored = EOL.restore_bom(stripped, bom)
      assert restored == original
    end

    test "complex file with BOM, CRLF, and mixed endings" do
      complex = <<0xEF, 0xBB, 0xBF, "Header\r\nLine1\rLine2\nLine3\r\n">>
      {normalized, bom} = EOL.normalize_with_bom(complex)

      assert bom == <<0xEF, 0xBB, 0xBF>>
      assert normalized == "Header\nLine1\nLine2\nLine3\n"
    end

    test "BOM-only content" do
      bom_only = <<0xEF, 0xBB, 0xBF>>
      assert EOL.strip_bom(bom_only) == {"", <<0xEF, 0xBB, 0xBF>>}
      assert EOL.normalize_eol(bom_only) == <<0xEF, 0xBB, 0xBF>>
    end

    test "very long lines are handled efficiently" do
      long_line = String.duplicate("a", 10_000)
      content = "#{long_line}\r\n#{long_line}"
      assert EOL.normalize_eol(content) == "#{long_line}\n#{long_line}"
    end

    test "many lines are handled efficiently" do
      many_lines = String.duplicate("line\r\n", 1000)
      expected = String.duplicate("line\n", 1000)
      assert EOL.normalize_eol(many_lines) == expected
    end
  end

  # ============================================================================
  # Property-based test helpers (manual examples)
  # ============================================================================

  describe "properties" do
    test "idempotent normalization" do
      content = "line1\r\nline2\rline3"
      once = EOL.normalize_eol(content)
      twice = EOL.normalize_eol(once)
      assert once == twice
    end

    test "normalization preserves non-EOL content" do
      content = "preserve this content exactly"
      assert EOL.normalize_eol(content) == content
    end

    test "strip_bom is idempotent" do
      content = <<0xEF, 0xBB, 0xBF, "hello">>
      {stripped1, bom1} = EOL.strip_bom(content)
      {stripped2, bom2} = EOL.strip_bom(stripped1)

      assert bom1 == <<0xEF, 0xBB, 0xBF>>
      assert bom2 == nil
      assert stripped1 == "hello"
      assert stripped2 == "hello"
    end
  end
end
