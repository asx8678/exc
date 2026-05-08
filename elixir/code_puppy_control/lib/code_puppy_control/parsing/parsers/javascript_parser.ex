defmodule CodePuppyControl.Parsing.Parsers.JavaScriptParser do
  @moduledoc """
  JavaScript parser using Yecc-generated parser.

  This module extracts declarations from JavaScript source code including:
  - Function declarations (regular and async)
  - Class declarations
  - Variable declarations (const, let, var)
  - Arrow functions
  - Import/export statements

  Uses the `:javascript_parser` Yecc module generated from `src/javascript_parser.yrl`.

  ## Usage

      iex> JavaScriptParser.parse("function foo() {} const bar = () => {}")
      {:ok, %{language: "javascript", symbols: [...], diagnostics: [], ...}}

  ## Yecc Integration

  The parser is generated from `src/javascript_parser.yrl` at compile time.
  Use `@external_resource` to ensure recompilation when the `.yrl` file changes.
  """

  @behaviour CodePuppyControl.Parsing.ParserBehaviour

  alias CodePuppyControl.Parsing.ParserRegistry

  @external_resource "src/javascript_parser.yrl"

  # Token mapping from lexer to parser format
  # The Yecc parser expects tokens in the format {TokenType, Line} or {TokenType, Line, Value}
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
    # Delimiters
    lparen: :lparen,
    rparen: :rparen,
    lbrace: :lbrace,
    rbrace: :rbrace,
    comma: :comma,
    semicolon: :semicolon,
    # Operators
    assign: :assign,
    arrow: :arrow,
    # Tokens to pass through (with values)
    identifier: :identifier,
    string: :string,
    integer: :identifier,
    float: :identifier,
    newline: :semicolon
  }

  @impl true
  def parse(source) when is_binary(source) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, tokens} <- tokenize(source),
         {:ok, declarations} <- parse_tokens(tokens) do
      symbols = declarations_to_symbols(declarations)
      end_time = System.monotonic_time(:millisecond)
      parse_time = end_time - start_time

      {:ok,
       %{
         language: language(),
         symbols: symbols,
         diagnostics: [],
         success: true,
         parse_time_ms: parse_time / 1.0
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  catch
    error ->
      {:error, {:parser_exception, error}}
  end

  @impl true
  def language, do: "javascript"

  @impl true
  def file_extensions, do: [".js", ".jsx", ".mjs", ".cjs"]

  @impl true
  def supported?, do: true

  @doc """
  Tokenize JavaScript source code using the JavaScript lexer.

  ## Parameters

    * `source` - Binary string containing JavaScript source code

  ## Returns

    * `{:ok, tokens}` - List of tokens in Yecc-compatible format
    * `{:error, reason}` - Error tuple with error info
  """
  @spec tokenize(String.t()) :: {:ok, [term()]} | {:error, term()}
  def tokenize(source) when is_binary(source) do
    case CodePuppyControl.Parsing.Lexers.JavaScriptLexer.tokenize(source) do
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
    case :javascript_parser.parse(tokens) do
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

  # Export default (bare)
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

  # Export default with identifier value
  defp declaration_to_symbol({:export_default, line, value}) when is_list(value) do
    [
      %{
        name: "export default #{value}",
        kind: :import,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Export default with no value (:none)
  defp declaration_to_symbol({:export_default, line, :none}) do
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
end
