defmodule CodePuppyControl.Parsing.ParserBehaviourTest do
  @moduledoc """
  Tests for the ParserBehaviour types and interface contract.

  These tests verify that the behaviour types work correctly and that
  implementing modules conform to the contract.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Parsing.ParserBehaviour

  # Define a mock parser for testing the behaviour contract
  defmodule MockParser do
    @behaviour ParserBehaviour

    @impl true
    def parse(_source) do
      {:ok,
       %{
         language: "mock",
         symbols: [
           %{
             name: "test",
             kind: :function,
             line: 1,
             end_line: 2,
             doc: nil,
             children: []
           }
         ],
         diagnostics: [],
         success: true,
         parse_time_ms: 0.5
       }}
    end

    @impl true
    def language, do: "mock"

    @impl true
    def file_extensions, do: [".mock", ".mk"]

    @impl true
    def supported?, do: true
  end

  # Define an unsupported parser for testing
  defmodule UnsupportedParser do
    @behaviour ParserBehaviour

    @impl true
    def parse(_source) do
      {:error, :unsupported}
    end

    @impl true
    def language, do: "unsupported"

    @impl true
    def file_extensions, do: [".unsupported"]

    @impl true
    def supported?, do: false
  end

  describe "ParserBehaviour types" do
    test "symbol type has required keys" do
      symbol = %{
        name: "test_function",
        kind: :function,
        line: 10,
        end_line: 20,
        doc: "A test function",
        children: []
      }

      assert is_map(symbol)
      assert symbol.name == "test_function"
      assert symbol.kind == :function
      assert symbol.line == 10
      assert symbol.end_line == 20
      assert symbol.doc == "A test function"
      assert symbol.children == []
    end

    test "symbol type allows nil values for optional fields" do
      symbol = %{
        name: "test",
        kind: :module,
        line: 1,
        end_line: nil,
        doc: nil,
        children: []
      }

      assert symbol.end_line == nil
      assert symbol.doc == nil
    end

    test "symbol type allows nested children" do
      child = %{
        name: "child_method",
        kind: :method,
        line: 5,
        end_line: 10,
        doc: nil,
        children: []
      }

      parent = %{
        name: "ParentClass",
        kind: :class,
        line: 1,
        end_line: 15,
        doc: "Parent class",
        children: [child]
      }

      assert length(parent.children) == 1
      assert hd(parent.children).name == "child_method"
    end

    test "diagnostic type has required keys" do
      diagnostic = %{
        line: 42,
        column: 5,
        message: "Unexpected token",
        severity: :error
      }

      assert diagnostic.line == 42
      assert diagnostic.column == 5
      assert diagnostic.message == "Unexpected token"
      assert diagnostic.severity == :error
    end

    test "diagnostic type supports all severity levels" do
      error = %{line: 1, column: 1, message: "Error", severity: :error}
      warning = %{line: 2, column: 1, message: "Warning", severity: :warning}
      info = %{line: 3, column: 1, message: "Info", severity: :info}

      assert error.severity == :error
      assert warning.severity == :warning
      assert info.severity == :info
    end

    test "parse_result type has required keys" do
      result = %{
        language: "elixir",
        symbols: [],
        diagnostics: [],
        success: true,
        parse_time_ms: 1.23
      }

      assert result.language == "elixir"
      assert result.symbols == []
      assert result.diagnostics == []
      assert result.success == true
      assert result.parse_time_ms == 1.23
    end
  end

  describe "ParserBehaviour implementation contract" do
    test "mock parser implements all callbacks" do
      assert function_exported?(MockParser, :parse, 1)
      assert function_exported?(MockParser, :language, 0)
      assert function_exported?(MockParser, :file_extensions, 0)
      assert function_exported?(MockParser, :supported?, 0)
    end

    test "mock parser returns correct language" do
      assert MockParser.language() == "mock"
    end

    test "mock parser returns correct extensions" do
      assert MockParser.file_extensions() == [".mock", ".mk"]
    end

    test "mock parser reports as supported" do
      assert MockParser.supported?() == true
    end

    test "mock parser returns valid parse result" do
      assert {:ok, result} = MockParser.parse("test source")
      assert result.language == "mock"
      assert is_list(result.symbols)
      assert is_list(result.diagnostics)
      assert result.success == true
      assert is_float(result.parse_time_ms)
    end

    test "unsupported parser reports as not supported" do
      assert UnsupportedParser.supported?() == false
    end

    test "unsupported parser returns error on parse" do
      assert {:error, :unsupported} = UnsupportedParser.parse("test")
    end
  end
end
