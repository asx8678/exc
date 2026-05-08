defmodule CodePuppyControl.Parsing.Parser do
  @moduledoc """
  Unified parsing API. Routes to language-specific parsers via registry.

  This module provides a high-level interface for parsing source code across
  multiple languages. It delegates to language-specific implementations registered
  in `ParserRegistry`.

  ## Usage

      # Parse source code with explicit language
      {:ok, result} = Parser.parse(source, "elixir")

      # Parse a file (language detected from extension)
      {:ok, result} = Parser.parse_file("lib/my_app.ex")

      # Just extract symbols
      {:ok, symbols} = Parser.extract_symbols(source, "python")

      # Check available languages
      languages = Parser.supported_languages()

  ## Result Format

  The parse result is a map with the following structure:

      %{
        language: "elixir",
        symbols: [
          %{
            name: "MyModule",
            kind: :module,
            line: 1,
            end_line: 10,
            doc: "Module documentation",
            children: []
          }
        ],
        diagnostics: [],
        success: true,
        parse_time_ms: 1.23
      }

  """

  alias CodePuppyControl.Parsing.ParserRegistry
  alias CodePuppyControl.Parsing.ParserBehaviour

  @typedoc """
  Parse result from any language parser.
  """
  @type parse_result :: ParserBehaviour.parse_result()

  @typedoc """
  Symbol from parse result.
  """
  @type symbol :: ParserBehaviour.symbol()

  @typedoc """
  Diagnostic message from parse result.
  """
  @type diagnostic :: ParserBehaviour.diagnostic()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Parse source code for a given language.

  ## Parameters
    - source: The source code string to parse
    - language: The canonical language name (e.g., "elixir", "python")

  ## Returns
    - `{:ok, parse_result()}` on successful parsing
    - `{:error, :unsupported_language}` if no parser is registered for the language
    - `{:error, term()}` on parse failure

  ## Examples
      iex> Parser.parse("defmodule Foo do end", "elixir")
      {:ok, %{language: "elixir", symbols: [...], ...}}
  """
  @spec parse(String.t(), String.t()) :: {:ok, parse_result()} | {:error, term()}
  def parse(source, language) when is_binary(source) and is_binary(language) do
    language = normalize_language(language)

    case ParserRegistry.get(language) do
      {:ok, parser_module} ->
        parser_module.parse(source)

      :error ->
        {:error, :unsupported_language}
    end
  end

  @doc """
  Parse a file, detecting language from the file extension.

  ## Parameters
    - path: Path to the source file

  ## Returns
    - `{:ok, parse_result()}` on successful parsing
    - `{:error, :unsupported_language}` if language cannot be determined
    - `{:error, :file_not_found}` if the file doesn't exist
    - `{:error, term()}` on parse failure

  ## Examples
      iex> Parser.parse_file("lib/my_app.ex")
      {:ok, %{language: "elixir", symbols: [...], ...}}
  """
  @spec parse_file(String.t()) :: {:ok, parse_result()} | {:error, term()}
  def parse_file(path) when is_binary(path) do
    extension = Path.extname(path) |> String.downcase()

    with {:ok, parser_module} <- ParserRegistry.for_extension(extension),
         language = parser_module.language(),
         {:ok, source} <- read_file(path) do
      parse(source, language)
    else
      :error ->
        {:error, :unsupported_language}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extract symbols from source code without full parse metadata.

  ## Parameters
    - source: The source code string
    - language: The canonical language name

  ## Returns
    - `{:ok, [symbol()]}` list of extracted symbols
    - `{:error, term()}` on failure

  ## Examples
      iex> Parser.extract_symbols("def foo do end", "elixir")
      {:ok, [%{name: "foo", kind: :function, line: 1, ...}]}
  """
  @spec extract_symbols(String.t(), String.t()) :: {:ok, [symbol()]} | {:error, term()}
  def extract_symbols(source, language) when is_binary(source) and is_binary(language) do
    case parse(source, language) do
      {:ok, %{symbols: symbols}} -> {:ok, symbols}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extract diagnostics (errors, warnings) from source code.

  ## Parameters
    - source: The source code string
    - language: The canonical language name

  ## Returns
    - `{:ok, [diagnostic()]}` list of diagnostics
    - `{:error, term()}` on failure

  ## Examples
      iex> Parser.extract_diagnostics("def foo do", "elixir")
      {:ok, [%{line: 1, message: "missing 'end'", severity: :error}]}
  """
  @spec extract_diagnostics(String.t(), String.t()) :: {:ok, [diagnostic()]} | {:error, term()}
  def extract_diagnostics(source, language) when is_binary(source) and is_binary(language) do
    case parse(source, language) do
      {:ok, %{diagnostics: diagnostics}} -> {:ok, diagnostics}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all supported languages with their registered parsers.

  ## Returns
    A list of `{language, parser_module}` tuples.

  ## Examples
      iex> Parser.supported_languages()
      [{"elixir", MyElixirParser}, {"python", MyPythonParser}]
  """
  @spec supported_languages() :: [{String.t(), module()}]
  def supported_languages() do
    ParserRegistry.list_languages()
  end

  @doc """
  Check if a language is supported (has a registered parser).

  ## Parameters
    - language: The canonical language name or alias

  ## Returns
    `true` if a parser is registered, `false` otherwise.

  ## Examples
      iex> Parser.language_supported?("elixir")
      true

      iex> Parser.language_supported?("brainfuck")
      false
  """
  @spec language_supported?(String.t()) :: boolean()
  def language_supported?(language) when is_binary(language) do
    language = normalize_language(language)

    case ParserRegistry.get(language) do
      {:ok, _} -> true
      :error -> false
    end
  end

  @doc """
  Gets the parser module for a language.

  ## Parameters
    - language: The canonical language name

  ## Returns
    - `{:ok, module}` if found
    - `:error` if not found

  ## Examples
      iex> Parser.get_parser("elixir")
      {:ok, MyElixirParser}
  """
  @spec get_parser(String.t()) :: {:ok, module()} | :error
  def get_parser(language) when is_binary(language) do
    language = normalize_language(language)
    ParserRegistry.get(language)
  end

  @doc """
  Gets the parser module for a file extension.

  ## Parameters
    - extension: The file extension with dot (e.g., ".ex", ".py")

  ## Returns
    - `{:ok, module}` if found
    - `:error` if not found

  ## Examples
      iex> Parser.get_parser_for_extension(".ex")
      {:ok, MyElixirParser}
  """
  @spec get_parser_for_extension(String.t()) :: {:ok, module()} | :error
  def get_parser_for_extension(extension) when is_binary(extension) do
    ParserRegistry.for_extension(extension)
  end

  @doc """
  Normalize a language name to its canonical form.

  Handles common aliases like "ex" → "elixir", "py" → "python", etc.

  ## Parameters
    - language: The language name or alias

  ## Returns
    The canonical language name.

  ## Examples
      iex> Parser.normalize_language("ex")
      "elixir"

      iex> Parser.normalize_language("py")
      "python"

      iex> Parser.normalize_language("js")
      "javascript"
  """
  @spec normalize_language(String.t()) :: String.t()
  def normalize_language(language) when is_binary(language) do
    language = String.downcase(language)

    case language do
      "ex" -> "elixir"
      "exs" -> "elixir"
      "py" -> "python"
      "js" -> "javascript"
      "jsx" -> "javascript"
      "ts" -> "typescript"
      "tsx" -> "typescript"
      "rs" -> "rust"
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
