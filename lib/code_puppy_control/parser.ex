defmodule CodePuppyControl.Parser do
  @moduledoc """
  High-level parsing interface. Routes to pure Elixir parsers.

  Also provides hashline formatting for file display with line anchors.
  """

  alias CodePuppyControl.Parsing.Parser, as: PureParser
  alias CodePuppyControl.Parsing.ParserRegistry
  alias CodePuppyControl.HashlineNif

  @doc """
  Check if parsing is available (always true with pure Elixir parsers).
  """
  def nif_available? do
    # With pure Elixir parsers, parsing is always available
    true
  end

  @doc """
  Extract symbols from source code.

  Returns {:ok, map} with string keys for backward compatibility:
    - "language" => string
    - "symbols" => list
    - "extraction_time_ms" | "parse_time_ms" => float
    - "success" => boolean
    - "errors" | "diagnostics" => list

  Can return {:error, reason} for unsupported languages or parse failures.
  """
  def extract_symbols(source, language) do
    if PureParser.language_supported?(language) do
      case PureParser.extract_symbols(source, language) do
        {:ok, symbols} when is_list(symbols) ->
          {:ok,
           %{
             "language" => language,
             "symbols" => atom_keys_to_string_keys(symbols),
             "extraction_time_ms" => 0.0,
             "success" => true,
             "errors" => []
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok,
       %{
         "language" => language,
         "symbols" => [],
         "success" => false,
         "error" => "unsupported_language"
       }}
    end
  end

  @doc """
  Extract symbols from a file.

  Auto-detects language from file extension if not provided.
  """
  def extract_symbols_from_file(path, language \\ nil) do
    lang = language || detect_language(path)

    cond do
      not is_binary(lang) ->
        {:error, "Could not detect language for file: #{path}"}

      not PureParser.language_supported?(lang) ->
        {:error, "Unsupported language: #{lang}"}

      true ->
        case File.read(path) do
          {:ok, content} ->
            extract_symbols(content, lang)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Parse source code.

  Returns {:ok, map} with string keys for backward compatibility.
  """
  def parse_source(source, language) do
    case PureParser.parse(source, language) do
      {:ok, result} ->
        {:ok, atom_keys_to_string_keys(result)}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  @doc """
  Parse a file.

  Auto-detects language from file extension if not provided.
  """
  def parse_file(path, language \\ nil) do
    lang = language || detect_language(path)

    if is_binary(lang) do
      parse_source_from_file(path, lang)
    else
      {:error, "Could not detect language for file: #{path}"}
    end
  end

  @doc """
  Extract syntax diagnostics from source code.

  Returns {:ok, map} with string keys for backward compatibility,
  or {:error, reason} for unsupported languages.
  """
  def extract_syntax_diagnostics(source, language) do
    case PureParser.extract_diagnostics(source, language) do
      {:ok, diagnostics} ->
        # Count errors and warnings
        error_count = Enum.count(diagnostics, fn d -> d[:severity] == :error end)
        warning_count = Enum.count(diagnostics, fn d -> d[:severity] == :warning end)

        {:ok,
         %{
           "language" => language,
           "diagnostics" => atom_keys_to_string_keys(diagnostics),
           "error_count" => error_count,
           "warning_count" => warning_count,
           "success" => true
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get fold ranges for code folding.

  Note: Pure Elixir parsers don't support folding yet. Returns empty for supported languages.
  """
  def get_folds(_source, language) do
    if PureParser.language_supported?(language) do
      # Pure parsers don't support folding yet - return empty result
      {:ok,
       %{
         "language" => language,
         "folds" => [],
         "success" => true
       }}
    else
      {:error, "Folds not supported for language: #{language}"}
    end
  end

  @doc """
  Get fold ranges from a file.

  Note: Pure Elixir parsers don't support folding yet. Returns empty for supported languages.
  """
  def get_folds_from_file(path, language \\ nil) do
    lang = language || detect_language(path)

    if is_binary(lang) and PureParser.language_supported?(lang) do
      {:ok,
       %{
         "language" => lang,
         "folds" => [],
         "success" => true
       }}
    else
      {:error, "Could not detect or unsupported language for file: #{path}"}
    end
  end

  @doc """
  Get syntax highlights.

  Note: Pure Elixir parsers don't support highlights yet. Returns empty for supported languages.
  """
  def get_highlights(_source, language) do
    if PureParser.language_supported?(language) do
      # Pure parsers don't support highlights yet - return empty result
      {:ok,
       %{
         "language" => language,
         "captures" => [],
         "success" => true
       }}
    else
      {:error, "Highlights not supported for language: #{language}"}
    end
  end

  @doc """
  Get syntax highlights from a file.

  Note: Pure Elixir parsers don't support highlights yet. Returns empty for supported languages.
  """
  def get_highlights_from_file(path, language \\ nil) do
    lang = language || detect_language(path)

    if is_binary(lang) and PureParser.language_supported?(lang) do
      {:ok,
       %{
         "language" => lang,
         "captures" => [],
         "success" => true
       }}
    else
      {:error, "Could not detect or unsupported language for file: #{path}"}
    end
  end

  @doc """
  Check if a language is supported for parsing.
  """
  def is_language_supported(language) do
    PureParser.language_supported?(language)
  end

  @doc """
  Get supported languages.

  Returns list of language names as strings.
  """
  def supported_languages do
    PureParser.supported_languages()
    |> Enum.map(fn {lang, _mod} -> lang end)
  end

  @doc """
  Get the parser version string.
  """
  def version do
    "pure_elixir_parsers"
  end

  @doc """
  Normalize a language name (aliases to canonical name).

  Examples:
    normalize_language("py")  => "python"
    normalize_language("js")  => "javascript"
    normalize_language("jsx") => "javascript"
  """
  def normalize_language(language) do
    PureParser.normalize_language(language)
  end

  @doc """
  Get language metadata (name, available query types).

  Returns {:ok, info} or {:error, :unsupported_language}.
  """
  def get_language_info(language) do
    if is_language_supported(language) do
      normalized = normalize_language(language)

      {:ok,
       %{
         "name" => normalized,
         "highlights_available" => true,
         "folds_available" => true,
         "indents_available" => true
       }}
    else
      {:error, :unsupported_language}
    end
  end

  # ---------------------------------------------------------------------------
  # Hashline integration - file display with line anchors
  # ---------------------------------------------------------------------------

  @doc """
  Format text with hashline prefixes for display with line anchors.

  Each line gets a `LINE_NUM#HASH:` prefix for precise referencing.
  `start_line` is 1-based by convention.
  """
  @spec format_with_hashlines(String.t(), non_neg_integer()) :: String.t()
  def format_with_hashlines(text, start_line \\ 1) do
    HashlineNif.format_hashlines(text, start_line)
  end

  @doc """
  Strip hashline prefixes from text, returning plain content.
  """
  @spec strip_hashlines(String.t()) :: String.t()
  def strip_hashlines(text) do
    HashlineNif.strip_hashline_prefixes(text)
  end

  @doc """
  Validate that a hashline anchor still matches the current line content.
  """
  @spec validate_anchor(non_neg_integer(), String.t(), String.t()) :: boolean()
  def validate_anchor(idx, line, expected_hash) do
    HashlineNif.validate_hashline_anchor(idx, line, expected_hash)
  end

  @doc """
  Read a file and format with hashline prefixes for display.

  Returns `{:ok, formatted_text}` or `{:error, reason}`.
  `start_line` is 1-based by convention.
  """
  @spec read_file_with_hashlines(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def read_file_with_hashlines(path, start_line \\ 1) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, format_with_hashlines(content, start_line)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_source_from_file(path, language) do
    case File.read(path) do
      {:ok, content} ->
        parse_source(content, language)

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp detect_language(path) do
    ext = Path.extname(path) |> String.downcase()

    case ParserRegistry.for_extension(ext) do
      {:ok, parser_module} ->
        parser_module.language()

      :error ->
        # Fallback for common extensions not yet in registry
        case ext do
          ".py" -> "python"
          ".rs" -> "rust"
          ".js" -> "javascript"
          ".ts" -> "typescript"
          ".tsx" -> "tsx"
          ".ex" -> "elixir"
          ".exs" -> "elixir"
          _ -> nil
        end
    end
  end

  # Recursively convert atom keys and values to strings for backward compatibility
  # The NIF-based original returned string keys and string values
  defp atom_keys_to_string_keys(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} ->
      string_key = if is_atom(k), do: to_string(k), else: k
      {string_key, atom_keys_to_string_keys(v)}
    end)
    |> Enum.into(%{})
  end

  defp atom_keys_to_string_keys(data) when is_list(data) do
    Enum.map(data, &atom_keys_to_string_keys/1)
  end

  # Keep boolean and nil values as-is
  defp atom_keys_to_string_keys(true), do: true
  defp atom_keys_to_string_keys(false), do: false
  defp atom_keys_to_string_keys(nil), do: nil

  # Convert other atom values (like :module, :function) to strings
  defp atom_keys_to_string_keys(data) when is_atom(data) do
    to_string(data)
  end

  defp atom_keys_to_string_keys(data), do: data
end
