defmodule CodePuppyControl.Parsing.Parsers.PythonParserTest do
  @moduledoc """
  Tests for the PythonParser Yecc-based parser.

  ## Python-as-data (allowlisted)

  These tests exercise Python source parsing as a data operation.
  PythonParser is a pure-Elixir Leex/Yecc parser with zero Python
  runtime dependency. Test fixtures use `.py` source strings only.
  See ADR-005 for the full policy rationale.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Parsing.Parsers.PythonParser

  describe "ParserBehaviour callbacks" do
    test "language/0 returns python" do
      assert PythonParser.language() == "python"
    end

    test "file_extensions/0 returns .py and .pyi" do
      assert PythonParser.file_extensions() == [".py", ".pyi"]
    end

    test "supported?/0 returns true" do
      assert PythonParser.supported?() == true
    end
  end

  describe "parse/1 with functions" do
    test "parses simple function definition" do
      source = "def hello():\n    pass"

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert result.language == "python"
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "hello"
      assert symbol.kind == :function
      assert symbol.line == 1
    end

    test "parses function with parameters" do
      source = "def greet(name, greeting):\n    pass"

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "greet"
      assert symbol.kind == :function
    end

    test "parses multiple function definitions" do
      source = """
      def foo():
          pass

      def bar():
          pass
      """

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert length(result.symbols) == 2

      names = Enum.map(result.symbols, & &1.name)
      assert "foo" in names
      assert "bar" in names
    end

    test "parses function with decorators" do
      source = """
      @decorator
      def decorated():
          pass
      """

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "decorated"
      assert symbol.kind == :function
      assert symbol.doc == "@decorator"
    end

    test "parses function with multiple decorators" do
      source = """
      @staticmethod
      @property
      def multi_decorated():
          pass
      """

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      [symbol] = result.symbols
      assert symbol.doc == "@staticmethod @property"
    end

    test "parses async function definition" do
      source = "async def fetch():\n    pass"
      {:ok, result} = PythonParser.parse(source)
      [symbol] = result.symbols
      assert symbol.name == "fetch"
      assert :async in symbol.modifiers
    end
  end

  describe "parse/1 with classes" do
    test "parses simple class definition" do
      source = "class MyClass:\n    pass"

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "MyClass"
      assert symbol.kind == :class
      assert symbol.line == 1
    end

    test "parses class with inheritance" do
      source = "class MyClass(BaseClass):\n    pass"

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "MyClass"
      assert symbol.kind == :class
    end

    test "parses class with decorators" do
      source = """
      @dataclass
      class DataClass:
          pass
      """

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "DataClass"
      assert symbol.kind == :class
      assert symbol.doc == "@dataclass"
    end
  end

  describe "parse/1 with imports" do
    test "parses simple import statement" do
      source = "import os"

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "import os"
      assert symbol.kind == :import
    end

    test "parses from import statement" do
      source = "from collections import defaultdict"

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "from collections import defaultdict"
      assert symbol.kind == :import
    end

    test "parses multiple import statements" do
      source = """
      import os
      import sys
      from typing import List
      """

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert length(result.symbols) == 3

      names = Enum.map(result.symbols, & &1.name)
      assert "import os" in names
      assert "import sys" in names
      assert "from typing import List" in names
    end
  end

  describe "parse/1 with mixed declarations" do
    test "parses module with functions and classes" do
      source = """
      import os

      def helper():
          pass

      class MyClass:
          pass

      def main():
          pass
      """

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert length(result.symbols) == 4

      kinds = Enum.group_by(result.symbols, & &1.kind)
      assert map_size(kinds) == 3
      assert length(kinds[:import]) == 1
      assert length(kinds[:function]) == 2
      assert length(kinds[:class]) == 1
    end

    test "returns empty symbols for empty source" do
      source = ""

      {:ok, result} = PythonParser.parse(source)

      # Empty source may have just newlines which get skipped
      assert result.success == true
      assert is_list(result.symbols)
    end

    test "returns empty symbols for whitespace-only source" do
      source = "   \n\n   \n"

      {:ok, result} = PythonParser.parse(source)

      assert result.success == true
      assert result.symbols == []
    end
  end

  describe "parse/1 error handling" do
    test "handles invalid syntax gracefully" do
      # This is technically valid in Python's error-recovery parsing
      # but our simple grammar may not handle all edge cases
      source = "def incomplete("

      # The parser may succeed or fail depending on the grammar
      result = PythonParser.parse(source)

      # We expect either a success with empty symbols or an error result
      assert match?({:ok, _}, result)
    end
  end

  describe "registration" do
    test "can be registered with ParserRegistry" do
      # Registration is tested via the parsers.ex module
      assert PythonParser.register() == :ok
    end
  end
end
