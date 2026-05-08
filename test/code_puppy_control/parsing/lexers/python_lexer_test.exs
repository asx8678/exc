defmodule CodePuppyControl.Parsing.Lexers.PythonLexerTest do
  @moduledoc """
  Tests for the PythonLexer Leex-based lexer.

  ## Python-as-data (allowlisted)

  These tests exercise Python source tokenization as a data operation.
  PythonLexer is a pure-Elixir Leex lexer with zero Python runtime
  dependency. See ADR-005 for the full policy rationale.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Parsing.Lexers.PythonLexer

  describe "tokenize/1" do
    test "tokenizes simple function definition" do
      source = "def foo(): pass"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:def, 1} in tokens
      assert {:identifier, 1, ~c"foo"} in tokens
      assert {:"(", 1} in tokens
      assert {:")", 1} in tokens
      assert {:":", 1} in tokens
      assert {:pass, 1} in tokens
    end

    test "tokenizes class definition" do
      source = "class Foo:\n    pass"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:class, 1} in tokens
      assert {:identifier, 1, ~c"Foo"} in tokens
      assert {:":", 1} in tokens
      assert {:pass, 2} in tokens
    end

    test "tokenizes import statement" do
      source = "import os"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:import, 1} in tokens
      assert {:identifier, 1, ~c"os"} in tokens
    end

    test "tokenizes from import statement" do
      source = "from os import path"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:from, 1} in tokens
      assert {:identifier, 1, ~c"os"} in tokens
      assert {:import, 1} in tokens
      assert {:identifier, 1, ~c"path"} in tokens
    end

    test "tokenizes import with alias" do
      source = "import numpy as np"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:import, 1} in tokens
      assert {:identifier, 1, ~c"numpy"} in tokens
      assert {:as, 1} in tokens
      assert {:identifier, 1, ~c"np"} in tokens
    end

    test "tokenizes return statement" do
      source = "return x + 1"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:return, 1} in tokens
      assert {:identifier, 1, ~c"x"} in tokens
      assert {:+, 1} in tokens
      assert {:integer, 1, 1} in tokens
    end

    test "tokenizes if/else statement" do
      source = "if x:\n    pass\nelse:\n    pass"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:if, 1} in tokens
      assert {:identifier, 1, ~c"x"} in tokens
      assert {:else, 3} in tokens
      assert {:pass, 2} in tokens
      assert {:pass, 4} in tokens
    end

    test "tokenizes elif statement" do
      source = "if x:\n    pass\nelif y:\n    pass"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:if, 1} in tokens
      assert {:elif, 3} in tokens
    end

    test "tokenizes while loop" do
      source = "while True:\n    break"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:while, 1} in tokens
      assert {true, 1} in tokens
      assert {:break, 2} in tokens
    end

    test "tokenizes for loop" do
      source = "for i in range(10):\n    continue"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:for, 1} in tokens
      assert {:in, 1} in tokens
      assert {:continue, 2} in tokens
    end

    test "tokenizes async/await" do
      source = "async def foo():\n    await bar()"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:async, 1} in tokens
      assert {:await, 2} in tokens
    end

    test "tokenizes with statement" do
      source = "with open(f) as x:\n    pass"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:with, 1} in tokens
      assert {:as, 1} in tokens
    end

    test "tokenizes try/except/finally" do
      source = "try:\n    pass\nexcept:\n    pass\nfinally:\n    pass"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:try, 1} in tokens
      assert {:except, 3} in tokens
      assert {:finally, 5} in tokens
    end

    test "tokenizes integer literals" do
      source = "x = 42"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:identifier, 1, ~c"x"} in tokens
      assert {:=, 1} in tokens
      assert {:integer, 1, 42} in tokens
    end

    test "tokenizes float literals" do
      source = "x = 3.14"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:float, 1, 3.14} in tokens
    end

    test "tokenizes comparison operators" do
      source = "x == y"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:==, 1} in tokens
    end

    test "tokenizes boolean operators" do
      source = "x and y or z"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:and, 1} in tokens
      assert {:or, 1} in tokens
    end

    test "tokenizes not operator" do
      source = "not x"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:not, 1} in tokens
    end

    test "handles empty source" do
      source = ""

      assert {:ok, []} = PythonLexer.tokenize(source)
    end

    test "handles whitespace-only source" do
      source = "   \n   \t"

      assert {:ok, tokens} = PythonLexer.tokenize(source)
      # Should only have newline tokens, whitespace is skipped
      assert {:newline, 1} in tokens
    end

    test "tokenizes string literals (double quotes)" do
      source = ~s{x = "hello world"}

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      string_token =
        Enum.find(tokens, fn
          {:string, 1, _} -> true
          _ -> false
        end)

      assert string_token != nil
    end

    test "tokenizes string literals (single quotes)" do
      source = "x = 'hello world'"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      string_token =
        Enum.find(tokens, fn
          {:string, 1, _} -> true
          _ -> false
        end)

      assert string_token != nil
    end

    test "skips comments" do
      source = "x = 1  # this is a comment"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      # Should have x, =, 1, but not the comment
      assert {:identifier, 1, ~c"x"} in tokens
      assert {:=, 1} in tokens
      assert {:integer, 1, 1} in tokens
      # Comment should be skipped
      refute Enum.any?(tokens, fn
               {:comment, _, _} -> true
               _ -> false
             end)
    end

    test "tokenizes assignment operators" do
      source = "x += 1"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:"+=", 1} in tokens
    end

    test "tokenizes brackets and braces" do
      source = "x[0] = {a: 1}"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:"[", 1} in tokens
      assert {:"]", 1} in tokens
      assert {:"{", 1} in tokens
      assert {:"}", 1} in tokens
    end

    test "tokenizes decorators" do
      source = "@property\ndef foo(self):\n    return self._foo"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:@, 1} in tokens
      assert {:self, 2} in tokens
    end

    test "tokenizes lambda expression" do
      source = "f = lambda x: x * 2"

      assert {:ok, tokens} = PythonLexer.tokenize(source)

      assert {:lambda, 1} in tokens
    end
  end

  describe "tokenize_with_lines/1" do
    test "returns tokens with line info in structured format" do
      source = "x = 42"

      assert {:ok, tokens} = PythonLexer.tokenize_with_lines(source)

      assert %{token: :identifier, line: 1, value: ~c"x"} in tokens
      assert %{token: :=, line: 1} in tokens
      assert %{token: :integer, line: 1, value: 42} in tokens
    end

    test "handles multi-line source" do
      source = "x = 1\ny = 2"

      assert {:ok, tokens} = PythonLexer.tokenize_with_lines(source)

      x_token = Enum.find(tokens, &(&1.token == :identifier and &1.value == ~c"x"))
      y_token = Enum.find(tokens, &(&1.token == :identifier and &1.value == ~c"y"))

      assert x_token.line == 1
      assert y_token.line == 2
    end
  end
end
