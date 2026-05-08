defmodule CodePuppyControl.Parsing.ParserBehaviour do
  @moduledoc """
  Behaviour for language-specific parsers.

  This module defines the contract that all language-specific parsers must implement.
  It provides both a simple stateless interface (`parse/1`) and a stateful interface
  (`init/1`, `parse/2`, `declarations/1`) for more complex parsing scenarios.

  ## Two Parsing Patterns

  ### 1. Simple Stateless Parsing (Recommended for most parsers)

      defmodule MyParser do
        @behaviour CodePuppyControl.Parsing.ParserBehaviour

        @impl true
        def parse(source) do
          # Parse and return structured result
        end

        @impl true
        def language, do: "my_lang"

        @impl true
        def file_extensions, do: [".my", ".myl"]

        @impl true
        def supported?, do: true
      end

  ### 2. Stateful Parsing (For parsers requiring initialization)

      defmodule MyStatefulParser do
        @behaviour CodePuppyControl.Parsing.ParserBehaviour

        @impl true
        def init(opts) do
          # Initialize parser state (e.g., load grammar, configure tree-sitter)
          state = %{grammar: load_grammar(opts[:grammar_path])}
          {:ok, state}
        end

        @impl true
        def parse(source, state) do
          # Parse using state, return updated state
          ast = parse_with_grammar(source, state.grammar)
          {:ok, ast, state}
        end

        @impl true
        def declarations(ast) do
          # Extract declarations from AST
          extract_declarations(ast)
        end

        @impl true
        def language, do: "my_lang"

        @impl true
        def file_extensions, do: [".my"]

        @impl true
        def supported?, do: true
      end

  ## Declaration Types

  The `declaration()` type represents various code constructs:

  - `function_def` - Functions and methods
  - `class_def` - Classes and structs
  - `module_def` - Modules and namespaces
  - `variable_def` - Variables and constants
  - `import_def` - Import/require statements
  - `type_def` - Type definitions (typespecs, interfaces)

  """

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc """
  Symbol representation for a declaration (function, class, module, etc.)

  This is the classic symbol format used for simple extraction.
  """
  @type symbol :: %{
          name: String.t(),
          kind: :function | :class | :module | :method | :import | :constant | :type,
          line: pos_integer(),
          end_line: pos_integer() | nil,
          doc: String.t() | nil,
          children: [symbol()]
        }

  @typedoc """
  Diagnostic message for syntax errors or warnings.
  """
  @type diagnostic :: %{
          line: pos_integer(),
          column: pos_integer(),
          message: String.t(),
          severity: :error | :warning | :info
        }

  @typedoc """
  Complete parse result with symbols, diagnostics, and metadata.

  This is the return type for the simple `parse/1` callback.
  """
  @type parse_result :: %{
          language: String.t(),
          symbols: [symbol()],
          diagnostics: [diagnostic()],
          success: boolean(),
          parse_time_ms: float()
        }

  @typedoc """
  Function or method definition.
  """
  @type function_def :: %{
          name: String.t(),
          kind: :function | :method | :macro | :callback,
          line: pos_integer(),
          end_line: pos_integer() | nil,
          params: [String.t()],
          return_type: String.t() | nil,
          visibility: :public | :private | :protected,
          doc: String.t() | nil,
          decorators: [String.t()]
        }

  @typedoc """
  Class or struct definition.
  """
  @type class_def :: %{
          name: String.t(),
          kind: :class | :struct | :interface | :trait | :protocol,
          line: pos_integer(),
          end_line: pos_integer() | nil,
          parent: String.t() | nil,
          implements: [String.t()],
          visibility: :public | :private | nil,
          doc: String.t() | nil
        }

  @typedoc """
  Module or namespace definition.
  """
  @type module_def :: %{
          name: String.t(),
          kind: :module | :namespace | :package,
          line: pos_integer(),
          end_line: pos_integer() | nil,
          aliases: [String.t()],
          doc: String.t() | nil
        }

  @typedoc """
  Variable or constant definition.
  """
  @type variable_def :: %{
          name: String.t(),
          kind: :variable | :constant | :field | :property,
          line: pos_integer(),
          type: String.t() | nil,
          visibility: :public | :private | :protected | nil,
          doc: String.t() | nil
        }

  @typedoc """
  Import, require, or use statement.
  """
  @type import_def :: %{
          name: String.t(),
          kind: :import | :require | :use | :alias | :include,
          line: pos_integer(),
          source: String.t() | nil,
          symbols: [String.t()] | nil
        }

  @typedoc """
  Type definition (typespec, typedef, interface).
  """
  @type type_def :: %{
          name: String.t(),
          kind: :type | :typedef | :opaque | :interface | :union,
          line: pos_integer(),
          end_line: pos_integer() | nil,
          definition: String.t() | nil,
          doc: String.t() | nil
        }

  @typedoc """
  Union type for all declaration types.

  This is the return type for the `declarations/1` callback.
  """
  @type declaration ::
          function_def() | class_def() | module_def() | variable_def() | import_def() | type_def()

  @typedoc """
  Parser state for stateful parsers.

  The exact structure is defined by each parser implementation.
  """
  @type state :: term()

  @typedoc """
  Abstract Syntax Tree representation.

  The exact structure is defined by each parser implementation.
  Common formats include tree-sitter nodes, Erlang AST, or custom structs.
  """
  @type ast :: term()

  @typedoc """
  Initialization options for parsers.
  """
  @type opts :: keyword()

  @typedoc """
  Error reason for parser failures.
  """
  @type reason :: term()

  # ============================================================================
  # Callbacks - Simple Stateless Interface
  # ============================================================================

  @doc """
  Parse source code and extract symbols and diagnostics.

  This is the primary entry point for simple stateless parsing.

  ## Parameters
    - source: The source code string to parse

  ## Returns
    - `{:ok, parse_result()}` on successful parsing (even with diagnostics)
    - `{:error, term()}` on parse failure
  """
  @callback parse(source :: String.t()) :: {:ok, parse_result()} | {:error, term()}

  @doc """
  Returns the canonical language name this parser handles.

  ## Examples
      iex> MyParser.language()
      "elixir"
  """
  @callback language() :: String.t()

  @doc """
  Returns the list of file extensions this parser supports.

  Extensions should include the leading dot (e.g., ".ex", ".exs").

  ## Examples
      iex> MyParser.file_extensions()
      [".ex", ".exs"]
  """
  @callback file_extensions() :: [String.t()]

  @doc """
  Returns true if this parser is available/supported.

  Some parsers may depend on external libraries or NIFs that
  might not be available at runtime.

  ## Examples
      iex> MyParser.supported?()
      true
  """
  @callback supported?() :: boolean()

  # ============================================================================
  # Callbacks - Stateful Interface
  # ============================================================================

  @doc """
  Initialize parser state with options.

  This callback is optional. Implement it for parsers that require
  initialization (e.g., loading grammars, setting up NIFs).

  ## Parameters
    - opts: Keyword list of initialization options

  ## Returns
    - `{:ok, state}` - Parser initialized successfully
    - `{:error, reason}` - Initialization failed

  ## Examples
      iex> MyParser.init(grammar_path: "/path/to/grammar.wasm")
      {:ok, %{grammar: %Grammar{}, version: "1.0"}}
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, reason()}

  @doc """
  Parse source code using parser state.

  This callback is optional. Implement it for stateful parsing scenarios
  where the parser maintains state between calls.

  ## Parameters
    - source: The source code string to parse
    - state: Current parser state from `init/1` or previous `parse/2`

  ## Returns
    - `{:ok, ast, state}` - Parse successful, returns AST and updated state
    - `{:error, reason}` - Parse failed

  ## Examples
      iex> MyParser.parse("def foo do end", state)
      {:ok, %{type: :function, name: "foo", ...}, state}
  """
  @callback parse(source :: String.t(), state :: state()) ::
              {:ok, ast(), state()} | {:error, reason()}

  @doc """
  Extract declarations from an AST.

  This callback is optional. Implement it to extract structured
  declarations from an AST produced by `parse/2`.

  ## Parameters
    - ast: The abstract syntax tree from `parse/2`

  ## Returns
    A list of declarations (function_def, class_def, module_def, etc.)

  ## Examples
      iex> MyParser.declarations(ast)
      [%{name: "foo", kind: :function, line: 1, ...}]
  """
  @callback declarations(ast :: ast()) :: [declaration()]

  # ============================================================================
  # Optional Callbacks with Defaults
  # ============================================================================

  @doc """
  Clean up parser state.

  Called when the parser is being shut down. Use this to release
  resources (NIFs, file handles, memory).

  ## Parameters
    - state: Current parser state

  ## Returns
    `:ok` on success
  """
  @callback terminate(state :: state()) :: :ok

  # Make stateful callbacks optional - existing parsers only need parse/1, language/0, etc.
  @optional_callbacks [init: 1, parse: 2, declarations: 1, terminate: 1]

  # Make init/1 optional with a default implementation
  defmacro __using__(_opts) do
    quote do
      @behaviour CodePuppyControl.Parsing.ParserBehaviour

      @impl true
      def init(_opts) do
        {:ok, %{}}
      end

      @impl true
      def parse(source, state) do
        # Default implementation delegates to stateless parse/1
        case parse(source) do
          {:ok, result} -> {:ok, result, state}
          {:error, reason} -> {:error, reason}
        end
      end

      @impl true
      def declarations(_ast) do
        # Default implementation returns empty list
        []
      end

      @impl true
      def terminate(_state) do
        :ok
      end

      defoverridable init: 1, parse: 2, declarations: 1, terminate: 1
    end
  end
end
