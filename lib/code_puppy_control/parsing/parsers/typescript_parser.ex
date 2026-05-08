defmodule CodePuppyControl.Parsing.Parsers.TypeScriptParser do
  @moduledoc """
  TypeScript parser extending JavaScript with TypeScript-specific syntax.

  This parser uses Leex-generated lexer (`:typescript_lexer`) and
  Yecc-generated parser (`:typescript_parser`) to extract declarations
  from TypeScript source code.

  ## Supported TypeScript Syntax

    * **Interfaces**: `interface User { name: string }`
    * **Type Aliases**: `type ID = string`
    * **Enums**: `enum Color { Red, Green, Blue }`
    * **Abstract Classes**: `abstract class Animal`
    * **Class with Implements**: `class MyClass implements MyInterface`
    * **Access Modifiers**: `public`, `private`, `protected`, `readonly`
    * **All JavaScript features**: functions, classes, imports/exports, etc.

  ## Examples

      iex> TypeScriptParser.parse("interface Point { x: number; }")
      {:ok, %{
        language: "typescript",
        symbols: [%{name: "Point", kind: :interface, line: 1, ...}],
        ...
      }}

  ## ParserBehaviour Implementation

  This module implements `CodePuppyControl.Parsing.ParserBehaviour` and
  can be registered with `ParserRegistry`.
  """

  @behaviour CodePuppyControl.Parsing.ParserBehaviour

  alias CodePuppyControl.Parsing.ParserRegistry

  # Token mapping from lexer tokens to Yecc token names
  # This ensures Yecc gets the expected atom token types
  @token_map %{
    # Keywords
    function: :function,
    class: :class,
    const: :const,
    let: :let,
    var: :var,
    import: :import,
    export: :export,
    from: :from,
    default: :default,
    async: :async,
    static: :static_token,
    extends: :extends_token,

    # TypeScript-specific keywords
    interface: :interface,
    type: :type,
    enum: :enum,
    namespace: :namespace,
    declare: :declare,
    abstract: :abstract,
    implements: :implements,
    readonly: :readonly,
    private: :private,
    public: :public,
    protected: :protected,

    # Delimiters
    lparen: :lparen,
    rparen: :rparen,
    lbrace: :lbrace,
    rbrace: :rbrace,
    lbracket: :lbracket,
    rbracket: :rbracket,
    comma: :comma,
    semicolon: :semicolon,
    assign: :assign,
    arrow: :arrow,
    colon: :colon,

    # Other
    identifier: :identifier,
    string: :string,
    integer: :integer,
    float: :float
  }

  @impl true
  def language, do: "typescript"

  @impl true
  def file_extensions, do: [".ts", ".mts", ".cts"]

  @impl true
  def supported?, do: true

  @impl true
  def parse(source) when is_binary(source) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, tokens} <- tokenize(source),
         {:ok, declarations} <- parse_tokens(tokens) do
      symbols = declarations_to_symbols(declarations)

      parse_time_ms = System.monotonic_time(:millisecond) - start_time

      {:ok,
       %{
         language: "typescript",
         symbols: symbols,
         diagnostics: [],
         success: true,
         parse_time_ms: parse_time_ms
       }}
    else
      {:error, reason} ->
        parse_time_ms = System.monotonic_time(:millisecond) - start_time

        {:ok,
         %{
           language: "typescript",
           symbols: [],
           diagnostics: [format_error(reason)],
           success: false,
           parse_time_ms: parse_time_ms
         }}
    end
  end

  @doc """
  Tokenize TypeScript source code using the TypeScript lexer.

  ## Parameters

    * `source` - Binary string containing TypeScript source code

  ## Returns

    * `{:ok, tokens}` - List of tokens in Yecc-compatible format
    * `{:error, reason}` - Error tuple with error info
  """
  @spec tokenize(String.t()) :: {:ok, [term()]} | {:error, term()}
  def tokenize(source) when is_binary(source) do
    case CodePuppyControl.Parsing.Lexers.TypeScriptLexer.tokenize(source) do
      {:ok, tokens} ->
        # Convert lexer tokens to Yecc-compatible format
        yecc_tokens =
          tokens
          |> Enum.map(&convert_token/1)
          |> Enum.reject(&is_nil/1)

        {:ok, yecc_tokens}

      {:error, reason} ->
        {:error, {:tokenization_error, reason}}
    end
  end

  @doc """
  Parse tokens using the Yecc-generated parser.

  ## Parameters

    * `tokens` - List of tokens in Yecc-compatible format

  ## Returns

    * `{:ok, declarations}` - List of parsed declarations
    * `{:error, reason}` - Error tuple with parse error info
  """
  @spec parse_tokens([term()]) :: {:ok, [term()]} | {:error, term()}
  def parse_tokens(tokens) do
    case :typescript_parser.parse(tokens) do
      {:ok, declarations} ->
        {:ok, declarations}

      {:error, {line, module, message}} ->
        {:error, {:parse_error, line, module, message}}

      {:error, reason} ->
        {:error, {:parse_error, reason}}
    end
  end

  @doc """
  Registers this parser with the ParserRegistry.
  Call this during application startup.
  """
  @spec register() :: :ok | {:error, :unsupported | :invalid_module}
  def register do
    ParserRegistry.register(__MODULE__)
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  # Convert lexer tokens to Yecc-compatible format
  # Yecc expects: {TokenType, Line} or {TokenType, Line, Value}
  # Return nil for tokens we want to skip

  # Skip certain tokens that aren't part of declarations
  defp convert_token({:newline, _line}), do: nil
  defp convert_token({:semicolon, _line}), do: nil

  defp convert_token({token_type, line}) do
    yecc_type = Map.get(@token_map, token_type, token_type)
    {yecc_type, line}
  end

  defp convert_token({token_type, line, value}) when is_list(value) do
    yecc_type = Map.get(@token_map, token_type, token_type)
    {yecc_type, line, value}
  end

  defp convert_token({token_type, line, value}) do
    yecc_type = Map.get(@token_map, token_type, token_type)
    {yecc_type, line, value}
  end

  # Catch-all for unexpected token formats
  defp convert_token(_), do: nil

  # Convert parser declarations to symbol format
  defp declarations_to_symbols(declarations) when is_list(declarations) do
    Enum.flat_map(declarations, &declaration_to_symbol/1)
  end

  # Function declaration
  defp declaration_to_symbol({:function, line, name, _params}) do
    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Async function declaration
  defp declaration_to_symbol({:async_function, line, name, _params}) do
    [
      %{
        name: "async #{name}",
        kind: :function,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Class declaration
  defp declaration_to_symbol({:class, line, name}) do
    [
      %{
        name: to_string(name),
        kind: :class,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Class with extends clause
  defp declaration_to_symbol({:class_extends, line, name, parent}) do
    [
      %{
        name: "#{name} extends #{parent}",
        kind: :class,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Class with implements clause (TypeScript-specific)
  defp declaration_to_symbol({:class_implements, line, name, interface}) do
    [
      %{
        name: "#{name} implements #{interface}",
        kind: :class,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Abstract class declaration (TypeScript-specific)
  defp declaration_to_symbol({:abstract_class, line, name}) do
    [
      %{
        name: "abstract #{name}",
        kind: :class,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Interface declaration (TypeScript-specific)
  defp declaration_to_symbol({:interface, line, name}) do
    [
      %{
        name: to_string(name),
        kind: :interface,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Type alias declaration (TypeScript-specific)
  defp declaration_to_symbol({:type_alias, line, name, type_def}) do
    [
      %{
        name: "#{name} = #{type_def}",
        kind: :type_alias,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Enum declaration (TypeScript-specific)
  defp declaration_to_symbol({:enum, line, name}) do
    [
      %{
        name: to_string(name),
        kind: :enum,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Const declaration
  defp declaration_to_symbol({:const, line, name}) do
    [
      %{
        name: to_string(name),
        kind: :constant,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Let declaration
  defp declaration_to_symbol({:let_decl, line, name}) do
    [
      %{
        name: to_string(name),
        kind: :constant,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Var declaration
  defp declaration_to_symbol({:var, line, name}) do
    [
      %{
        name: to_string(name),
        kind: :constant,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Arrow function declaration
  defp declaration_to_symbol({:arrow_fn, line, name, _params}) do
    [
      %{
        name: "#{name} (arrow fn)",
        kind: :function,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Import statement
  defp declaration_to_symbol({:import, line, source, names}) do
    names_str = Enum.join(names, ", ")

    [
      %{
        name: "import {#{names_str}} from '#{source}'",
        kind: :import,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Default import statement
  defp declaration_to_symbol({:import_default, line, source, name}) do
    [
      %{
        name: "import #{name} from '#{source}'",
        kind: :import,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Export default
  defp declaration_to_symbol({:export_default, line}) do
    [
      %{
        name: "export default",
        kind: :import,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Named export
  defp declaration_to_symbol({:export, _line, inner_decl}) do
    inner_symbols = declaration_to_symbol(inner_decl)

    Enum.map(inner_symbols, fn symbol ->
      Map.update!(symbol, :name, &"export #{&1}")
    end)
  end

  # Unknown declaration type - skip
  defp declaration_to_symbol(_other) do
    []
  end

  # Format error for diagnostics
  defp format_error({:tokenization_error, {line, error}}) do
    %{
      severity: :error,
      message: "Tokenization error: #{inspect(error)}",
      line: line
    }
  end

  defp format_error({:parse_error, line, _module, message}) do
    %{
      severity: :error,
      message: "Parse error: #{inspect(message)}",
      line: line
    }
  end

  defp format_error({:parse_error, reason}) do
    %{
      severity: :error,
      message: "Parse error: #{inspect(reason)}",
      line: nil
    }
  end

  defp format_error(reason) do
    %{
      severity: :error,
      message: "Unknown error: #{inspect(reason)}",
      line: nil
    }
  end
end
