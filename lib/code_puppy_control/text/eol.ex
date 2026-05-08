defmodule CodePuppyControl.Text.EOL do
  @moduledoc """
  End-of-line normalization with binary-file detection.

  Port of `code_puppy/utils/eol.py`.

  Behavior:
  - Content with NUL bytes is treated as binary
  - Invalid UTF-8 is treated as binary
  - Valid UTF-8 content is considered text when at least 90% of characters
    are printable or common whitespace (`\\t`, `\\n`, `\\r`)
  - CRLF is normalized to LF for text content only
  - Leading UTF-8 BOM is stripped and can later be restored

  ## Examples

      iex> EOL.looks_textish("hello world\\n")
      true

      iex> EOL.looks_textish(<<0, 1, 2, 3>>)
      false

      iex> EOL.normalize_eol("line1\\r\\nline2\\rline3")
      "line1\\nline2\\nline3"

      iex> EOL.strip_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
      {"hello", <<0xEF, 0xBB, 0xBF>>}
  """

  # UTF-8 BOM: EF BB BF (decoded as U+FEFF)
  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  @doc """
  Check if content looks like human-readable text.

  The check is designed to be fast on typical source files (early-exit on
  NUL) and reasonably accurate on binary blobs.

  Returns `true` when the content is likely text, `false` when it appears
  to be binary.

  ## Heuristic

  1. Empty content is considered text
  2. NUL byte anywhere → binary
  3. Invalid UTF-8 → binary
  4. At least 90% of characters must be printable (>= 0x20) or common
     whitespace (\\t, \\n, \\r)

  ## Examples

      iex> EOL.looks_textish("hello world")
      true

      iex> EOL.looks_textish(<<0x00, 0x01, 0x02>>)
      false

      iex> EOL.looks_textish(<<0x80, 0x81, 0x82>>)
      false

      iex> EOL.looks_textish("")
      true
  """
  @spec looks_textish(binary()) :: boolean()
  def looks_textish(""), do: true

  def looks_textish(content) when is_binary(content) do
    cond do
      # 1. NUL byte → binary
      :binary.match(content, <<0>>) != :nomatch ->
        false

      # 2. Invalid UTF-8 → binary
      not String.valid?(content) ->
        false

      true ->
        # 3. Printable-ratio check
        chars = String.to_charlist(content)
        total = length(chars)

        printable = Enum.count(chars, &printable_char?/1)

        printable / total >= 0.90
    end
  end

  @doc """
  Normalize line endings to `\\n` if the content looks like text.

  Applies CRLF (`\\r\\n`) → LF (`\\n`) conversion and strips orphan CRs
  (`\\r` not followed by `\\n`). Binary-looking content is returned
  unchanged — see `looks_textish/1` for the detection heuristic.

  ## Examples

      iex> EOL.normalize_eol("line1\\r\\nline2\\rline3")
      "line1\\nline2\\nline3"

      iex> EOL.normalize_eol(<<0x00, 0x01>>)
      <<0x00, 0x01>>

      iex> EOL.normalize_eol("")
      ""
  """
  @spec normalize_eol(binary()) :: binary()
  def normalize_eol(""), do: ""

  def normalize_eol(content) when is_binary(content) do
    if looks_textish(content) do
      content
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
    else
      content
    end
  end

  @doc """
  Strip the UTF-8 BOM from the beginning of content.

  Returns a tuple of `{stripped_content, bom_bytes}`. The `bom_bytes` is
  `nil` if no BOM was present, or the BOM bytes if one was found.
  This allows callers to re-prepend the BOM after modifications.

  ## Examples

      iex> EOL.strip_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
      {"hello", <<0xEF, 0xBB, 0xBF>>}

      iex> EOL.strip_bom("hello")
      {"hello", nil}

      iex> EOL.strip_bom("")
      {"", nil}
  """
  @spec strip_bom(binary()) :: {binary(), binary() | nil}
  def strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {rest, @utf8_bom}
  def strip_bom(content) when is_binary(content), do: {content, nil}

  @doc """
  Re-prepend a BOM to content if one was originally present.

  ## Examples

      iex> EOL.restore_bom("hello", <<0xEF, 0xBB, 0xBF>>)
      <<0xEF, 0xBB, 0xBF, "hello">>

      iex> EOL.restore_bom("hello", nil)
      "hello"
  """
  @spec restore_bom(binary(), binary() | nil) :: binary()
  def restore_bom(content, nil) when is_binary(content), do: content

  def restore_bom(content, bom) when is_binary(content) and is_binary(bom),
    do: bom <> content

  @doc """
  Normalize content with full BOM handling.

  Strips BOM, normalizes EOL, and returns normalized content along with
  the BOM that was stripped (for later restoration).

  ## Examples

      iex> EOL.normalize_with_bom(<<0xEF, 0xBB, 0xBF, "line1\\r\\nline2">>)
      {"line1\\nline2", <<0xEF, 0xBB, 0xBF>>}

      iex> EOL.normalize_with_bom(<<0x00, 0x01>>)
      {<<0x00, 0x01>>, nil}
  """
  @spec normalize_with_bom(binary()) :: {binary(), binary() | nil}
  def normalize_with_bom(content) when is_binary(content) do
    {content_without_bom, bom} = strip_bom(content)
    normalized = normalize_eol(content_without_bom)
    {normalized, bom}
  end

  @doc """
  Remove leading/trailing blank lines that were added by the LLM.

  Compares original and updated text line-by-line. If `updated` has more
  leading blank lines than `original`, trims the surplus. Same for trailing.
  Blank-line counts in the middle of the content are preserved.

  Port of `code_puppy/utils/whitespace.py:strip_added_blank_lines`.

  ## Examples

      iex> EOL.strip_added_blank_lines("line1\nline2", "\nline1\nline2\n\n")
      "line1\nline2\n"

      iex> EOL.strip_added_blank_lines("line1\nline2", "line1\nline2")
      "line1\nline2"

      iex> EOL.strip_added_blank_lines("\nline1\n", "\nline1\n")
      "\nline1\n"
  """
  @spec strip_added_blank_lines(String.t(), String.t()) :: String.t()
  def strip_added_blank_lines(original, updated) do
    orig_lines = String.split(original, "\n")
    upd_lines = String.split(updated, "\n")

    # Count leading blank lines in each
    leading_orig = count_leading_blank(orig_lines)
    leading_upd = count_leading_blank(upd_lines)

    upd_lines =
      if leading_upd > leading_orig do
        Enum.drop(upd_lines, leading_upd - leading_orig)
      else
        upd_lines
      end

    # Count trailing blank lines in each
    trailing_orig = count_trailing_blank(orig_lines)
    trailing_upd = count_trailing_blank(upd_lines)

    upd_lines =
      if trailing_upd > trailing_orig do
        Enum.take(upd_lines, length(upd_lines) - (trailing_upd - trailing_orig))
      else
        upd_lines
      end

    Enum.join(upd_lines, "\n")
  end

  # Private helper for printable char check
  defp printable_char?(ch) when ch >= 0x20, do: true
  defp printable_char?(?\t), do: true
  defp printable_char?(?\n), do: true
  defp printable_char?(?\r), do: true
  defp printable_char?(_), do: false

  defp count_leading_blank(lines) do
    Enum.take_while(lines, &(String.trim(&1) == "")) |> length()
  end

  defp count_trailing_blank(lines) do
    Enum.reverse(lines)
    |> Enum.take_while(&(String.trim(&1) == ""))
    |> length()
  end
end
