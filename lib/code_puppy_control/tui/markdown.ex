defmodule CodePuppyControl.TUI.Markdown do
  @moduledoc """
  Markdown rendering to Owl-styled terminal output.

  Parses markdown text and returns `Owl.Data.t()` with proper ANSI
  styling for headers, bold, italic, inline code, code blocks,
  lists, and blockquotes.

  ## Supported Elements

    * Headers: `#`, `##`, `###`
    * Bold: `**text**`
    * Italic: `*text*`
    * Inline code: `` `code` ``
    * Code blocks: ` ```lang ... ``` `
    * Unordered lists: `- item` or `* item`
    * Blockquotes: `> text`

  ## Usage

      iex> Markdown.render("# Hello\\nWorld") |> Owl.IO.puts()
  """

  alias Owl.Data
  alias CodePuppyControl.TUI.Syntax

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Renders markdown text to Owl.Data tagged content.

  Returns a flat list of Owl.Data fragments suitable for `Owl.IO.puts/1`.
  """
  @spec render(String.t()) :: Data.t()
  def render(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> parse_lines([], nil)
    |> Enum.reverse()
  end

  # ── Line-by-Line Parser ───────────────────────────────────────────────────

  # State tracks multi-line constructs:
  #   nil                 — normal text
  #   {:code, lang, acc}  — inside a fenced code block
  #   {:blockquote, acc}  — inside a blockquote block

  @type parser_state :: nil | {:code, String.t(), [String.t()]} | {:blockquote, [String.t()]}

  # -- End of input: flush any open state --

  defp parse_lines([], acc, {:code, lang, lines}) do
    code_block = build_code_block(Enum.reverse(lines), lang)
    [code_block | acc]
  end

  defp parse_lines([], acc, {:blockquote, lines}) do
    blockquote = build_blockquote(Enum.reverse(lines))
    [blockquote | acc]
  end

  defp parse_lines([], acc, nil), do: acc

  # -- Code fence open --

  defp parse_lines([line | rest], acc, nil) do
    cond do
      code_fence?(line) ->
        {lang, _} = parse_code_fence(line)
        parse_lines(rest, acc, {:code, lang, []})

      blockquote_line?(line) ->
        text = extract_blockquote_text(line)
        parse_lines(rest, acc, {:blockquote, [text]})

      true ->
        parse_normal_line(line, rest, acc)
    end
  end

  # -- Inside code block --

  defp parse_lines([line | rest], acc, {:code, lang, lines}) do
    if code_fence?(line) do
      code_block = build_code_block(Enum.reverse(lines), lang)
      parse_lines(rest, [code_block | acc], nil)
    else
      parse_lines(rest, acc, {:code, lang, [line | lines]})
    end
  end

  # -- Inside blockquote block --

  defp parse_lines([line | rest], acc, {:blockquote, lines}) do
    if blockquote_line?(line) do
      text = extract_blockquote_text(line)
      parse_lines(rest, acc, {:blockquote, [text | lines]})
    else
      # End blockquote, process the accumulated lines
      blockquote = build_blockquote(Enum.reverse(lines))
      # Re-process current line in normal mode
      parse_lines([line | rest], [blockquote | acc], nil)
    end
  end

  # -- Normal line processing --

  defp parse_normal_line(line, rest, acc) do
    rendered =
      cond do
        header_line?(line) -> render_header(line)
        list_item_line?(line) -> render_list_item(line)
        horizontal_rule?(line) -> render_horizontal_rule()
        line == "" -> "\n"
        true -> render_inline(line)
      end

    parse_lines(rest, [rendered | acc], nil)
  end

  # ── Block-Level Detectors ─────────────────────────────────────────────────

  defp code_fence?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, "```")
  end

  defp blockquote_line?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, ">")
  end

  defp header_line?(line) do
    trimmed = String.trim_leading(line)
    Regex.match?(~r/^\#{1,3}\s/, trimmed)
  end

  defp list_item_line?(line) do
    trimmed = String.trim_leading(line)
    Regex.match?(~r/^[-*]\s/, trimmed)
  end

  defp horizontal_rule?(line) do
    trimmed = String.trim_leading(line)
    Regex.match?(~r/^-{3,}$/, trimmed) or Regex.match?(~r/^\*{3,}$/, trimmed)
  end

  # ── Block-Level Renderers ─────────────────────────────────────────────────

  defp parse_code_fence(line) do
    trimmed = String.trim(line)
    # Extract lang after the ```
    lang =
      trimmed
      |> String.trim_leading("`")
      |> String.trim()

    if lang == "", do: {"text", ""}, else: {lang, ""}
  end

  defp build_code_block(lines, lang) do
    code_text = Enum.join(lines, "\n")
    highlighted = Syntax.highlight(code_text, lang)

    # Wrap in a subtle box with language label
    label = Data.tag(" #{lang} ", [:white, :cyan_background])
    content = highlighted
    ["\n", label, "\n", content, "\n"]
  end

  defp extract_blockquote_text(line) do
    trimmed = String.trim_leading(line)

    String.trim_leading(trimmed, ">")
    |> String.trim()
  end

  defp build_blockquote(lines) do
    text = Enum.join(lines, "\n")
    rendered = render_inline(text)
    Data.tag(["  │ ", rendered], :faint)
  end

  # -- Headers --

  defp render_header(line) do
    trimmed = String.trim_leading(line)
    [hashes | rest] = Regex.split(~r/\s+/, trimmed, parts: 2, trim: true)
    level = String.length(hashes)
    text = Enum.join(rest, " ")

    case level do
      1 -> ["\n", Data.tag(text, [:bright, :cyan]), "\n"]
      2 -> ["\n", Data.tag(text, [:bright, :yellow]), "\n"]
      _ -> ["\n", Data.tag(text, [:bright, :white]), "\n"]
    end
  end

  # -- List items --

  defp render_list_item(line) do
    trimmed = String.trim_leading(line)
    text = String.replace(trimmed, ~r/^[-*]\s/, "")
    ["  • ", render_inline(text), "\n"]
  end

  # -- Horizontal rule --

  defp render_horizontal_rule do
    Data.tag(String.duplicate("─", 40), :faint)
  end

  # ── Inline Rendering ──────────────────────────────────────────────────────

  @doc """
  Renders inline markdown elements within a single line.

  Handles: bold, italic, inline code, and plain text.
  """
  @spec render_inline(String.t()) :: Data.t()
  def render_inline(text) when is_binary(text) do
    text
    |> parse_inline([])
    |> Enum.reverse()
  end

  # Inline code: `code`
  defp parse_inline(text, acc) do
    case Regex.run(~r/`([^`]+)`/, text, return: :index) do
      [{start, match_len} | [{inner_start, inner_len}]] ->
        # Text before the inline code
        before = binary_part(text, 0, start)
        inner = binary_part(text, inner_start, inner_len)

        acc =
          acc
          |> maybe_add_text(before)
          |> then(&[Data.tag(inner, [:white, :black_background]) | &1])

        rest_start = start + match_len
        remaining = binary_part(text, rest_start, byte_size(text) - rest_start)
        parse_inline(remaining, acc)

      nil ->
        # Try bold: **text**
        parse_bold(text, acc)
    end
  end

  defp parse_bold(text, acc) do
    case Regex.run(~r/\*\*(.+?)\*\*/, text, return: :index) do
      [{start, match_len} | [{inner_start, inner_len}]] ->
        before = binary_part(text, 0, start)
        inner = binary_part(text, inner_start, inner_len)

        acc =
          acc
          |> maybe_add_text(before)
          |> then(&[Data.tag(inner, :bright) | &1])

        rest_start = start + match_len
        remaining = binary_part(text, rest_start, byte_size(text) - rest_start)
        parse_inline(remaining, acc)

      nil ->
        # Try italic: *text*
        parse_italic(text, acc)
    end
  end

  defp parse_italic(text, acc) do
    case Regex.run(~r/\*(.+?)\*/, text, return: :index) do
      [{start, match_len} | [{inner_start, inner_len}]] ->
        before = binary_part(text, 0, start)
        inner = binary_part(text, inner_start, inner_len)

        acc =
          acc
          |> maybe_add_text(before)
          |> then(&[Data.tag(inner, :italic) | &1])

        rest_start = start + match_len
        remaining = binary_part(text, rest_start, byte_size(text) - rest_start)
        parse_inline(remaining, acc)

      nil ->
        # No more inline elements — add remaining text
        maybe_add_text(acc, text)
    end
  end

  defp maybe_add_text(acc, ""), do: acc
  defp maybe_add_text(acc, text), do: [text | acc]
end
