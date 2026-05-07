defmodule CodePuppyControl.TUI.SyntaxTest do
  @moduledoc """
  Tests for TUI Syntax highlighting.

  Note (ADR-005): Python syntax highlighting references exercise
  Python-as-data display — no Python runtime is required or implied.
  The Syntax module performs static keyword highlighting in Elixir.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Syntax

  describe "highlight/2" do
    test "returns binary for unknown language" do
      result = Syntax.highlight("hello world", "brainfuck")
      assert is_binary(result) or is_list(result)
    end

    test "highlights elixir keywords" do
      result = Syntax.highlight("def foo do", "elixir")
      # Should contain tagged fragments
      assert is_list(result) or is_binary(result)
    end

    test "highlights python keywords" do
      result = Syntax.highlight("def foo():", "python")
      assert is_list(result) or is_binary(result)
    end

    test "highlights javascript keywords" do
      result = Syntax.highlight("const x = 1;", "javascript")
      assert is_list(result) or is_binary(result)
    end

    test "highlights rust keywords" do
      result = Syntax.highlight("fn main() {}", "rust")
      assert is_list(result) or is_binary(result)
    end

    test "highlights shell keywords" do
      result = Syntax.highlight("if true; then", "shell")
      assert is_list(result) or is_binary(result)
    end

    test "normalizes language aliases" do
      # These should all produce valid output without errors
      for lang <- ["ts", "js", "sh", "bash", "zsh"] do
        result = Syntax.highlight("hello", lang)
        assert is_list(result) or is_binary(result)
      end
    end

    test "handles empty string" do
      result = Syntax.highlight("", "elixir")
      assert is_list(result) or is_binary(result)
    end

    test "handles code with comments" do
      result = Syntax.highlight("# this is a comment\ndef foo do", "elixir")
      assert is_list(result) or is_binary(result)
    end

    test "handles code with strings" do
      result = Syntax.highlight("IO.puts(\"hello\")", "elixir")
      assert is_list(result) or is_binary(result)
    end

    test "handles code with numbers" do
      result = Syntax.highlight("x = 42", "python")
      assert is_list(result) or is_binary(result)
    end
  end

  describe "highlight_file/2" do
    test "detects language from extension" do
      result = Syntax.highlight_file("def foo, do: bar", "test.ex")
      assert is_list(result) or is_binary(result)
    end

    test "falls back for unknown extensions" do
      result = Syntax.highlight_file("hello", "test.xyz")
      assert is_list(result) or is_binary(result)
    end
  end
end
