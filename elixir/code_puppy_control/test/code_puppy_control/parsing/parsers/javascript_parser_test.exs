defmodule CodePuppyControl.Parsing.Parsers.JavaScriptParserTest do
  @moduledoc """
  Tests for the JavaScript Yecc parser.

  These tests verify correct parsing of:
  - Function declarations (regular and async)
  - Class declarations
  - Variable declarations (const, let, var)
  - Arrow functions
  - Import/export statements
  """
  use ExUnit.Case

  alias CodePuppyControl.Parsing.Parsers.JavaScriptParser

  describe "parse/1 basic functionality" do
    test "parses simple function declaration" do
      source = "function foo() {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert result.language == "javascript"
      assert result.success == true
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "foo"
      assert symbol.kind == :function
      assert symbol.line == 1
    end

    test "parses function with parameters" do
      source = "function add(a, b) {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "add"
      assert symbol.kind == :function
    end

    test "parses async function" do
      source = "async function fetchData() {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "async fetchData"
      assert symbol.kind == :function
    end

    test "parses class declaration" do
      source = "class MyClass {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "MyClass"
      assert symbol.kind == :class
    end
  end

  describe "variable declarations" do
    test "parses const declaration with identifier value" do
      source = "const PI = MathPI"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "PI"
      assert symbol.kind == :constant
    end

    test "parses const declaration with string value" do
      source = ~s(const name = "John")

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "name"
      assert symbol.kind == :constant
    end

    test "parses let declaration" do
      source = "let count = zero"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "count"
      assert symbol.kind == :constant
    end

    test "parses var declaration with identifier value" do
      source = "var data = myData"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "data"
      assert symbol.kind == :constant
    end
  end

  describe "arrow functions" do
    test "parses simple arrow function" do
      source = "const add = () => {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "add (arrow fn)"
      assert symbol.kind == :function
    end

    test "parses arrow function with parameters" do
      source = "const multiply = (a, b) => {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "multiply (arrow fn)"
      assert symbol.kind == :function
    end
  end

  describe "import statements" do
    test "parses default import" do
      source = ~s(import React from 'react')

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      # The source module name is included (quotes stripped by parser, added back by formatter)
      assert symbol.name == ~s(import React from 'react')
      assert symbol.kind == :import
    end

    test "parses named imports" do
      source = ~s(import { useState, useEffect } from 'react')

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      # The source module name is included (quotes stripped by parser, added back by formatter)
      assert symbol.name == ~s(import {useState, useEffect} from 'react')
      assert symbol.kind == :import
    end
  end

  describe "export statements" do
    test "parses bare export default" do
      source = "export default"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export default"
      assert symbol.kind == :import
    end

    test "parses export default with identifier" do
      source = "export default MyComponent"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export default MyComponent"
      assert symbol.kind == :import
    end

    test "parses named export of function" do
      source = "export function foo() {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export foo"
      assert symbol.kind == :function
    end

    test "parses named export of class" do
      source = "export class MyClass {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export MyClass"
      assert symbol.kind == :class
    end
  end

  describe "multiple declarations" do
    test "parses multiple declarations in source" do
      source = """
      function foo() {}
      class Bar {}
      const baz = () => {}
      """

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert length(result.symbols) == 3

      [foo, bar, baz] = result.symbols
      assert foo.name == "foo"
      assert foo.kind == :function
      assert bar.name == "Bar"
      assert bar.kind == :class
      assert baz.name == "baz (arrow fn)"
      assert baz.kind == :function
    end
  end

  describe "ParserBehaviour callbacks" do
    test "language/0 returns 'javascript'" do
      assert JavaScriptParser.language() == "javascript"
    end

    test "file_extensions/0 returns JS extensions" do
      extensions = JavaScriptParser.file_extensions()
      assert ".js" in extensions
      assert ".jsx" in extensions
      assert ".mjs" in extensions
      assert ".cjs" in extensions
    end

    test "supported?/0 returns true" do
      assert JavaScriptParser.supported?() == true
    end
  end

  describe "tokenize/1" do
    test "tokenizes valid JavaScript" do
      source = "function foo() {}"

      assert {:ok, tokens} = JavaScriptParser.tokenize(source)
      assert is_list(tokens)
      assert length(tokens) > 0
    end

    test "returns error for invalid JavaScript" do
      source = ~s("unclosed string)

      assert {:error, {:tokenization_error, _}} = JavaScriptParser.tokenize(source)
    end
  end

  describe "parse_tokens/1" do
    test "parses valid tokens" do
      tokens = [
        {:function, 1},
        {:identifier, 1, 'foo'},
        {:lparen, 1},
        {:rparen, 1},
        {:lbrace, 1},
        {:rbrace, 1}
      ]

      assert {:ok, declarations} = JavaScriptParser.parse_tokens(tokens)
      assert is_list(declarations)
    end

    test "returns error for invalid tokens" do
      # Invalid token sequence
      tokens = [
        {:function, 1},
        # Missing identifier and lparen
        {:rparen, 1}
      ]

      assert {:error, {:parse_error, _, _, _}} = JavaScriptParser.parse_tokens(tokens)
    end
  end

  describe "complex real-world examples" do
    test "parses multiple declarations" do
      source = """
      import React from 'react'
      import { useState } from 'react'

      function Counter() {}

      export default Counter
      """

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert result.success == true
      assert length(result.symbols) >= 3

      # Should have imports and function
      import_symbols = Enum.filter(result.symbols, &(&1.kind == :import))
      function_symbols = Enum.filter(result.symbols, &(&1.kind == :function))

      assert length(import_symbols) >= 1
      assert length(function_symbols) >= 1
    end

    test "parses module with class and exports" do
      source = """
      import helper from 'utils'

      const CONFIG = production

      class Service {}

      export default Service
      """

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert result.success == true

      # Should extract import, const, class
      assert length(result.symbols) >= 3
    end
  end

  describe "diagnostics" do
    test "returns empty diagnostics on successful parse" do
      source = "function foo() {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert result.diagnostics == []
    end
  end

  describe "parse timing" do
    test "includes parse_time_ms in result" do
      source = "function foo() {}"

      assert {:ok, result} = JavaScriptParser.parse(source)
      assert is_float(result.parse_time_ms)
      assert result.parse_time_ms >= 0
    end
  end
end
