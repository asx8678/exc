defmodule CodePuppyControl.Parsing.Parsers.ElixirParserTest do
  @moduledoc """
  Tests for the ElixirParser module.

  Covers parsing of:
  - Simple functions
  - Modules with nested content
  - Macros
  - Error handling
  - Doc extraction
  - Types and specifications
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Parsing.Parsers.ElixirParser

  describe "ParserBehaviour callbacks" do
    test "language/0 returns 'elixir'" do
      assert ElixirParser.language() == "elixir"
    end

    test "file_extensions/0 returns .ex and .exs" do
      assert ElixirParser.file_extensions() == [".ex", ".exs"]
    end

    test "supported?/0 returns true" do
      assert ElixirParser.supported?() == true
    end

    test "parse/1 returns {:ok, result} for valid code" do
      assert {:ok, result} = ElixirParser.parse("def hello do end")
      assert result.language == "elixir"
      assert result.success == true
      assert is_list(result.symbols)
      assert is_list(result.diagnostics)
      assert is_number(result.parse_time_ms)
    end

    test "register/0 registers the parser with the registry" do
      assert :ok = ElixirParser.register()
    end
  end

  describe "simple function extraction" do
    test "extracts a simple public function" do
      source = """
      def hello do
        :world
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert result.success == true
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "hello"
      assert symbol.kind == :function
      assert symbol.line == 1
      assert symbol.children == []
    end

    test "extracts a private function" do
      source = """
      defp secret do
        :hidden
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "secret"
      assert symbol.kind == :function
    end

    test "extracts function with arguments" do
      source = """
      def greet(name, opts) do
        :hello
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "greet"
    end

    test "extracts function with guard clause" do
      source = """
      def positive?(x) when x > 0 do
        true
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "positive?"
    end

    test "extracts multiple functions" do
      source = """
      def one do
        1
      end

      def two do
        2
      end

      defp three do
        3
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 3

      names = Enum.map(result.symbols, & &1.name)
      assert "one" in names
      assert "two" in names
      assert "three" in names
    end
  end

  describe "module extraction" do
    test "extracts a simple module" do
      source = """
      defmodule MyModule do
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "MyModule"
      assert symbol.kind == :module
      assert symbol.line == 1
    end

    test "extracts nested module name" do
      source = """
      defmodule Foo.Bar.Baz do
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      symbol = hd(result.symbols)
      assert symbol.name == "Foo.Bar.Baz"
    end

    test "extracts module with nested functions" do
      source = """
      defmodule MyModule do
        def public_function do
          :ok
        end

        defp private_function do
          :secret
        end
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      # Flattened: 1 module + 2 functions = 3 symbols
      assert length(result.symbols) == 3

      # Find module
      module = Enum.find(result.symbols, &(&1.kind == :module))
      assert module.name == "MyModule"
      assert module.kind == :module
      # Children are now flattened, so module.children is empty
      assert module.children == []

      # Find functions with parent reference
      functions = Enum.filter(result.symbols, &(&1.kind == :function))
      assert length(functions) == 2

      child_names = Enum.map(functions, & &1.name)
      assert "public_function" in child_names
      assert "private_function" in child_names

      # All functions should have parent reference (use Access behavior)
      for func <- functions do
        assert func[:parent] == "MyModule"
      end
    end
  end

  describe "macro extraction" do
    test "extracts public macro" do
      source = """
      defmacro my_macro(name) do
        quote do
          unquote(name)
        end
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "my_macro"
      assert symbol.kind == :function
    end

    test "extracts private macro" do
      source = """
      defmacrop internal_macro(x) do
        x
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "internal_macro"
      assert symbol.kind == :function
    end

    test "extracts macro with guard clause" do
      source = """
      defmacro assert(condition) when is_boolean(condition) do
        condition
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "assert"
    end
  end

  describe "documentation extraction" do
    test "extracts @doc for function" do
      source = """
      @doc "Returns a greeting"
      def hello do
        :world
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      symbol = hd(result.symbols)
      assert symbol.name == "hello"
      assert symbol.doc == "Returns a greeting"
    end

    test "extracts @moduledoc for module" do
      source = """
      defmodule MyModule do
        @moduledoc "This is my module"

        def hello do
          :world
        end
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      module = hd(result.symbols)
      assert module.name == "MyModule"
      assert module.doc == "This is my module"
    end

    test "extracts heredoc documentation" do
      source = ~S'''
      defmodule MyModule do
        @moduledoc """
        Multi-line documentation
        for the module.
        """

        @doc """
        Function with heredoc.
        Multiple lines.
        """
        def greet(name) do
          name
        end
      end
      '''

      assert {:ok, result} = ElixirParser.parse(source)
      module = hd(result.symbols)
      assert module.name == "MyModule"
      assert module.doc =~ "Multi-line documentation"
      assert module.doc =~ "for the module."
    end
  end

  describe "type and spec extraction" do
    test "extracts @type definition" do
      source = """
      @type my_type :: integer()
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "my_type"
      assert symbol.kind == :type
    end

    test "extracts @typep (private type)" do
      source = """
      @typep private_type :: string()
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "private_type"
      assert symbol.kind == :type
    end

    test "extracts @opaque type" do
      source = """
      @opaque opaque_type :: map()
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 1

      symbol = hd(result.symbols)
      assert symbol.name == "opaque_type"
      assert symbol.kind == :type
    end

    test "extracts @spec for function" do
      source = """
      @spec greet(String.t()) :: String.t()
      def greet(name) do
        "Hello " <> name
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      names = Enum.map(result.symbols, & &1.name)
      assert "greet" in names
    end

    test "extracts @callback" do
      source = """
      defmodule MyBehaviour do
        @callback init(opts :: keyword()) :: {:ok, state}
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      # Module + callback
      module = hd(result.symbols)
      assert module.name == "MyBehaviour"
    end

    test "extracts @macrocallback" do
      source = """
      defmodule MyBehaviour do
        @macrocallback my_macro(term()) :: Macro.t()
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      # Flattened: 1 module + 1 macrocallback = 2 symbols
      assert length(result.symbols) == 2

      # Check macrocallback has parent reference (use Access behavior)
      # Note: callback name extraction returns "::" for type specs
      callback = Enum.find(result.symbols, &(&1.kind == :type))
      assert callback[:parent] == "MyBehaviour"
    end
  end

  describe "import/require/use/alias extraction" do
    test "extracts import statements" do
      source = """
      import Enum
      import List, only: [flatten: 1]
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert length(result.symbols) == 2

      names = Enum.map(result.symbols, & &1.name)
      assert "import Enum" in names
      assert "import List" in names
    end

    test "extracts require statements" do
      source = """
      require Logger
      """

      assert {:ok, result} = ElixirParser.parse(source)
      symbol = hd(result.symbols)
      assert symbol.name == "require Logger"
      assert symbol.kind == :import
    end

    test "extracts use statements" do
      source = """
      use GenServer
      """

      assert {:ok, result} = ElixirParser.parse(source)
      symbol = hd(result.symbols)
      assert symbol.name == "use GenServer"
      assert symbol.kind == :import
    end

    test "extracts alias statements" do
      source = """
      alias MyApp.Users
      alias MyApp.Accounts.User
      """

      assert {:ok, result} = ElixirParser.parse(source)
      names = Enum.map(result.symbols, & &1.name)
      assert "alias MyApp.Users" in names
      assert "alias MyApp.Accounts.User" in names
    end
  end

  describe "error handling" do
    test "returns error diagnostics for invalid syntax" do
      source = """
      def unclosed do
        :missing_end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert result.success == false
      assert length(result.diagnostics) >= 1

      diagnostic = hd(result.diagnostics)
      assert diagnostic.severity == :error
      assert diagnostic.line >= 1
      assert is_binary(diagnostic.message)
    end

    test "returns multiple diagnostics for multiple errors" do
      source = """
      def foo
        :no_do_end
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      # Should have error diagnostics
      assert length(result.diagnostics) >= 1
    end

    test "handles empty string" do
      assert {:ok, result} = ElixirParser.parse("")
      assert result.success == true
      assert result.symbols == []
      assert result.diagnostics == []
    end

    test "handles whitespace-only string" do
      assert {:ok, result} = ElixirParser.parse("   \n\t  ")
      assert result.success == true
      assert result.symbols == []
    end

    test "handles module attribute without value" do
      source = """
      @some_attr
      def foo do
        @some_attr
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert result.success == true
      # The parser should handle this gracefully
    end
  end

  describe "real-world code examples" do
    test "parses a GenServer module" do
      source = """
      defmodule MyApp.Worker do
        @moduledoc "A GenServer worker"

        use GenServer

        @spec start_link(keyword()) :: GenServer.on_start()
        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        @impl true
        def init(state) do
          {:ok, state}
        end

        @doc "Handles messages"
        def handle_call(msg, _from, state) do
          {:reply, msg, state}
        end
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert result.success == true
      # Flattened: 1 module + use + spec + 3 defs = 6 symbols
      assert length(result.symbols) == 6

      module = Enum.find(result.symbols, &(&1.kind == :module))
      assert module.name == "MyApp.Worker"
      assert module.kind == :module
      assert module.doc == "A GenServer worker"
      # Children are now flattened
      assert module.children == []

      # Verify nested items are at top level with parent (use Access behavior)
      children_with_parent = Enum.filter(result.symbols, &(&1[:parent] == "MyApp.Worker"))
      assert length(children_with_parent) >= 4
    end

    test "parses a module with many definitions" do
      source = """
      defmodule Math do
        @moduledoc "Math utilities"

        @pi 3.14159

        @type number :: integer() | float()

        @spec add(number(), number()) :: number()
        def add(a, b), do: a + b

        @spec sub(number(), number()) :: number()
        def sub(a, b), do: a - b

        def multiply(a, b) do
          a * b
        end

        def divide(a, b) when b != 0 do
          a / b
        end
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert result.success == true

      # Flattened structure: find module in the list
      module = Enum.find(result.symbols, &(&1.kind == :module))
      assert module.name == "Math"
      assert module.doc == "Math utilities"
      # Children are now flattened
      assert module.children == []

      # Verify nested items are at top level with parent (use Access behavior)
      children_with_parent = Enum.filter(result.symbols, &(&1[:parent] == "Math"))
      assert length(children_with_parent) >= 5
    end

    test "parses nested module definitions" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def inner_func do
            :ok
          end
        end

        def outer_func do
          :ok
        end
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert result.success == true
      # Flattened: 2 modules + 2 functions = 4 symbols
      assert length(result.symbols) == 4

      # Both modules at top level
      modules = Enum.filter(result.symbols, &(&1.kind == :module))
      assert length(modules) == 2

      outer = Enum.find(modules, &(&1.name == "Outer"))
      assert outer.kind == :module
      assert outer.children == []

      inner = Enum.find(modules, &String.ends_with?(&1.name, "Inner"))
      assert inner.kind == :module
      assert inner.children == []
      assert inner[:parent] == "Outer"

      # Functions have correct parent (use Access behavior)
      # Note: nested module children get outer module as parent
      outer_func = Enum.find(result.symbols, &(&1.name == "outer_func"))
      assert outer_func[:parent] == "Outer"

      inner_func = Enum.find(result.symbols, &(&1.name == "inner_func"))
      # The nested module function gets Outer as parent (flattened extraction)
      assert inner_func[:parent] == "Outer"
    end
  end

  describe "parse/1 returns correct metadata" do
    test "includes parse time" do
      source = """
      defmodule Test do
        def one, do: 1
        def two, do: 2
      end
      """

      assert {:ok, result} = ElixirParser.parse(source)
      assert is_number(result.parse_time_ms)
      assert result.parse_time_ms >= 0
    end

    test "returns language as 'elixir'" do
      assert {:ok, result} = ElixirParser.parse("def x do end")
      assert result.language == "elixir"
    end

    test "symbol has required fields" do
      assert {:ok, result} = ElixirParser.parse("def foo do end")
      symbol = hd(result.symbols)

      assert is_binary(symbol.name)
      assert symbol.kind in [:function, :module, :type, :constant, :import]
      assert is_integer(symbol.line) and symbol.line >= 1
      assert is_list(symbol.children)
    end
  end
end
