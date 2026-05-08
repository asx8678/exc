defmodule CodePuppyControl.REPL.InputTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.REPL.Input

  describe "display_prompt/1" do
    test "default prompt with agent and model" do
      prompt = Input.display_prompt(agent: "code-puppy", model: "claude-sonnet-4")
      assert prompt =~ "🐶"
      assert prompt =~ "code-puppy"
      assert prompt =~ "claude-sonnet-4"
      assert prompt =~ ">"
    end

    test "multiline continuation prompt" do
      prompt = Input.display_prompt(agent: "code-puppy", model: "gpt-4", multiline: true)
      assert prompt =~ "..."
      refute prompt =~ "🐶"
    end

    test "shortens model names with date suffixes" do
      prompt = Input.display_prompt(agent: "code-puppy", model: "claude-sonnet-4-20250514")
      assert prompt =~ "claude-sonnet-4"
      refute prompt =~ "20250514"
    end

    test "uses defaults when no opts given" do
      prompt = Input.display_prompt([])
      assert prompt =~ "🐶"
      assert prompt =~ "code-puppy"
      assert prompt =~ "default"
    end
  end

  describe "multiline_continue?/1" do
    test "balanced input does not need continuation" do
      refute Input.multiline_continue?("print('hello')")
    end

    test "unclosed parenthesis needs continuation" do
      assert Input.multiline_continue?("def foo(")
    end

    test "unclosed bracket needs continuation" do
      assert Input.multiline_continue?("x = [1, 2,")
    end

    test "unclosed brace needs continuation" do
      assert Input.multiline_continue?("%{a: 1,")
    end

    test "balanced brackets do not need continuation" do
      refute Input.multiline_continue?("[1, 2, 3]")
    end

    test "empty string does not need continuation" do
      refute Input.multiline_continue?("")
    end

    test "delimiters inside strings are ignored" do
      # Parenthesis inside a string literal
      refute Input.multiline_continue?("x = \"hello (world)\"")
    end
  end

  describe "delimiter_depth/1" do
    test "returns 0 for balanced input" do
      assert Input.delimiter_depth("foo(bar)") == 0
    end

    test "returns positive for unclosed delimiters" do
      assert Input.delimiter_depth("foo(") == 1
      assert Input.delimiter_depth("(((") == 3
    end

    test "returns negative for extra closing delimiters" do
      assert Input.delimiter_depth(")") == -1
    end

    test "mixed delimiter types" do
      assert Input.delimiter_depth("([") == 2
      assert Input.delimiter_depth("()[]{}") == 0
    end
  end
end
