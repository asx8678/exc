defmodule CodePuppyControl.Parsing.Parsers.TsxParserTest do
  @moduledoc """
  Tests for the TSX Yecc parser.
  """
  use ExUnit.Case

  alias CodePuppyControl.Parsing.Parsers.TsxParser

  describe "ParserBehaviour callbacks" do
    test "language/0 returns tsx" do
      assert TsxParser.language() == "tsx"
    end

    test "file_extensions/0 returns .tsx" do
      assert TsxParser.file_extensions() == [".tsx"]
    end

    test "supported?/0 returns true" do
      assert TsxParser.supported?() == true
    end
  end

  describe "parse/1 TSX handling" do
    test "parses simple function and returns tsx language" do
      source = "function Card() { }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"
      assert result.success == true
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "Card"
      assert symbol.kind == :function
    end

    test "parses arrow function component" do
      source = "const Button = () => { }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      function = Enum.find(result.symbols, &(&1.kind == :function))
      assert function != nil
      assert function.name == "Button (arrow fn)"
    end

    test "parses React class component" do
      source = "class MyComponent extends Component { }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      class = Enum.find(result.symbols, &(&1.kind == :class))
      assert class != nil
      assert class.name == "MyComponent extends Component"
    end

    test "parses interface declaration" do
      source = "interface Props { title: string; }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      interface = Enum.find(result.symbols, &(&1.kind == :interface))
      assert interface != nil
      assert interface.name == "Props"
    end

    test "parses type alias" do
      source = "type ButtonVariant = string;"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      type_alias = Enum.find(result.symbols, &(&1.kind == :type_alias))
      assert type_alias != nil
      assert String.starts_with?(type_alias.name, "ButtonVariant")
    end

    test "parses enum" do
      # Note: The TypeScript parser can only handle empty enum bodies
      source = "enum Status { }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      enum = Enum.find(result.symbols, &(&1.kind == :enum))
      assert enum != nil
      assert enum.name == "Status"
    end

    test "parses import statement" do
      source = "import React from 'react';"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      import_ = Enum.find(result.symbols, &(&1.kind == :import))
      assert import_ != nil
      assert import_.name == "import React from 'react'"
    end

    test "parses export default function" do
      source = "export default function Home() { }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      # Export default creates two symbols: the export and the function
      assert length(result.symbols) == 2

      export = Enum.find(result.symbols, &(&1.name == "export default"))
      assert export != nil
      assert export.kind == :import

      function = Enum.find(result.symbols, &(&1.kind == :function))
      assert function != nil
      assert function.name == "Home"
    end

    test "handles JSX elements by replacing with null" do
      source = "function Card() { return <div>Hello</div>; }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      function = Enum.find(result.symbols, &(&1.kind == :function))
      assert function != nil
      assert function.name == "Card"
    end

    test "handles self-closing JSX elements" do
      source = "function ImgTag() { return <img src=\"icon.png\" />; }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      function = Enum.find(result.symbols, &(&1.kind == :function))
      assert function != nil
      assert function.name == "ImgTag"
    end

    test "handles React.Component extends" do
      source = "class MyComponent extends React.Component { }"

      assert {:ok, result} = TsxParser.parse(source)
      assert result.language == "tsx"

      class = Enum.find(result.symbols, &(&1.kind == :class))
      assert class != nil
      # Should be simplified to "extends React"
      assert class.name == "MyComponent extends React"
    end
  end
end
