defmodule CodePuppyControl.Parsing.ParserUtils do
  @moduledoc """
  Shared utility functions for language parsers.

  This module provides common helper functions that parsers can use for:
  - Source normalization and preprocessing
  - Line/column position calculations
  - String extraction and manipulation
  - Common AST traversal patterns
  - Declaration builders

  ## Usage

      defmodule MyParser do
        import CodePuppyControl.Parsing.ParserUtils

        def parse(source) do
          normalized = normalize_source(source)
          # ... parse logic
        end
      end
  """

  alias CodePuppyControl.Parsing.ParserBehaviour

  # ============================================================================
  # Source Normalization
  # ============================================================================

  @doc """
  Normalize source code for parsing.

  Performs common normalizations:
  - Normalizes line endings (CRLF -> LF)
  - Ensures trailing newline for easier line counting
  - Removes BOM if present

  ## Examples

      iex> ParserUtils.normalize_source("line1\\r\\nline2")
      "line1\\nline2\\n"

      iex> ParserUtils.normalize_source("code")
      "code\\n"
  """
  @spec normalize_source(String.t()) :: String.t()
  def normalize_source(source) when is_binary(source) do
    source
    |> String.replace("\r\n", "\n")
    |> remove_bom()
    |> ensure_trailing_newline()
  end

  @doc """
  Remove UTF-8 BOM if present.
  """
  @spec remove_bom(String.t()) :: String.t()
  def remove_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  def remove_bom(source), do: source

  @doc """
  Ensure source ends with a newline for easier line counting.
  """
  @spec ensure_trailing_newline(String.t()) :: String.t()
  def ensure_trailing_newline(<<>>), do: "\n"

  def ensure_trailing_newline(source) do
    if String.ends_with?(source, "\n"), do: source, else: source <> "\n"
  end

  # ============================================================================
  # Position Calculations
  # ============================================================================

  @doc """
  Calculate line and column from a byte offset in source code.

  ## Parameters
    - source: The source code string
    - offset: Byte offset (0-based)

  ## Returns
    `{line, column}` where both are 1-based

  ## Examples

      iex> ParserUtils.position_at_offset("line1\\nline2", 7)
      {2, 1}
  """
  @spec position_at_offset(String.t(), non_neg_integer()) :: {pos_integer(), pos_integer()}
  def position_at_offset(source, offset) when is_binary(source) and is_integer(offset) do
    {line, col} = do_position_at_offset(source, offset, 1, 1, 0)
    {line, max(1, col)}
  end

  defp do_position_at_offset(_source, offset, line, col, current_offset)
       when current_offset >= offset do
    {line, col}
  end

  defp do_position_at_offset(<<>>, _offset, line, col, _current_offset), do: {line, col}

  defp do_position_at_offset(<<"\n", rest::binary>>, offset, line, _col, current_offset) do
    do_position_at_offset(rest, offset, line + 1, 1, current_offset + 1)
  end

  defp do_position_at_offset(<<char::utf8, rest::binary>>, offset, line, col, current_offset) do
    char_size = byte_size(<<char::utf8>>)

    do_position_at_offset(
      rest,
      offset,
      line,
      col + 1,
      current_offset + char_size
    )
  end

  @doc """
  Get the text of a specific line from source code.

  ## Parameters
    - source: The source code string
    - line: 1-based line number

  ## Returns
    The text of that line (without trailing newline), or nil if line doesn't exist

  ## Examples

      iex> ParserUtils.get_line("line1\\nline2\\n", 2)
      "line2"
  """
  @spec get_line(String.t(), pos_integer()) :: String.t() | nil
  def get_line(source, line) when is_binary(source) and line > 0 do
    source
    |> String.split("\n")
    |> Enum.at(line - 1)
  end

  @doc """
  Get the byte offset for the start of a specific line.

  ## Parameters
    - source: The source code string
    - line: 1-based line number

  ## Returns
    Byte offset (0-based) to the start of the line
  """
  @spec line_offset(String.t(), pos_integer()) :: non_neg_integer()
  def line_offset(source, target_line) when is_binary(source) and target_line > 0 do
    do_line_offset(source, target_line, 1, 0)
  end

  defp do_line_offset(_source, 1, _current_line, offset), do: offset

  defp do_line_offset(<<>>, _target_line, _current_line, offset), do: offset

  defp do_line_offset(<<"\n", rest::binary>>, target_line, current_line, offset) do
    if current_line + 1 == target_line do
      offset + 1
    else
      do_line_offset(rest, target_line, current_line + 1, offset + 1)
    end
  end

  defp do_line_offset(<<char::utf8, rest::binary>>, target_line, current_line, offset) do
    char_size = byte_size(<<char::utf8>>)
    do_line_offset(rest, target_line, current_line, offset + char_size)
  end

  # ============================================================================
  # String Helpers
  # ============================================================================

  @doc """
  Extract an identifier name from a string, respecting language-specific rules.

  ## Parameters
    - text: The text to extract from
    - allowed_chars: Additional characters allowed in identifiers (default: "_")

  ## Examples

      iex> ParserUtils.extract_identifier("def my_function():")
      "my_function"

      iex> ParserUtils.extract_identifier("@my_var = 1", "_@")
      "@my_var"
  """
  @spec extract_identifier(String.t(), String.t()) :: String.t()
  def extract_identifier(text, allowed_chars \\ "_") do
    text
    |> String.graphemes()
    |> Enum.take_while(fn char ->
      String.match?(char, ~r/^\w$/) or String.contains?(allowed_chars, char)
    end)
    |> Enum.join()
  end

  @doc """
  Strip common indentation from multi-line strings.

  Useful for normalizing heredocs and docstrings.

  ## Examples

      iex> ParserUtils.strip_indent(\"""
      ...>     line1
      ...>     line2
      ...>   \""")
      "line1\\nline2"
  """
  @spec strip_indent(String.t()) :: String.t()
  def strip_indent(text) when is_binary(text) do
    lines = String.split(text, "\n")

    # Find minimum indentation (excluding empty lines)
    indent =
      lines
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&count_leading_spaces/1)
      |> Enum.min(fn -> 0 end)

    lines
    |> Enum.map(&String.slice(&1, indent..-1))
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp count_leading_spaces(line) do
    line
    |> String.graphemes()
    |> Enum.take_while(&(&1 == " "))
    |> length()
  end

  @doc """
  Sanitize a string for use in display/JSON output.

  Removes control characters and limits length.

  ## Parameters
    - text: The text to sanitize
    - max_length: Maximum length (default: 1000)

  ## Examples

      iex> ParserUtils.sanitize_for_display("hello\\nworld")
      "hello world"
  """
  @spec sanitize_for_display(String.t(), pos_integer()) :: String.t()
  def sanitize_for_display(text, max_length \\ 1000) do
    text
    |> String.replace(~r/[\x00-\x08\x0B-\x0C\x0E-\x1F]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max_length)
  end

  # ============================================================================
  # Declaration Builders
  # ============================================================================

  @doc """
  Build a function declaration struct.

  ## Examples

      iex> ParserUtils.function_def("my_func", 1, 5, ["arg1", "arg2"])
      %{name: "my_func", kind: :function, line: 1, end_line: 5, params: ["arg1", "arg2"], ...}
  """
  @spec function_def(String.t(), pos_integer(), pos_integer() | nil, [String.t()], keyword()) ::
          ParserBehaviour.function_def()
  def function_def(name, line, end_line \\ nil, params \\ [], opts \\ []) do
    %{
      name: name,
      kind: Keyword.get(opts, :kind, :function),
      line: line,
      end_line: end_line,
      params: params,
      return_type: Keyword.get(opts, :return_type),
      visibility: Keyword.get(opts, :visibility, :public),
      doc: Keyword.get(opts, :doc),
      decorators: Keyword.get(opts, :decorators, [])
    }
  end

  @doc """
  Build a class declaration struct.
  """
  @spec class_def(String.t(), pos_integer(), pos_integer() | nil, keyword()) ::
          ParserBehaviour.class_def()
  def class_def(name, line, end_line \\ nil, opts \\ []) do
    %{
      name: name,
      kind: Keyword.get(opts, :kind, :class),
      line: line,
      end_line: end_line,
      parent: Keyword.get(opts, :parent),
      implements: Keyword.get(opts, :implements, []),
      visibility: Keyword.get(opts, :visibility),
      doc: Keyword.get(opts, :doc)
    }
  end

  @doc """
  Build a module declaration struct.
  """
  @spec module_def(String.t(), pos_integer(), pos_integer() | nil, keyword()) ::
          ParserBehaviour.module_def()
  def module_def(name, line, end_line \\ nil, opts \\ []) do
    %{
      name: name,
      kind: Keyword.get(opts, :kind, :module),
      line: line,
      end_line: end_line,
      aliases: Keyword.get(opts, :aliases, []),
      doc: Keyword.get(opts, :doc)
    }
  end

  @doc """
  Build a variable declaration struct.
  """
  @spec variable_def(String.t(), pos_integer(), keyword()) :: ParserBehaviour.variable_def()
  def variable_def(name, line, opts \\ []) do
    %{
      name: name,
      kind: Keyword.get(opts, :kind, :variable),
      line: line,
      type: Keyword.get(opts, :type),
      visibility: Keyword.get(opts, :visibility),
      doc: Keyword.get(opts, :doc)
    }
  end

  @doc """
  Build an import declaration struct.
  """
  @spec import_def(String.t(), pos_integer(), keyword()) :: ParserBehaviour.import_def()
  def import_def(name, line, opts \\ []) do
    %{
      name: name,
      kind: Keyword.get(opts, :kind, :import),
      line: line,
      source: Keyword.get(opts, :source),
      symbols: Keyword.get(opts, :symbols)
    }
  end

  @doc """
  Build a type declaration struct.
  """
  @spec type_def(String.t(), pos_integer(), pos_integer() | nil, keyword()) ::
          ParserBehaviour.type_def()
  def type_def(name, line, end_line \\ nil, opts \\ []) do
    %{
      name: name,
      kind: Keyword.get(opts, :kind, :type),
      line: line,
      end_line: end_line,
      definition: Keyword.get(opts, :definition),
      doc: Keyword.get(opts, :doc)
    }
  end

  # ============================================================================
  # Common AST Operations
  # ============================================================================

  @doc """
  Flatten a nested list of declarations, optionally keeping parent references.

  ## Parameters
    - declarations: Nested list of declarations (with :children key)
    - opts: Options including `:keep_parent` to include parent name in children

  ## Examples

      iex> decls = [%{name: "Mod", children: [%{name: "func"}]}]
      iex> ParserUtils.flatten_declarations(decls)
      [%{name: "Mod"}, %{name: "func"}]
  """
  @spec flatten_declarations([ParserBehaviour.declaration() | map()], keyword()) ::
          [ParserBehaviour.declaration()]
  def flatten_declarations(declarations, opts \\ []) when is_list(declarations) do
    keep_parent = Keyword.get(opts, :keep_parent, false)
    do_flatten(declarations, [], nil, keep_parent)
  end

  defp do_flatten([], acc, _parent, _keep_parent), do: Enum.reverse(acc)

  defp do_flatten([decl | rest], acc, parent, keep_parent) do
    children = Map.get(decl, :children, [])

    # Add parent reference if requested
    decl_with_parent =
      if keep_parent and parent do
        Map.put(decl, :parent, parent)
      else
        decl
      end

    # Remove children for flat representation
    flat_decl = Map.delete(decl_with_parent, :children)

    new_acc = [flat_decl | acc]
    new_acc = do_flatten(children, new_acc, decl.name, keep_parent)

    do_flatten(rest, new_acc, parent, keep_parent)
  end

  @doc """
  Filter declarations by kind.

  ## Examples

      iex> decls = [%{name: "foo", kind: :function}, %{name: "Bar", kind: :class}]
      iex> ParserUtils.filter_by_kind(decls, :function)
      [%{name: "foo", kind: :function}]
  """
  @spec filter_by_kind([ParserBehaviour.declaration()], atom()) :: [ParserBehaviour.declaration()]
  def filter_by_kind(declarations, kind) when is_atom(kind) do
    Enum.filter(declarations, fn decl -> decl.kind == kind end)
  end

  @doc """
  Find a declaration by name (case-sensitive).

  ## Examples

      iex> decls = [%{name: "foo"}, %{name: "bar"}]
      iex> ParserUtils.find_by_name(decls, "foo")
      %{name: "foo"}
  """
  @spec find_by_name([ParserBehaviour.declaration() | map()], String.t()) ::
          ParserBehaviour.declaration() | map() | nil
  def find_by_name(declarations, name) when is_binary(name) do
    Enum.find(declarations, fn decl -> decl.name == name end)
  end

  @doc """
  Get all declaration names.

  ## Examples

      iex> ParserUtils.declaration_names([%{name: "foo"}, %{name: "bar"}])
      ["foo", "bar"]
  """
  @spec declaration_names([ParserBehaviour.declaration() | map()]) :: [String.t()]
  def declaration_names(declarations) do
    Enum.map(declarations, & &1.name)
  end

  @doc """
  Group declarations by their kind.

  ## Examples

      iex> decls = [%{name: "foo", kind: :function}, %{name: "Bar", kind: :class}]
      iex> ParserUtils.group_by_kind(decls)
      %{function: [%{...}], class: [%{...}]}
  """
  @spec group_by_kind([ParserBehaviour.declaration()]) :: %{
          atom() => [ParserBehaviour.declaration()]
        }
  def group_by_kind(declarations) do
    Enum.group_by(declarations, & &1.kind)
  end

  # ============================================================================
  # Parse Result Helpers
  # ============================================================================

  @doc """
  Build a successful parse result.

  ## Examples

      iex> ParserUtils.success_result("python", [%{name: "foo"}], 1.5)
      %{language: "python", symbols: [%{name: "foo"}], success: true, parse_time_ms: 1.5, diagnostics: []}
  """
  @spec success_result(String.t(), [ParserBehaviour.symbol()], float(), keyword()) ::
          ParserBehaviour.parse_result()
  def success_result(language, symbols, parse_time_ms, opts \\ []) do
    %{
      language: language,
      symbols: symbols,
      diagnostics: Keyword.get(opts, :diagnostics, []),
      success: true,
      parse_time_ms: parse_time_ms
    }
  end

  @doc """
  Build a failed parse result with diagnostics.

  ## Examples

      iex> ParserUtils.error_result("python", [{:error, "Syntax error"}], 0.5)
      %{language: "python", symbols: [], success: false, parse_time_ms: 0.5, diagnostics: [...]}
  """
  @spec error_result(String.t(), [ParserBehaviour.diagnostic()], float()) ::
          ParserBehaviour.parse_result()
  def error_result(language, diagnostics, parse_time_ms) do
    %{
      language: language,
      symbols: [],
      diagnostics: diagnostics,
      success: false,
      parse_time_ms: parse_time_ms
    }
  end

  @doc """
  Create a diagnostic from raw error information.

  ## Examples

      iex> ParserUtils.diagnostic_from_error(1, 5, "syntax error", :error)
      %{line: 1, column: 5, message: "syntax error", severity: :error}
  """
  @spec diagnostic_from_error(pos_integer(), pos_integer(), String.t(), atom()) ::
          ParserBehaviour.diagnostic()
  def diagnostic_from_error(line, column, message, severity) do
    %{
      line: line,
      column: column,
      message: message,
      severity: severity
    }
  end

  @doc """
  Merge multiple parse results (e.g., from partial parses).

  Concatenates symbols and diagnostics, uses max time.
  """
  @spec merge_results([ParserBehaviour.parse_result()]) :: ParserBehaviour.parse_result()
  def merge_results(results) when is_list(results) do
    base = %{
      language: "",
      symbols: [],
      diagnostics: [],
      success: true,
      parse_time_ms: 0.0
    }

    Enum.reduce(results, base, fn result, acc ->
      %{
        language: result.language || acc.language,
        symbols: acc.symbols ++ result.symbols,
        diagnostics: acc.diagnostics ++ result.diagnostics,
        success: acc.success and result.success,
        parse_time_ms: max(acc.parse_time_ms, result.parse_time_ms)
      }
    end)
  end
end
