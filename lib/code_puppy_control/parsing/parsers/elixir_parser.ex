defmodule CodePuppyControl.Parsing.Parsers.ElixirParser do
  @moduledoc """
  Elixir parser using `Code.string_to_quoted/2`.

  Extracts symbols from Elixir source code including:
  - Modules (defmodule)
  - Functions (def/defp)
  - Macros (defmacro/defmacrop)
  - Types and typespecs (@type/@spec)
  - Module attributes (@doc, @moduledoc, etc.)

  This parser uses Elixir's built-in tokenizer and parser, making it
  accurate and reliable for syntax error detection.
  """
  @behaviour CodePuppyControl.Parsing.ParserBehaviour

  alias CodePuppyControl.Parsing.ParserRegistry
  alias CodePuppyControl.Parsing.Parsers.ElixirParserHelpers, as: Helpers

  # ---------------------------------------------------------------------------
  # ParserBehaviour Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def language, do: "elixir"

  @impl true
  def file_extensions, do: [".ex", ".exs"]

  @impl true
  def supported?, do: true

  @impl true
  def parse(source) when is_binary(source) do
    start = System.monotonic_time(:millisecond)

    case Code.string_to_quoted(source,
           columns: true,
           token_metadata: true,
           unescape: false
         ) do
      {:ok, ast} ->
        {symbols, _acc} = extract_symbols(ast, [], %{current_module: nil})

        {:ok,
         %{
           language: "elixir",
           symbols: symbols,
           diagnostics: [],
           success: true,
           parse_time_ms: System.monotonic_time(:millisecond) - start
         }}

      {:error, {_line, error_message, _}} ->
        # Format the error message
        formatted_message = Helpers.format_error_message(error_message)

        {:ok,
         %{
           language: "elixir",
           symbols: [],
           diagnostics: [
             %{
               line: Helpers.extract_error_line(error_message),
               column: 1,
               message: formatted_message,
               severity: :error
             }
           ],
           success: false,
           parse_time_ms: System.monotonic_time(:millisecond) - start
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Symbol Extraction
  # ---------------------------------------------------------------------------

  # Top-level AST traversal
  @spec extract_symbols(Macro.t(), [map()], map()) :: {[map()], map()}
  defp extract_symbols(ast, symbols, acc)

  # Handle blocks (do blocks, __block__, etc.)
  defp extract_symbols({:__block__, _meta, contents}, symbols, acc) when is_list(contents) do
    Enum.reduce(contents, {symbols, acc}, fn item, {syms, acc} ->
      extract_symbols(item, syms, acc)
    end)
  end

  # Handle defmodule
  defp extract_symbols(
         {:defmodule, meta, [{:__aliases__, _, module_parts}, [do: module_body]]},
         symbols,
         acc
       ) do
    module_name = Enum.join(module_parts, ".")
    line = meta[:line] || 1
    end_line = meta[:end_line] || meta[:line] || 1

    # Extract nested symbols from module body
    {children, child_acc} = extract_symbols(module_body, [], %{current_module: module_name})

    # Get module doc from child accumulator
    doc = Map.get(child_acc, :module_doc, nil)

    # Module symbol (no children - we flatten them)
    module_symbol = %{
      name: module_name,
      kind: :module,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    # Add parent field to each child and flatten into top-level list
    children_with_parent =
      Enum.map(children, fn child ->
        Map.put(child, :parent, module_name)
      end)

    # Return flattened: module + its children + existing symbols
    {[module_symbol | children_with_parent] ++ symbols, Map.delete(acc, :module_doc)}
  end

  # Handle defmodule with nested __aliases__ (e.g., defmodule Foo.Bar)
  defp extract_symbols(
         {:defmodule, meta, [{:__aliases__, _, module_parts} | rest]},
         symbols,
         acc
       ) do
    module_name = Enum.join(module_parts, ".")
    line = meta[:line] || 1

    # Try to extract from rest (which may contain do: block)
    {children, child_acc} =
      case rest do
        [[do: module_body]] ->
          extract_symbols(module_body, [], %{current_module: module_name})

        _ ->
          {[], %{}}
      end

    # Get module doc from child accumulator if available
    doc = Map.get(child_acc, :module_doc, nil)

    # Module symbol (no children - we flatten them)
    module_symbol = %{
      name: module_name,
      kind: :module,
      line: line,
      end_line: meta[:end_line] || line,
      doc: doc,
      children: []
    }

    # Add parent field to each child and flatten into top-level list
    children_with_parent =
      Enum.map(children, fn child ->
        Map.put(child, :parent, module_name)
      end)

    # Return flattened: module + its children + existing symbols
    {[module_symbol | children_with_parent] ++ symbols, Map.delete(acc, :module_doc)}
  end

  # Handle def with guard clause (when) - MUST come before non-guard patterns
  # because the non-guard pattern is more generic and would match {:when, ...}
  defp extract_symbols(
         {:def, meta, [{:when, _, [{function_name, func_meta, _args} | _guard]} | _rest]},
         symbols,
         acc
       )
       when is_atom(function_name) do
    function_name_str = to_string(function_name)
    line = meta[:line] || func_meta[:line] || 1
    end_line = meta[:end_line] || func_meta[:closing][:line] || line

    doc = Map.get(acc, :doc, nil)

    symbol = %{
      name: function_name_str,
      kind: :function,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    {[symbol | symbols], Map.delete(acc, :doc)}
  end

  # Handle def (public function) without guard
  defp extract_symbols(
         {:def, meta, [{function_name, func_meta, _args} | _rest]},
         symbols,
         acc
       )
       when is_atom(function_name) and function_name != :when do
    function_name_str = to_string(function_name)
    line = meta[:line] || func_meta[:line] || 1
    end_line = meta[:end_line] || func_meta[:closing][:line] || line

    doc = Map.get(acc, :doc, nil)

    symbol = %{
      name: function_name_str,
      kind: :function,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    {[symbol | symbols], Map.delete(acc, :doc)}
  end

  # Handle defp with guard clause - MUST come before non-guard
  defp extract_symbols(
         {:defp, meta, [{:when, _, [{function_name, func_meta, _args} | _guard]} | _rest]},
         symbols,
         acc
       )
       when is_atom(function_name) do
    function_name_str = to_string(function_name)
    line = meta[:line] || func_meta[:line] || 1
    end_line = meta[:end_line] || func_meta[:closing][:line] || line

    doc = Map.get(acc, :doc, nil)

    symbol = %{
      name: function_name_str,
      kind: :function,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    {[symbol | symbols], Map.delete(acc, :doc)}
  end

  # Handle defp (private function) without guard
  defp extract_symbols(
         {:defp, meta, [{function_name, func_meta, _args} | _rest]},
         symbols,
         acc
       )
       when is_atom(function_name) and function_name != :when do
    function_name_str = to_string(function_name)
    line = meta[:line] || func_meta[:line] || 1
    end_line = meta[:end_line] || func_meta[:closing][:line] || line

    doc = Map.get(acc, :doc, nil)

    symbol = %{
      name: function_name_str,
      kind: :function,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    {[symbol | symbols], Map.delete(acc, :doc)}
  end

  # Handle defmacro with guard clause - MUST come before non-guard
  defp extract_symbols(
         {:defmacro, meta, [{:when, _, [{macro_name, macro_meta, _args} | _guard]} | _rest]},
         symbols,
         acc
       )
       when is_atom(macro_name) do
    macro_name_str = to_string(macro_name)
    line = meta[:line] || macro_meta[:line] || 1
    end_line = meta[:end_line] || macro_meta[:closing][:line] || line

    doc = Map.get(acc, :doc, nil)

    symbol = %{
      name: macro_name_str,
      kind: :function,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    {[symbol | symbols], Map.delete(acc, :doc)}
  end

  # Handle defmacro (public macro) without guard
  defp extract_symbols(
         {:defmacro, meta, [{macro_name, macro_meta, _args} | _rest]},
         symbols,
         acc
       )
       when is_atom(macro_name) and macro_name != :when do
    macro_name_str = to_string(macro_name)
    line = meta[:line] || macro_meta[:line] || 1
    end_line = meta[:end_line] || macro_meta[:closing][:line] || line

    doc = Map.get(acc, :doc, nil)

    symbol = %{
      name: macro_name_str,
      kind: :function,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    {[symbol | symbols], Map.delete(acc, :doc)}
  end

  # Handle defmacrop with guard clause - MUST come before non-guard
  defp extract_symbols(
         {:defmacrop, meta, [{:when, _, [{macro_name, macro_meta, _args} | _guard]} | _rest]},
         symbols,
         acc
       )
       when is_atom(macro_name) do
    macro_name_str = to_string(macro_name)
    line = meta[:line] || macro_meta[:line] || 1
    end_line = meta[:end_line] || macro_meta[:closing][:line] || line

    doc = Map.get(acc, :doc, nil)

    symbol = %{
      name: macro_name_str,
      kind: :function,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    {[symbol | symbols], Map.delete(acc, :doc)}
  end

  # Handle defmacrop (private macro) without guard
  defp extract_symbols(
         {:defmacrop, meta, [{macro_name, macro_meta, _args} | _rest]},
         symbols,
         acc
       )
       when is_atom(macro_name) and macro_name != :when do
    macro_name_str = to_string(macro_name)
    line = meta[:line] || macro_meta[:line] || 1
    end_line = meta[:end_line] || macro_meta[:closing][:line] || line

    doc = Map.get(acc, :doc, nil)

    symbol = %{
      name: macro_name_str,
      kind: :function,
      line: line,
      end_line: end_line,
      doc: doc,
      children: []
    }

    {[symbol | symbols], Map.delete(acc, :doc)}
  end

  # Handle @type definition
  # Handle @type, @typep, @opaque (type definitions)
  defp extract_symbols({:@, meta, [{type_attr, _, [type_def]}]}, symbols, acc)
       when type_attr in [:type, :typep, :opaque] do
    {type_name, type_meta, _} = Helpers.extract_type_name(type_def)
    type_name_str = to_string(type_name)
    line = meta[:line] || type_meta[:line] || 1

    symbol = %{
      name: type_name_str,
      kind: :type,
      line: line,
      end_line: meta[:end_line] || line,
      doc: nil,
      children: []
    }

    {[symbol | symbols], acc}
  end

  # Handle @spec (function specification)
  defp extract_symbols({:@, meta, [{:spec, _, [spec_def]}]}, symbols, acc) do
    # Extract function name from spec (handles when clauses)
    func_name = Helpers.extract_spec_name(spec_def)
    line = meta[:line] || 1

    symbol = %{
      name: func_name,
      kind: :type,
      line: line,
      end_line: meta[:end_line] || line,
      doc: nil,
      children: []
    }

    {[symbol | symbols], acc}
  end

  # Handle @doc and @moduledoc (documentation)
  defp extract_symbols({:@, _meta, [{attr, _, [doc_string]}]}, symbols, acc)
       when attr in [:doc, :moduledoc] do
    doc = Helpers.extract_doc_string(doc_string)
    key = if attr == :doc, do: :doc, else: :module_doc
    {symbols, Map.put(acc, key, doc)}
  end

  # Handle @callback and @macrocallback (behaviour callback specifications)
  defp extract_symbols({:@, meta, [{cb_type, _, [callback_def]}]}, symbols, acc)
       when cb_type in [:callback, :macrocallback] do
    callback_name = Helpers.extract_callback_name(callback_def)
    line = meta[:line] || 1

    symbol = %{
      name: callback_name,
      kind: :type,
      line: line,
      end_line: meta[:end_line] || line,
      doc: nil,
      children: []
    }

    {[symbol | symbols], acc}
  end

  # Handle @impl (implementation marker) - skip these
  defp extract_symbols({:@, _meta, [{:impl, _, _}]}, symbols, acc) do
    {symbols, acc}
  end

  # Handle other module attributes (@attr) - extract as constants
  defp extract_symbols({:@, meta, [{attr_name, _, val}]}, symbols, acc)
       when is_atom(attr_name) and is_list(val) do
    # Skip attributes we've already handled
    skip_attrs = [
      :doc,
      :moduledoc,
      :type,
      :typep,
      :opaque,
      :spec,
      :callback,
      :macrocallback,
      :impl
    ]

    if attr_name not in skip_attrs do
      line = meta[:line] || 1
      attr_name_str = "@#{attr_name}"

      symbol = %{
        name: attr_name_str,
        kind: :constant,
        line: line,
        end_line: meta[:end_line] || line,
        doc: nil,
        children: []
      }

      {[symbol | symbols], acc}
    else
      {symbols, acc}
    end
  end

  # Handle @attr with nil value
  defp extract_symbols({:@, meta, [{attr_name, _, nil}]}, symbols, acc) when is_atom(attr_name) do
    skip_attrs = [
      :doc,
      :moduledoc,
      :type,
      :typep,
      :opaque,
      :spec,
      :callback,
      :macrocallback,
      :impl
    ]

    if attr_name not in skip_attrs do
      line = meta[:line] || 1
      attr_name_str = "@#{attr_name}"

      symbol = %{
        name: attr_name_str,
        kind: :constant,
        line: line,
        end_line: meta[:end_line] || line,
        doc: nil,
        children: []
      }

      {[symbol | symbols], acc}
    else
      {symbols, acc}
    end
  end

  # Handle import statements
  # Handle import/require/use statements (similar structure)
  defp extract_symbols({op, meta, [{:__aliases__, _, module_parts} | _]}, symbols, acc)
       when op in [:import, :require, :use] do
    {[build_import_symbol(op, module_parts, meta) | symbols], acc}
  end

  # Handle alias statements
  defp extract_symbols({:alias, meta, [{:__aliases__, _, module_parts}]}, symbols, acc) do
    {[build_import_symbol(:alias, module_parts, meta) | symbols], acc}
  end

  # Handle do blocks with nested content
  defp extract_symbols({:do, _meta, body}, symbols, acc) when is_list(body) do
    {children, _acc} =
      Enum.reduce(body, {[], acc}, fn item, {syms, acc} ->
        extract_symbols(item, syms, acc)
      end)

    # Merge children into symbols, but they should already be in the right place
    {symbols ++ children, acc}
  end

  defp extract_symbols({:do, _meta, body}, symbols, acc) do
    {children, _acc} = extract_symbols(body, [], acc)
    {symbols ++ children, acc}
  end

  # Fallback for any other AST structure - recursively process
  defp extract_symbols(tuple, symbols, acc) when is_tuple(tuple) and tuple_size(tuple) == 3 do
    {func, _meta, args} = tuple

    # Check if this looks like a function call with body
    if is_atom(func) and is_list(args) do
      # Recurse into arguments to find more symbols
      {child_symbols, acc} =
        Enum.reduce(args, {[], acc}, fn arg, {syms, acc} ->
          {new_syms, new_acc} = extract_symbols(arg, [], acc)
          {syms ++ new_syms, new_acc}
        end)

      {symbols ++ child_symbols, acc}
    else
      {symbols, acc}
    end
  end

  # Ignore literals and other non-structural elements
  defp extract_symbols(_other, symbols, acc) do
    {symbols, acc}
  end

  # Helper to build import/require/use/alias symbols
  defp build_import_symbol(op, module_parts, meta) do
    module_name = Enum.join(module_parts, ".")
    line = meta[:line] || 1

    %{
      name: "#{op} #{module_name}",
      kind: :import,
      line: line,
      end_line: meta[:end_line] || line,
      doc: nil,
      children: []
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
