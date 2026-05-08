defmodule CodePuppyControl.Parsing.Parsers.RustParser do
  @moduledoc """
  Rust parser using Yecc-generated parser.

  Extracts symbols from Rust source code including:
  - Functions (fn declarations, including async/const)
  - Structs (struct declarations)
  - Enums (enum declarations)
  - Impl blocks (impl and impl Trait for Type)
  - Traits (trait declarations)
  - Modules (mod declarations)
  - Use statements (imports)
  - Type aliases (type declarations)
  - Constants (const declarations)
  - Static items (static declarations)

  This parser uses the Rust lexer (from ) for tokenization
  and a Yecc-generated parser for building the AST.

  ## Examples

      iex> RustParser.parse("fn main() {}")
      {:ok, %{language: "rust", symbols: [%{name: "main", kind: :function, ...}], ...}}

      iex> RustParser.parse("struct Point { x: i32, y: i32 }")
      {:ok, %{language: "rust", symbols: [%{name: "Point", kind: :class, ...}], ...}}

  """
  @behaviour CodePuppyControl.Parsing.ParserBehaviour

  alias CodePuppyControl.Parsing.ParserRegistry
  alias CodePuppyControl.Parsing.Lexers.RustLexer

  # ---------------------------------------------------------------------------
  # ParserBehaviour Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def language, do: "rust"

  @impl true
  def file_extensions, do: [".rs"]

  @impl true
  def supported?, do: true

  @impl true
  def parse(source) when is_binary(source) do
    start = System.monotonic_time(:millisecond)

    with {:ok, tokens} <- RustLexer.tokenize(source),
         {:ok, ast} <- do_parse(tokens) do
      symbols = ast_to_symbols(ast)

      {:ok,
       %{
         language: "rust",
         symbols: symbols,
         diagnostics: [],
         success: true,
         parse_time_ms: System.monotonic_time(:millisecond) - start
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           language: "rust",
           symbols: [],
           diagnostics: [format_error(reason)],
           success: false,
           parse_time_ms: System.monotonic_time(:millisecond) - start
         }}
    end
  end

  # Helper to handle parsing with graceful whitespace handling
  defp do_parse(tokens) do
    case :rust_parser.parse(tokens) do
      {:ok, ast} ->
        {:ok, ast}

      # If parsing fails due to only newlines/whitespace, return empty AST
      {:error, {_, _, _}} = error ->
        # Check if tokens are only newlines
        if Enum.all?(tokens, fn t -> match?({:newline, _}, t) end) do
          {:ok, []}
        else
          error
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Symbol Extraction
  # ---------------------------------------------------------------------------

  @spec ast_to_symbols(list()) :: [map()]
  defp ast_to_symbols(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &node_to_symbol/1)
  end

  # Regular function: {function, line, name, params, attrs, _body}
  defp node_to_symbol({:function, line, name, _params, attrs, _}) do
    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: format_attrs(attrs),
        children: []
      }
    ]
  end

  # Async function: {async_function, line, name, params, attrs, _body}
  defp node_to_symbol({:async_function, line, name, _params, attrs, _}) do
    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: format_attrs([:async | attrs]),
        children: []
      }
    ]
  end

  # Const function: {const_function, line, name, params, attrs, _body}
  defp node_to_symbol({:const_function, line, name, _params, attrs, _}) do
    [
      %{
        name: to_string(name),
        kind: :function,
        line: line,
        end_line: nil,
        doc: format_attrs([:const | attrs]),
        children: []
      }
    ]
  end

  # Struct declaration: {struct, line, name, attrs}
  defp node_to_symbol({:struct, line, name, attrs}) do
    [
      %{
        name: to_string(name),
        kind: :class,
        line: line,
        end_line: nil,
        doc: format_attrs(attrs),
        children: []
      }
    ]
  end

  # Enum declaration: {enum, line, name, attrs}
  defp node_to_symbol({:enum, line, name, attrs}) do
    [
      %{
        name: to_string(name),
        kind: :type,
        line: line,
        end_line: nil,
        doc: format_attrs(attrs),
        children: []
      }
    ]
  end

  # Impl block: {impl, line, type, nil}
  defp node_to_symbol({:impl, line, type, nil}) do
    [
      %{
        name: "impl #{type}",
        kind: :class,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Impl for trait: {impl, line, trait, type}
  defp node_to_symbol({:impl, line, trait, type}) when is_atom(type) do
    [
      %{
        name: "impl #{trait} for #{type}",
        kind: :class,
        line: line,
        end_line: nil,
        doc: nil,
        children: []
      }
    ]
  end

  # Trait declaration: {trait, line, name, attrs}
  defp node_to_symbol({:trait, line, name, attrs}) do
    [
      %{
        name: to_string(name),
        kind: :type,
        line: line,
        end_line: nil,
        doc: format_attrs(attrs),
        children: []
      }
    ]
  end

  # Module declaration (block): {mod, line, name, attrs}
  defp node_to_symbol({:mod, line, name, attrs}) do
    [
      %{
        name: to_string(name),
        kind: :module,
        line: line,
        end_line: nil,
        doc: format_attrs(attrs),
        children: []
      }
    ]
  end

  # Module declaration (file): {mod_file, line, name, attrs}
  defp node_to_symbol({:mod_file, line, name, attrs}) do
    [
      %{
        name: to_string(name),
        kind: :module,
        line: line,
        end_line: line,
        doc: format_attrs([:file | attrs]),
        children: []
      }
    ]
  end

  # Use statement: {use, line, path}
  defp node_to_symbol({:use, line, path}) do
    path_str = format_use_path(path)

    [
      %{
        name: "use #{path_str}",
        kind: :import,
        line: line,
        end_line: line,
        doc: nil,
        children: []
      }
    ]
  end

  # Type alias: {type_alias, line, name, type, attrs}
  defp node_to_symbol({:type_alias, line, name, type, attrs}) when is_list(attrs) do
    doc = format_type_doc(type)
    doc = format_attrs_with_doc(attrs, doc)

    [
      %{
        name: format_type_name(name),
        kind: :type,
        line: line,
        end_line: nil,
        doc: doc,
        children: []
      }
    ]
  end

  # Type alias without attrs: {type_alias, line, name, type}
  defp node_to_symbol({:type_alias, line, name, type}) do
    doc = format_type_doc(type)

    [
      %{
        name: format_type_name(name),
        kind: :type,
        line: line,
        end_line: nil,
        doc: doc,
        children: []
      }
    ]
  end

  # Constant: {const, line, name, type, attrs}
  defp node_to_symbol({:const, line, name, type, attrs}) when is_list(attrs) do
    [
      %{
        name: to_string(name),
        kind: :constant,
        line: line,
        end_line: nil,
        doc: format_attrs_with_doc(attrs, ": #{type}"),
        children: []
      }
    ]
  end

  # Constant without attrs: {const, line, name, type}
  defp node_to_symbol({:const, line, name, type}) do
    [
      %{
        name: to_string(name),
        kind: :constant,
        line: line,
        end_line: nil,
        doc: ": #{type}",
        children: []
      }
    ]
  end

  # Static: {static, line, name, type, attrs}
  defp node_to_symbol({:static, line, name, type, attrs}) when is_list(attrs) do
    [
      %{
        name: to_string(name),
        kind: :constant,
        line: line,
        end_line: nil,
        doc: format_attrs_with_doc(attrs, ": #{type}"),
        children: []
      }
    ]
  end

  # Static without attrs: {static, line, name, type}
  defp node_to_symbol({:static, line, name, type}) do
    [
      %{
        name: to_string(name),
        kind: :constant,
        line: line,
        end_line: nil,
        doc: ": #{type}",
        children: []
      }
    ]
  end

  # Fallback for unrecognized nodes
  defp node_to_symbol(_node), do: []

  # ---------------------------------------------------------------------------
  # Helper Functions
  # ---------------------------------------------------------------------------

  defp format_attrs(attrs) when is_list(attrs) do
    attrs
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp format_attrs(_), do: nil

  defp format_attrs_with_doc(attrs, doc) do
    attrs_str = format_attrs(attrs)

    case {attrs_str, doc} do
      {nil, nil} -> nil
      {nil, d} -> d
      {a, nil} -> a
      {a, d} -> "#{a} #{d}"
    end
  end

  defp format_use_path(path) when is_atom(path) do
    to_string(path)
  end

  defp format_use_path(path) when is_list(path) do
    path
    |> List.flatten()
    |> Enum.map(&to_string/1)
    |> Enum.join("::")
  end

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

  # Format type for type alias doc string
  defp format_type_doc(nil), do: nil

  defp format_type_doc({:generic, name, params}) when is_list(params) do
    params_str = Enum.map_join(params, ", ", &format_type_doc/1)
    "= #{name}<#{params_str}>"
  end

  defp format_type_doc({:generic, name, param}), do: "= #{name}<#{format_type_doc(param)}>"
  defp format_type_doc({:ref, type}), do: "= &#{format_type_doc(type)}"
  defp format_type_doc({:ref_mut, type}), do: "= &mut #{format_type_doc(type)}"
  defp format_type_doc(name) when is_atom(name), do: "= #{name}"
  defp format_type_doc(other), do: "= #{inspect(other)}"

  # Format type name (handles simple names and generic names)
  defp format_type_name({:generic, name, _param}), do: to_string(name)
  defp format_type_name(name) when is_atom(name), do: to_string(name)
  defp format_type_name(other), do: inspect(other)

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
