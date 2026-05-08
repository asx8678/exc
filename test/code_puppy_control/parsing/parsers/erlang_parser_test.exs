defmodule CodePuppyControl.Parsing.Parsers.ErlangParserTest do
  @moduledoc """
  Tests for the Erlang parser implementation.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Parsing.Parsers.ErlangParser

  describe "behaviour implementation" do
    test "implements ParserBehaviour callbacks" do
      assert function_exported?(ErlangParser, :parse, 1)
      assert function_exported?(ErlangParser, :language, 0)
      assert function_exported?(ErlangParser, :file_extensions, 0)
      assert function_exported?(ErlangParser, :supported?, 0)
    end

    test "language/0 returns erlang" do
      assert ErlangParser.language() == "erlang"
    end

    test "file_extensions/0 returns .erl and .hrl" do
      assert ErlangParser.file_extensions() == [".erl", ".hrl"]
    end

    test "supported?/0 returns true" do
      assert ErlangParser.supported?() == true
    end
  end

  describe "parse/1 - module extraction" do
    test "extracts -module declaration" do
      source = "-module(my_module).\n"

      assert {:ok, result} = ErlangParser.parse(source)
      assert result.language == "erlang"
      assert result.success == true
      assert length(result.symbols) == 1

      [module] = result.symbols
      assert module.name == "my_module"
      assert module.kind == :module
      assert module.line == 1
    end

    test "extracts module with full attribute" do
      source = """
      -module(my_server).
      -export([start/0]).
      """

      assert {:ok, result} = ErlangParser.parse(source)
      assert result.success == true

      module = Enum.find(result.symbols, &(&1.kind == :module))
      assert module.name == "my_server"
      assert module.line == 1
    end
  end

  describe "parse/1 - function extraction" do
    test "extracts simple function definition" do
      source = """
      -module(test).
      hello() ->
          world.
      """

      assert {:ok, result} = ErlangParser.parse(source)
      assert result.success == true

      func = Enum.find(result.symbols, &(&1.kind == :function))
      assert func.name == "hello"
      assert func.line == 2
    end

    test "extracts function with arguments" do
      source = """
      -module(math).
      add(A, B) ->
          A + B.
      """

      assert {:ok, result} = ErlangParser.parse(source)

      func = Enum.find(result.symbols, &(&1.kind == :function))
      assert func.name == "add"
      assert func.line == 2
    end

    test "extracts multiple functions" do
      source = """
      -module(test).
      foo() -> 1.
      bar() -> 2.
      baz() -> 3.
      """

      assert {:ok, result} = ErlangParser.parse(source)
      functions = Enum.filter(result.symbols, &(&1.kind == :function))

      assert length(functions) == 3
      names = Enum.map(functions, & &1.name)
      assert "foo" in names
      assert "bar" in names
      assert "baz" in names
    end

    test "extracts function with when clause" do
      source = """
      -module(test).
      factorial(N) when N > 0 ->
          N * factorial(N - 1).
      """

      assert {:ok, result} = ErlangParser.parse(source)

      func = Enum.find(result.symbols, &(&1.kind == :function))
      assert func.name == "factorial"
    end
  end

  describe "parse/1 - record extraction" do
    test "extracts -record declaration" do
      source = """
      -module(test).
      -record(person, {name, age = 0}).
      """

      assert {:ok, result} = ErlangParser.parse(source)

      record = Enum.find(result.symbols, &(&1.kind == :type))
      assert record.name == "person"
      assert record.line == 2
    end

    test "extracts record with fields" do
      source = """
      -module(test).
      -record(state, {
          counter = 0 :: integer(),
          items = [] :: list()
      }).
      """

      assert {:ok, result} = ErlangParser.parse(source)

      record = Enum.find(result.symbols, &(&1.kind == :type and &1.name == "state"))
      assert record != nil
    end
  end

  describe "parse/1 - type extraction" do
    test "extracts -type declaration" do
      source = """
      -module(test).
      -type my_type() :: atom() | integer().
      """

      assert {:ok, result} = ErlangParser.parse(source)

      type = Enum.find(result.symbols, &(&1.kind == :type and &1.name == "my_type"))
      assert type != nil
      assert type.line == 2
    end

    test "extracts -opaque declaration" do
      source = """
      -module(test).
      -opaque internal_id() :: integer().
      """

      assert {:ok, result} = ErlangParser.parse(source)

      opaque = Enum.find(result.symbols, &(&1.kind == :type and &1.name == "internal_id"))
      assert opaque != nil
    end

    test "extracts multiple type definitions" do
      source = """
      -module(types).
      -type name() :: string().
      -type age() :: non_neg_integer().
      -type person() :: {name(), age()}.
      """

      assert {:ok, result} = ErlangParser.parse(source)
      types = Enum.filter(result.symbols, &(&1.kind == :type))

      assert length(types) >= 3
      names = Enum.map(types, & &1.name)
      assert "name" in names
      assert "age" in names
      assert "person" in names
    end
  end

  describe "parse/1 - complete module parsing" do
    test "parses complete Erlang module with all constructs" do
      source = """
      %% @doc A gen_server implementation
      -module(my_gen_server).
      -behaviour(gen_server).

      %% API
      -export([start_link/0, init/1]).

      -record(state, {counter = 0 :: integer()}).

      -type server_ref() :: pid() | atom().

      -spec start_link() -> {ok, pid()}.
      start_link() ->
          gen_server:start_link(?MODULE, [], []).

      init(_Args) ->
          {ok, #state{counter = 0}}.
      """

      assert {:ok, result} = ErlangParser.parse(source)
      assert result.success == true
      assert is_list(result.symbols)
      assert is_list(result.diagnostics)
      assert result.parse_time_ms >= 0

      # Should find module
      module = Enum.find(result.symbols, &(&1.kind == :module))
      assert module.name == "my_gen_server"

      # Should find record as type
      record = Enum.find(result.symbols, &(&1.kind == :type and &1.name == "state"))
      assert record != nil

      # Should find functions
      functions = Enum.filter(result.symbols, &(&1.kind == :function))
      func_names = Enum.map(functions, & &1.name)
      assert "start_link" in func_names
      assert "init" in func_names
    end
  end

  describe "parse/1 - error handling" do
    test "handles empty source" do
      source = ""

      assert {:ok, result} = ErlangParser.parse(source)
      assert result.language == "erlang"
      assert result.symbols == []
      assert result.success == true
    end

    test "handles syntax errors gracefully" do
      # Missing closing parenthesis
      source = "-module(my_module."

      assert {:ok, result} = ErlangParser.parse(source)
      assert result.success == false
      assert length(result.diagnostics) >= 1

      [diagnostic] = result.diagnostics
      assert diagnostic.severity == :error
      assert is_binary(diagnostic.message)
      assert diagnostic.line > 0
    end

    test "handles invalid token errors" do
      # Invalid character
      source = "-module(@invalid)."

      assert {:ok, result} = ErlangParser.parse(source)
      # Result should indicate failure
      assert result.success == false or result.diagnostics != []
    end

    test "handles whitespace-only source" do
      source = "     \n\n     "

      assert {:ok, result} = ErlangParser.parse(source)
      assert result.language == "erlang"
      assert result.symbols == []
    end

    test "handles comments-only source" do
      source = """
      %% This is just a comment
      %% Another comment
      """

      assert {:ok, result} = ErlangParser.parse(source)
      assert result.language == "erlang"
      assert is_list(result.symbols)
    end
  end

  describe "parse/1 - edge cases" do
    test "handles complex expressions in functions" do
      source = """
      -module(complex).
      complex_function(X) ->
          case X of
              1 -> one;
              2 -> two;
              _ -> other
          end.
      """

      assert {:ok, result} = ErlangParser.parse(source)
      func = Enum.find(result.symbols, &(&1.kind == :function))
      assert func.name == "complex_function"
    end

    test "handles nested records" do
      source = """
      -module(nested).
      -record(outer, {inner :: map()}).
      func() ->
          ok.
      """

      assert {:ok, result} = ErlangParser.parse(source)
      record = Enum.find(result.symbols, &(&1.kind == :type))
      assert record.name == "outer"
    end

    test "handles unicode in atom names" do
      source = """
      -module(unicode).
      'привет'() -> world.
      """

      assert {:ok, result} = ErlangParser.parse(source)
      func = Enum.find(result.symbols, &(&1.kind == :function))
      assert func.name == "привет"
    end
  end
end
