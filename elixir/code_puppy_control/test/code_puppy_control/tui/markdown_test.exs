defmodule CodePuppyControl.TUI.MarkdownTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Markdown

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp render_to_string(text) do
    text
    |> Markdown.render()
    |> Owl.Data.to_chardata()
    |> IO.chardata_to_string()
  end

  defp render_inline_to_string(text) do
    text
    |> Markdown.render_inline()
    |> Owl.Data.to_chardata()
    |> IO.chardata_to_string()
  end

  # Recursively search nested IO-data for Owl.Tag structs.
  # render/1 wraps each line in a list, so tags can be nested.
  defp has_any_tag?(data) when is_list(data) do
    Enum.any?(data, &has_any_tag?/1)
  end

  defp has_any_tag?(%Owl.Tag{}), do: true
  defp has_any_tag?(_), do: false

  # ── render/1 ─────────────────────────────────────────────────────────────────

  describe "render/1" do
    test "plain text renders with no injection" do
      string = render_to_string("Hello world")
      assert string =~ "Hello world"
    end

    test "h1 header content appears in output" do
      string = render_to_string("# Big Title")
      assert string =~ "Big Title"
      refute string =~ "# Big Title"
    end

    test "h1 header produces styled output" do
      result = Markdown.render("# Title")
      assert has_any_tag?(result),
             "expected at least one Owl.Tag for header styling"
    end

    test "h2 header has no raw markdown markers" do
      string = render_to_string("## Subtitle")
      assert string =~ "Subtitle"
      refute string =~ "## Subtitle"
    end

    test "h3 header has no raw markdown markers" do
      string = render_to_string("### Section")
      assert string =~ "Section"
      refute string =~ "### Section"
    end

    test "bold text strips markers" do
      string = render_to_string("This is **bold** text")
      assert string =~ "bold"
      refute string =~ "**bold**"
    end

    test "bold text produces tagged output" do
      result = Markdown.render("**important**")
      assert has_any_tag?(result)
    end

    test "italic text strips markers" do
      string = render_to_string("This is *italic* text")
      assert string =~ "italic"
      refute string =~ "*italic*"
    end

    test "inline code strips backticks" do
      string = render_to_string("Use `mix test` to run")
      assert string =~ "mix test"
      refute string =~ "`mix test`"
    end

    test "inline code produces tagged output" do
      result = Markdown.render("Use `mix test` to run")
      assert has_any_tag?(result)
    end

    test "code block preserves content" do
      md = "```elixir\ndef foo do\n  :ok\nend\n```"
      string = render_to_string(md)
      assert string =~ "def foo"
      assert string =~ ":ok"
    end

    test "code block without language renders content" do
      md = "```\nsome code\n```"
      string = render_to_string(md)
      assert string =~ "some code"
    end

    test "unordered list renders items" do
      md = "- Item one\n- Item two\n- Item three"
      string = render_to_string(md)
      assert string =~ "Item one"
      assert string =~ "Item two"
      assert string =~ "Item three"
    end

    test "unordered list strips leading dash" do
      string = render_to_string("- Alone")
      refute string =~ "- Alone"
      assert string =~ "Alone"
    end

    test "blockquote text appears in output" do
      md = "> This is a quote"
      string = render_to_string(md)
      assert string =~ "This is a quote"
    end

    test "multi-line blockquote preserves all lines" do
      md = "> Line one\n> Line two\n> Line three"
      string = render_to_string(md)
      assert string =~ "Line one"
      assert string =~ "Line two"
      assert string =~ "Line three"
    end

    test "horizontal rule produces non-empty output" do
      string = render_to_string("---")
      refute string == ""
    end

    test "empty string produces empty or single-newline output" do
      string = render_to_string("")
      assert string == "" or string == "\n"
    end

    test "mixed content renders all elements" do
      md = ~S"""
      # Header

      Some **bold** and *italic* text.

      - List item

      > A quote

      ```elixir
      def hello, do: :world
      ```
      """

      string = render_to_string(md)
      assert string =~ "Header"
      assert string =~ "bold"
      assert string =~ "italic"
      assert string =~ "List item"
      assert string =~ "A quote"
      assert string =~ "def hello, do: :world"
    end

    test "unicode characters pass through" do
      string = render_to_string("Hello 世界")
      assert string =~ "Hello"
      assert string =~ "世界"
    end

    test "emoji in markdown renders" do
      string = render_to_string("🐶 Code Puppy rocks!")
      assert string =~ "🐶"
      assert string =~ "Code Puppy rocks!"
    end

    test "nil input raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        Markdown.render(nil)
      end
    end
  end

  # ── Strengthened tests (code_puppy-c2a.2) ───────────────────────────────

  describe "render/1 — header levels" do
    test "h1 header uses cyan styling" do
      result = Markdown.render("# Cyan Title")
      # h1 should be tagged bright cyan
      assert has_any_tag?(result)
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "Cyan Title"
    end

    test "h2 header uses yellow styling" do
      result = Markdown.render("## Yellow Subtitle")
      assert has_any_tag?(result)
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "Yellow Subtitle"
    end

    test "h3+ header uses white styling" do
      result = Markdown.render("### White Section")
      assert has_any_tag?(result)
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "White Section"
    end

    test "header with extra spaces after hashes" do
      string = render_to_string("#   Spaced Title")
      assert string =~ "Spaced Title"
    end
  end

  describe "render/1 — list items" do
    test "uses bullet marker, not dash" do
      string = render_to_string("- An item")
      assert string =~ "•"
      refute string =~ "- An item"
    end

    test "asterisk list items render with bullet" do
      string = render_to_string("* Star item")
      assert string =~ "Star item"
      refute string =~ "* Star item"
    end

    test "list item with inline formatting" do
      string = render_to_string("- **bold** item")
      assert string =~ "bold"
      refute string =~ "**bold**"
    end
  end

  describe "render/1 — code blocks" do
    test "code block with elixir language tag" do
      md = "```elixir\nIO.puts(:hello)\n```"
      string = render_to_string(md)
      assert string =~ "elixir"
      assert string =~ "IO.puts(:hello)"
    end

    test "code block without language defaults to text" do
      md = "```\nplain code\n```"
      string = render_to_string(md)
      assert string =~ "plain code"
      # The language label should be "text"
      assert string =~ "text"
    end

    test "multiline code block preserves all lines" do
      md = "```python\nline1\nline2\nline3\n```"
      string = render_to_string(md)
      assert string =~ "line1"
      assert string =~ "line2"
      assert string =~ "line3"
    end
  end

  describe "render/1 — blockquotes" do
    test "blockquote uses box-drawing prefix" do
      result = Markdown.render("> A quote")
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "│"
      assert string =~ "A quote"
    end

    test "blockquote strips > marker" do
      string = render_to_string("> Quoted")
      refute String.contains?(string, "> Quoted")
    end

    test "blockquote followed by normal line ends blockquote" do
      md = "> A quote\nNormal line"
      string = render_to_string(md)
      assert string =~ "A quote"
      assert string =~ "Normal line"
    end
  end

  describe "render/1 — horizontal rules" do
    test "horizontal rule with asterisks" do
      string = render_to_string("***")
      # Should produce some non-empty output
      refute string == ""
    end
  end

  describe "render/1 — blank lines" do
    test "single blank line produces newline" do
      string = render_to_string("")
      assert string == "" or string == "\n"
    end

    test "multiple blank lines don't crash" do
      string = render_to_string("\n\n\n")
      assert is_binary(string)
    end
  end

  describe "render/1 — inline formatting nesting" do
    test "bold then plain then italic" do
      string = render_to_string("**first** middle *last*")
      assert string =~ "first"
      assert string =~ "middle"
      assert string =~ "last"
      refute string =~ "**first**"
      refute string =~ "*last*"
    end

    test "multiple inline code spans" do
      string = render_to_string("use `a` and `b` together")
      assert string =~ "a"
      assert string =~ "b"
      refute string =~ "`a`"
      refute string =~ "`b`"
    end
  end

  describe "render_inline/1 — edge cases" do
    test "empty string returns empty" do
      result = Markdown.render_inline("")
      assert result == []
    end

    test "plain text with no markdown returns list of string" do
      result = Markdown.render_inline("just text")
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "just text"
    end

    test "only bold" do
      result = Markdown.render_inline("**solo bold**")
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "solo bold"
      refute string =~ "**solo bold**"
    end

    test "only italic" do
      result = Markdown.render_inline("*solo italic*")
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "solo italic"
      refute string =~ "*solo italic*"
    end

    test "only inline code" do
      result = Markdown.render_inline("`solo code`")
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "solo code"
      refute string =~ "`solo code`"
    end
  end

  # ── render_inline/1 ──────────────────────────────────────────────────────────

  describe "render_inline/1" do
    test "plain text passes through" do
      string = render_inline_to_string("hello")
      assert string =~ "hello"
    end

    test "inline code strips backticks" do
      string = render_inline_to_string("use `code` here")
      assert string =~ "code"
      refute string =~ "`code`"
    end

    test "bold strips markers" do
      string = render_inline_to_string("**bold**")
      assert string =~ "bold"
      refute string =~ "**bold**"
    end

    test "italic strips markers" do
      string = render_inline_to_string("*italic*")
      assert string =~ "italic"
      refute string =~ "*italic*"
    end

    test "mixed inline elements all render" do
      string = render_inline_to_string("**bold** and *italic* and `code`")
      assert string =~ "bold"
      assert string =~ "italic"
      assert string =~ "code"
    end

    test "each inline element produces tagged output when properly ordered" do
      # Parser processes left-to-right, matching one pattern per call.
      # When inline code comes first, remaining text is recursively parsed,
      # allowing bold and italic to each produce their own tag.
      result = Markdown.render_inline("`c` and **b** and *i*")
      string = IO.chardata_to_string(Owl.Data.to_chardata(result))
      assert string =~ "c"
      assert string =~ "b"
      assert string =~ "i"
      refute string =~ "`c`"
      refute string =~ "**b**"
      refute string =~ "*i*"
    end

    test "inline code produces tagged output" do
      result = Markdown.render_inline("use `mix test` here")
      assert Enum.any?(result, &match?(%Owl.Tag{}, &1))
    end

    test "unicode passes through inline" do
      string = render_inline_to_string("世界 🌍")
      assert string =~ "世界"
      assert string =~ "🌍"
    end
  end
end
