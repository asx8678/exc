defmodule CodePuppyControl.Parsing.Parsers.PythonParser do
  @moduledoc """
  Python source parser (data-only, no Python runtime needed).

  Extracts symbols from Python source code including:
  - Functions (def statements, with async def support)
  - Classes (class statements)
  - Imports (import and from...import statements)
  - Decorators (@decorator syntax with argument support)
  - Type annotations (return type annotations on functions)

  This parser uses the Python lexer (python_lexer.xrl) for tokenization
  and a Yecc-generated parser (python_parser.yrl) for building the AST.

  **Architectural note:** This is a **data-only** parser - it parses Python
  source as structured data for code context, repo indexing, and outline
  extraction. It requires **zero Python runtime**. It is compiled via the
  same [:leex, :yecc] pipeline as all other parsers (Elixir, JS, TS, Rust,
  etc.) and is listed as Python-free in the runtime guarantee.
  See ADR-005 for the full policy rationale.

  ## Examples

      iex> PythonParser.parse("def foo():\n    pass")
      {:ok, %{language: "python", symbols: [%{name: "foo", kind: :function, ...}], ...}}

      iex> PythonParser.parse("async def bar():\n    pass")
      {:ok, %{language: "python", symbols: [%{name: "bar", kind: :function, modifiers: [:async], ...}], ...}}

  """
  @behaviour CodePuppyControl.Parsing.ParserBehaviour

  alias CodePuppyControl.Parsing.ParserRegistry
  alias CodePuppyControl.Parsing.Lexers.PythonLexer

  # ---------------------------------------------------------------------------
  # ParserBehaviour Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def language, do: "python"

  @impl true
  def file_extensions, do: [".py", ".pyi"]

  @impl true
  def supported?, do: true

  @impl true
  def parse(source) when is_binary(source) do
    start = System.monotonic_time(:millisecond)

    with {:ok, tokens} <- PythonLexer.tokenize(source),
         {:ok, ast} <- :python_parser.parse(tokens) do
      symbols = ast_to_symbols(ast)

      {:ok,
       %{
         language: "python",
         symbols: symbols,
         diagnostics: [],
         success: true,
         parse_time_ms: System.monotonic_time(:millisecond) - start
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           language: "python",
           symbols: [],
           diagnostics: [format_error(reason)],
           success: false,
           parse_time_ms: System.monotonic_time(:millisecond) - start
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Symbol Extraction
  # ---------------------------------------------------------------------------

  @spec ast_to_symbols(list()) :: [map()]
  defp ast_to_symbols(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &node_to_symbol/1)
  end

  # Skip :skip atoms (newline placeholders)
  defp node_to_symbol(:skip), do: []

  # Function without decorators: {function, line, name, params, annotation}
  defp node_to_symbol({:function, line, name, _params, nil}) do
    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: nil,
        children: [],
        modifiers: []
      }
    ]
  end

  # Function with async modifier but no decorators: {function, line, name, params, async}
  defp node_to_symbol({:function, line, name, _params, :async}) do
    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: nil,
        children: [],
        modifiers: [:async]
      }
    ]
  end

  # Async function with return annotation: {function, line, name, params, {async, annotation}}
  defp node_to_symbol({:function, line, name, _params, {:async, annotation}}) do
    type_info = format_annotation(annotation)

    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: type_info,
        children: [],
        modifiers: [:async]
      }
    ]
  end

  # Function with return annotation but no decorators
  defp node_to_symbol({:function, line, name, _params, annotation})
       when is_list(annotation) or is_tuple(annotation) do
    type_info = format_annotation(annotation)

    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: type_info,
        children: [],
        modifiers: []
      }
    ]
  end

  defp node_to_symbol({:function, line, name, _params, nil, decorators}) do
    decorator_info = format_decorators(decorators)

    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: decorator_info,
        children: [],
        modifiers: []
      }
    ]
  end

  defp node_to_symbol({:function, line, name, _params, :async, decorators}) do
    decorator_info = format_decorators(decorators)

    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: decorator_info,
        children: [],
        modifiers: [:async]
      }
    ]
  end

  defp node_to_symbol({:function, line, name, _params, annotation, decorators}) do
    type_info = format_annotation(annotation)
    decorator_info = format_decorators(decorators)
    doc = if decorator_info, do: "#{decorator_info} -> #{type_info}", else: type_info

    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: doc,
        children: [],
        modifiers:
          if(is_tuple(annotation) and elem(annotation, 0) == :async, do: [:async], else: [])
      }
    ]
  end

  # Class without decorators and without parents: {class, line, name, params, nil}
  defp node_to_symbol({:class, line, name, params, nil})
       when params in [nil, []] do
    [
      %{
        name: to_string(name),
        kind: :class,
        line: line,
        end_line: nil,
        doc: nil,
        children: [],
        modifiers: []
      }
    ]
  end

  # Class without decorators but with parents: {class, line, name, params, nil}
  defp node_to_symbol({:class, line, name, params, nil})
       when is_list(params) and length(params) > 0 do
    inheritance = format_params(params)

    [
      %{
        name: to_string(name),
        kind: :class,
        line: line,
        end_line: nil,
        doc: if(inheritance, do: "(#{inheritance})", else: nil),
        children: [],
        modifiers: []
      }
    ]
  end

  # Class with decorators: {class, line, name, params, nil, decorators}
  defp node_to_symbol({:class, line, name, _params, nil, decorators}) do
    decorator_info = format_decorators(decorators)

    [
      %{
        name: to_string(name),
        kind: :class,
        line: line,
        end_line: nil,
        doc: decorator_info,
        children: [],
        modifiers: []
      }
    ]
  end

  # Import statement: {import, line, module, nil}
  defp node_to_symbol({:import, line, module, nil}) do
    [
      %{
        name: "import #{module}",
        kind: :import,
        line: line,
        end_line: line,
        doc: nil,
        children: [],
        modifiers: []
      }
    ]
  end

  # Import with alias: {import, line, module, alias}
  defp node_to_symbol({:import, line, module, alias_name}) do
    [
      %{
        name: "import #{module} as #{alias_name}",
        kind: :import,
        line: line,
        end_line: line,
        doc: nil,
        children: [],
        modifiers: []
      }
    ]
  end

  # From import statement: {from_import, line, module, name}
  defp node_to_symbol({:from_import, line, module, name}) do
    [
      %{
        name: "from #{module} import #{name}",
        kind: :import,
        line: line,
        end_line: line,
        doc: nil,
        children: [],
        modifiers: []
      }
    ]
  end

  # From import all: {from_import_all, line, module}
  defp node_to_symbol({:from_import_all, line, module}) do
    [
      %{
        name: "from #{module} import *",
        kind: :import,
        line: line,
        end_line: line,
        doc: nil,
        children: [],
        modifiers: []
      }
    ]
  end

  # Fallback for unrecognized nodes
  defp node_to_symbol(_node) do
    # Log unhandled nodes for debugging during development
    # require Logger
    # Logger.debug("Unhandled Python AST node: #{inspect(_node)}")
    []
  end

  # ---------------------------------------------------------------------------
  # Helper Functions
  # ---------------------------------------------------------------------------

  defp format_decorators(decorators) when is_list(decorators) do
    decorators
    |> Enum.map(fn
      {:decorator, _line, name, []} -> "@#{to_string(name)}"
      {:decorator, _line, name, _args} -> "@#{to_string(name)}(...)"
    end)
    |> Enum.join(" ")
  end

  defp format_decorators(_), do: nil

  defp format_annotation(nil), do: nil
  defp format_annotation(:async), do: nil

  defp format_annotation(annotation) when is_list(annotation) or is_binary(annotation) do
    to_string(annotation)
  end

  defp format_annotation(annotation) when is_tuple(annotation) do
    inspect(annotation)
  end

  defp format_annotation(annotation), do: inspect(annotation)

  defp format_params(params) when is_list(params) do
    params
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end

  defp format_params(_), do: nil

  defp format_error({line, _module, message}) when is_integer(line) do
    %{
      line: line,
      column: 1,
      message: to_string(message),
      severity: :error
    }
  end

  defp format_error(reason) do
    %{
      line: 1,
      column: 1,
      message: "Parse error: #{inspect(reason)}",
      severity: :error
    }
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Registers this parser with the ParserRegistry.
  Call this during application startup.
  """
  @spec register() :: :ok | {:error, :unsupported | :invalid_module}
  def register do
    ParserRegistry.register(__MODULE__)
  end
end
