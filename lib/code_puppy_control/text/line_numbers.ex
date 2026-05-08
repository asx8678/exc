defmodule CodePuppyControl.Text.LineNumbers do
  @moduledoc """
  Line number formatting with continuation markers for long lines.

  Port of `code_puppy_core/src/line_numbers.rs` and Python's
  `format_content_with_line_numbers()` from file_display.py.

  Provides `cat -n` style line numbering with continuation markers for
  lines exceeding the maximum length.

  ## Key Behavior

  - GRAPHEME-BASED chunking (not byte-based or codepoint-based)
  - Elixir's `String.length/1` counts graphemes (visual characters)
  - This differs from Python's `len()` which counts codepoints:
    - Most characters: 1 grapheme = 1 codepoint (same behavior)
    - Combining characters: `e` + `\u0300` = 1 grapheme (Elixir) vs 2 codepoints (Python)
  - For typical source code, the behavior matches; combining chars are rare
  - Lines exceeding `max_line_length` are split with markers like "5.1", "5.2"

  ## Examples

      iex> LineNumbers.format_line_numbers("hello\\nworld")
      "     1\\thello\\n     2\\tworld"

      iex> LineNumbers.format_line_numbers("hello", start_line: 10)
      "    10\\thello"

      iex> long = String.duplicate("a", 5001)
      iex> LineNumbers.format_line_numbers(long, max_line_length: 5000)
      "     1\\t" <> String.duplicate("a", 5000) <> "\\n   1.1\\ta"
  """

  @default_max_line_length 5000
  @default_line_number_width 6

  @doc """
  Format content with line numbers (cat -n style).

  For lines exceeding `max_line_length` (character count, not bytes),
  splits into chunks with continuation markers (e.g., "5.1", "5.2", "5.3").

  ## Options

    * `:max_line_length` - Maximum character count before splitting (default: 5000)
    * `:start_line` - Starting line number, 1-based (default: 1)
    * `:num_lines` - Maximum number of lines to process (default: nil, meaning all)
    * `:line_number_width` - Width for line number column (default: 6)

  ## Examples

      iex> LineNumbers.format_line_numbers("hello\\nworld")
      "     1\\thello\\n     2\\tworld"

      iex> LineNumbers.format_line_numbers("hello", start_line: 5)
      "     5\\thello"

      iex> LineNumbers.format_line_numbers("line1\\nline2\\nline3", start_line: 1, num_lines: 2)
      "     1\\tline1\\n     2\\tline2"

      iex> LineNumbers.format_line_numbers("héllo\\nwörld")
      "     1\\théllo\\n     2\\twörld"
  """
  @spec format_line_numbers(binary(), keyword()) :: binary()
  def format_line_numbers(content, opts \\ []) when is_binary(content) do
    max_line_length = Keyword.get(opts, :max_line_length, @default_max_line_length)
    start_line = Keyword.get(opts, :start_line, 1)
    num_lines = Keyword.get(opts, :num_lines, nil)
    line_number_width = Keyword.get(opts, :line_number_width, @default_line_number_width)

    lines = split_lines(content)

    # Apply line range limit if specified
    lines =
      if num_lines do
        Enum.take(lines, num_lines)
      else
        lines
      end

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      line_num = start_line + idx
      format_line(line, line_num, max_line_length, line_number_width)
    end)
    |> Enum.join("\n")
  end

  # Split content by newlines, preserving Python's split('\n') behavior
  # An empty string produces [""] (one empty line)
  # A trailing newline produces an extra empty line at the end
  defp split_lines(""), do: [""]

  defp split_lines(content) when is_binary(content) do
    String.split(content, "\n")
  end

  # Format a single logical line, handling long lines with continuation
  defp format_line(line, line_num, max_line_length, line_number_width) do
    char_len = String.length(line)

    if char_len <= max_line_length do
      # Normal line: just format with line number
      format_single_chunk(line_num, line, line_number_width)
    else
      # Long line: split into chunks with continuation markers
      # Pre-compute graphemes once for efficiency (avoids repeated String.graphemes/1 calls)
      graphemes = String.graphemes(line)
      num_chunks = div_ceil(char_len, max_line_length)

      0..(num_chunks - 1)
      |> Enum.map(fn chunk_idx ->
        start_char = chunk_idx * max_line_length
        end_char = min(start_char + max_line_length, char_len)
        chunk = slice_by_chars(graphemes, start_char, end_char)

        if chunk_idx == 0 do
          format_single_chunk(line_num, chunk, line_number_width)
        else
          format_continuation_chunk(line_num, chunk_idx, chunk, line_number_width)
        end
      end)
      |> Enum.join("\n")
    end
  end

  # Format a regular line: "     1\tcontent"
  defp format_single_chunk(line_num, content, width) do
    formatted_num = String.pad_leading("#{line_num}", width, " ")
    "#{formatted_num}\t#{content}"
  end

  # Format a continuation chunk: "   1.1\tcontent"
  defp format_continuation_chunk(line_num, chunk_idx, content, width) do
    marker = "#{line_num}.#{chunk_idx}"
    formatted_marker = String.pad_leading(marker, width, " ")
    "#{formatted_marker}\t#{content}"
  end

  # Slice by character indices (grapheme-based, not byte-based)
  # Accepts pre-computed graphemes list for efficiency on long lines
  defp slice_by_chars(graphemes, start_char, end_char) when is_list(graphemes) do
    graphemes
    |> Enum.slice(start_char, end_char - start_char)
    |> Enum.join()
  end

  # Ceiling division: (a + b - 1) // b
  defp div_ceil(a, b) do
    div(a + b - 1, b)
  end
end
