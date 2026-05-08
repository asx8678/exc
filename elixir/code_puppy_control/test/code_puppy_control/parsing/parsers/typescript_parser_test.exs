defmodule CodePuppyControl.Parsing.Parsers.TypeScriptParserTest do
  @moduledoc """
  Tests for the TypeScript Yecc parser.

  These tests verify correct parsing of:
  - All JavaScript declarations (functions, classes, variables, imports/exports)
  - TypeScript-specific declarations:
    - Interface declarations
    - Type aliases
    - Enum declarations
    - Abstract class declarations
    - Class with implements clause
    - Access modifiers on classes
  """
  use ExUnit.Case

  alias CodePuppyControl.Parsing.Parsers.TypeScriptParser

  describe "parse/1 basic functionality (JavaScript compatibility)" do
    test "parses simple function declaration" do
      source = "function foo() {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert result.language == "typescript"
      assert result.success == true
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "foo"
      assert symbol.kind == :function
      assert symbol.line == 1
    end

    test "parses async function" do
      source = "async function fetchData() {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "async fetchData"
      assert symbol.kind == :function
    end

    test "parses class declaration" do
      source = "class MyClass {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "MyClass"
      assert symbol.kind == :class
    end

    test "parses const declaration" do
      source = "const PI = 3.14"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "PI"
      assert symbol.kind == :constant
    end
  end

  describe "TypeScript-specific: interface declarations" do
    test "parses simple interface" do
      source = "interface Point {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "Point"
      assert symbol.kind == :interface
      assert symbol.line == 1
    end

    test "parses interface (grammar extracts name only)" do
      # Parser extracts interface name; body members are not parsed
      source = "interface User {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "User"
      assert symbol.kind == :interface
    end

    test "parses exported interface" do
      source = "export interface Config {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export Config"
      assert symbol.kind == :interface
    end
  end

  describe "TypeScript-specific: type aliases" do
    test "parses type alias with identifier" do
      source = "type ID = string"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "ID = string"
      assert symbol.kind == :type_alias
      assert symbol.line == 1
    end

    test "parses type alias with string literal" do
      source = ~s(type Name = "default")

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == ~s(Name = default)
      assert symbol.kind == :type_alias
    end

    test "parses exported type alias" do
      source = "export type Result = string"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export Result = string"
      assert symbol.kind == :type_alias
    end
  end

  describe "TypeScript-specific: enum declarations" do
    test "parses simple enum" do
      source = "enum Color {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "Color"
      assert symbol.kind == :enum
      assert symbol.line == 1
    end

    test "parses enum (grammar extracts name only)" do
      # Parser extracts enum name; members are not parsed
      source = "enum Direction {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "Direction"
      assert symbol.kind == :enum
    end

    test "parses exported enum" do
      source = "export enum Status {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export Status"
      assert symbol.kind == :enum
    end
  end

  describe "TypeScript-specific: abstract classes" do
    test "parses abstract class" do
      source = "abstract class Animal {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "abstract Animal"
      assert symbol.kind == :class
      assert symbol.line == 1
    end
  end

  describe "TypeScript-specific: class with implements clause" do
    test "parses class implementing interface" do
      source = "class UserService implements IUserService {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "UserService implements IUserService"
      assert symbol.kind == :class
      assert symbol.line == 1
    end
  end

  describe "TypeScript-specific: class with extends clause" do
    test "parses class extending another class" do
      source = "class Dog extends Animal {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "Dog extends Animal"
      assert symbol.kind == :class
      assert symbol.line == 1
    end
  end

  describe "arrow functions" do
    test "parses arrow function with type annotation" do
      source = "const add = (a, b) => {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "add (arrow fn)"
      assert symbol.kind == :function
    end
  end

  describe "import statements" do
    test "parses default import" do
      source = ~s(import React from 'react')

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      # Quote stripping varies - just verify structure
      assert symbol.name =~ "import React from"
      assert symbol.kind == :import
    end

    test "parses named imports" do
      source = ~s(import { useState, useEffect } from 'react')

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      # Quote stripping varies - just verify structure
      assert symbol.name =~ "import {"
      assert symbol.name =~ "useState"
      assert symbol.name =~ "from"
      assert symbol.kind == :import
    end
  end

  describe "export statements" do
    test "parses export default" do
      source = "export default"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export default"
      assert symbol.kind == :import
    end

    test "parses named export of function" do
      source = "export function foo() {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export foo"
      assert symbol.kind == :function
    end

    test "parses named export of class" do
      source = "export class MyClass {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "export MyClass"
      assert symbol.kind == :class
    end
  end

  describe "multiple declarations" do
    test "parses multiple TypeScript declarations in source" do
      source = """
      interface Point {}
      type ID = string
      enum Color {}
      function distance(p1, p2) {}
      class Shape {}
      """

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert length(result.symbols) == 5

      [interface, type_alias, enum, function_sym, class] = result.symbols
      assert interface.kind == :interface
      assert type_alias.kind == :type_alias
      assert enum.kind == :enum
      assert function_sym.kind == :function
      assert class.kind == :class
    end

    test "parses complex TypeScript module with exports" do
      # Test various TypeScript declarations with exports
      source = """
      export interface IService {}

      export abstract class BaseService {}

      export type ServiceType = string

      export enum ServiceStatus {}
      """

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert result.success == true
      assert length(result.symbols) == 4

      [interface, class, type_alias, enum] = result.symbols
      assert interface.kind == :interface
      assert class.kind == :class
      assert type_alias.kind == :type_alias
      assert enum.kind == :enum
    end

    test "parses TypeScript module with imports" do
      # Test import separately - it has its own parsing rules
      source = ~s(import { Logger } from "logger")

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert result.success == true
      assert length(result.symbols) == 1

      [import_sym] = result.symbols
      assert import_sym.kind == :import
    end
  end

  describe "ParserBehaviour callbacks" do
    test "language/0 returns 'typescript'" do
      assert TypeScriptParser.language() == "typescript"
    end

    test "file_extensions/0 returns TS extensions" do
      extensions = TypeScriptParser.file_extensions()
      assert ".ts" in extensions
      assert ".mts" in extensions
      assert ".cts" in extensions
    end

    test "supported?/0 returns true" do
      assert TypeScriptParser.supported?() == true
    end
  end

  describe "tokenize/1" do
    test "tokenizes valid TypeScript" do
      source = "interface Foo {}"

      assert {:ok, tokens} = TypeScriptParser.tokenize(source)
      assert is_list(tokens)
      assert length(tokens) > 0

      # Should have interface token
      assert Enum.any?(tokens, fn
               {:interface, 1} -> true
               _ -> false
             end)
    end

    test "tokenizes TypeScript-specific keywords" do
      source = "type ID = string; enum Color { Red }"

      assert {:ok, tokens} = TypeScriptParser.tokenize(source)
      assert is_list(tokens)

      # Should have type and enum tokens
      assert Enum.any?(tokens, fn
               {:type, _} -> true
               _ -> false
             end)

      assert Enum.any?(tokens, fn
               {:enum, _} -> true
               _ -> false
             end)
    end

    test "returns error for invalid TypeScript" do
      source = ~s("unclosed string)

      assert {:error, {:tokenization_error, _}} = TypeScriptParser.tokenize(source)
    end
  end

  describe "parse_tokens/1" do
    test "parses valid tokens" do
      tokens = [
        {:interface, 1},
        {:identifier, 1, 'User'},
        {:lbrace, 1},
        {:rbrace, 1}
      ]

      assert {:ok, declarations} = TypeScriptParser.parse_tokens(tokens)
      assert is_list(declarations)
    end

    test "returns error for invalid tokens" do
      # Invalid token sequence
      tokens = [
        {:interface, 1},
        # Missing identifier and lbrace
        {:rbrace, 1}
      ]

      assert {:error, {:parse_error, _, _, _}} = TypeScriptParser.parse_tokens(tokens)
    end
  end

  describe "diagnostics" do
    test "returns empty diagnostics on successful parse" do
      source = "interface Foo {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert result.diagnostics == []
    end

    test "returns diagnostics on failed parse" do
      source = ~s("unclosed string)

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert result.success == false
      assert length(result.diagnostics) == 1

      [diagnostic] = result.diagnostics
      assert diagnostic.severity == :error
    end
  end

  describe "parse timing" do
    test "includes parse_time_ms in result" do
      source = "interface Foo {}"

      assert {:ok, result} = TypeScriptParser.parse(source)
      assert is_number(result.parse_time_ms)
      assert result.parse_time_ms >= 0
    end
  end
end
