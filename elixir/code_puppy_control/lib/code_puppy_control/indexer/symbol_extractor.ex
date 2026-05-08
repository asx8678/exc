defmodule CodePuppyControl.Indexer.SymbolExtractor do
  @moduledoc """
  Extracts symbols from source files using CodePuppyControl.Parsing.Parser
  (with regex fallback for languages without a registered parser).

  Uses tree-sitter based extraction when available, falls back to regex
  for unsupported languages or when tree-sitter parser is unavailable.
  """

  alias CodePuppyControl.Parser

  # Python regex patterns (for fallback)
  @python_class_regex ~r/^class\s+(\w+)/m
  @python_def_regex ~r/^(?:async\s+)?def\s+(\w+)\s*\(/m

  # Elixir regex patterns (for fallback)
  @elixir_def_regex ~r/^\s*(?:def|defp|defmacro|defmacrop)\s+(\w+)/m
  @elixir_module_regex ~r/^\s*defmodule\s+([\w.]+)/m

  @doc """
  Extracts symbols from source code content.

  Uses CodePuppyControl.Parsing.Parser for tree-sitter based extraction when available,
  falls back to regex for unsupported languages or when parser is unavailable.

  ## Parameters

    - content: The source code as a string
    - kind: The file kind/language (determines which parser to use)
    - max_symbols: Maximum number of symbols to return

  ## Returns

  A list of symbol strings like ["class MyClass", "def my_function"]

  ## Examples

      iex> content = "class Foo:\\n def bar():\\n pass"
      iex> SymbolExtractor.extract(content, "python", 10)
      ["class Foo", "def bar"]
  """
  # Updated docstring to reference Parsing.Parser instead of deprecated TurboParseNIF
  @spec extract(String.t(), String.t(), pos_integer()) :: [String.t()]
  def extract(content, kind, max_symbols) do
    case Parser.extract_symbols(content, kind) do
      {:ok, outline} when is_map(outline) ->
        # Convert rich symbol format to simple strings for backward compat
        symbols = outline["symbols"] || []

        symbols
        |> Enum.map(&format_symbol_to_string/1)
        |> Enum.take(max_symbols)

      {:error, _reason} ->
        # Fall back to regex extraction
        extract_symbols_regex(content, kind, max_symbols)
    end
  end

  @doc """
  Extracts symbols using regex only, returning structured format.
  This is called by Parser for regex fallback to avoid circular dependency.

  Returns a list of symbol maps with keys: kind, name, start_line, etc.
  """
  @spec extract_regex_symbols(String.t(), String.t()) :: [map()]
  def extract_regex_symbols(content, language) do
    case language do
      "python" -> extract_python_structured(content)
      "elixir" -> extract_elixir_structured(content)
      _ -> []
    end
  end

  # Convert rich symbol map (NIF format) to legacy string format
  # NIF uses: "class", "function", "method", "module"
  # Legacy format uses: "class", "def", "defmodule"
  defp format_symbol_to_string(%{"kind" => kind, "name" => name}) do
    legacy_kind = nif_kind_to_legacy(kind)
    "#{legacy_kind} #{name}"
  end

  defp format_symbol_to_string(%{kind: kind, name: name}) do
    legacy_kind = nif_kind_to_legacy(kind)
    "#{legacy_kind} #{name}"
  end

  defp format_symbol_to_string(symbol) when is_binary(symbol), do: symbol

  # Convert NIF kind to legacy string format
  defp nif_kind_to_legacy("function"), do: "def"
  defp nif_kind_to_legacy("method"), do: "def"
  defp nif_kind_to_legacy("module"), do: "defmodule"
  defp nif_kind_to_legacy("class"), do: "class"
  defp nif_kind_to_legacy(other), do: other

  # Regex-based fallback extraction (returns string format for backward compat)
  defp extract_symbols_regex(content, "python", max_symbols) do
    extract_python_strings(content, max_symbols)
  end

  defp extract_symbols_regex(content, "elixir", max_symbols) do
    extract_elixir_strings(content, max_symbols)
  end

  defp extract_symbols_regex(_content, _language, _max_symbols) do
    []
  end

  # Structured extraction returning maps (for Parser integration)

  defp extract_python_structured(content) do
    classes =
      @python_class_regex
      |> Regex.scan(content)
      |> Enum.map(fn [_, name] ->
        %{
          "kind" => "class",
          "name" => name,
          "start_line" => 1,
          "end_line" => 1,
          "start_col" => 0,
          "end_col" => 0
        }
      end)

    functions =
      @python_def_regex
      |> Regex.scan(content)
      |> Enum.map(fn [_, name] ->
        %{
          "kind" => "function",
          "name" => name,
          "start_line" => 1,
          "end_line" => 1,
          "start_col" => 0,
          "end_col" => 0
        }
      end)

    classes ++ functions
  end

  defp extract_elixir_structured(content) do
    modules =
      @elixir_module_regex
      |> Regex.scan(content)
      |> Enum.map(fn [_, name] ->
        %{
          "kind" => "module",
          "name" => name,
          "start_line" => 1,
          "end_line" => 1,
          "start_col" => 0,
          "end_col" => 0
        }
      end)

    functions =
      @elixir_def_regex
      |> Regex.scan(content)
      |> Enum.map(fn [_, name] ->
        %{
          "kind" => "function",
          "name" => name,
          "start_line" => 1,
          "end_line" => 1,
          "start_col" => 0,
          "end_col" => 0
        }
      end)

    (modules ++ functions) |> Enum.uniq()
  end

  # Private functions for Python symbol extraction (returns string format)

  defp extract_python_strings(content, max_symbols) do
    classes =
      @python_class_regex
      |> Regex.scan(content)
      |> Enum.map(fn [_, name] -> "class #{name}" end)

    functions =
      @python_def_regex
      |> Regex.scan(content)
      |> Enum.map(fn [_, name] -> "def #{name}" end)

    (classes ++ functions)
    |> Enum.take(max_symbols)
  end

  # Private functions for Elixir symbol extraction (returns string format)

  defp extract_elixir_strings(content, max_symbols) do
    modules =
      @elixir_module_regex
      |> Regex.scan(content)
      |> Enum.map(fn [_, name] -> "defmodule #{name}" end)

    functions =
      @elixir_def_regex
      |> Regex.scan(content)
      |> Enum.map(fn [_, name] -> "def #{name}" end)

    (modules ++ functions)
    |> Enum.uniq()
    |> Enum.take(max_symbols)
  end
end
