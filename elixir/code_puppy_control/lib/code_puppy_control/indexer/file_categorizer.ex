defmodule CodePuppyControl.Indexer.FileCategorizer do
  @moduledoc """
  Categorizes files by extension and detects important files.

  This module determines:
  1. The "kind" of a file (elixir, python, docs, etc.)
  2. Whether to extract symbols from the file
  """

  alias CodePuppyControl.Indexer.Constants

  @doc """
  Categorizes a file path into a {kind, extract_symbols?} tuple.

  Important files like README.md get special "project-file" categorization.
  Known extensions are mapped to their language kind.
  Unknown files return {"file", false}.

  ## Examples

      iex> FileCategorizer.categorize("README.md")
      {"project-file", false}

      iex> FileCategorizer.categorize("lib/app.ex")
      {"elixir", true}

      iex> FileCategorizer.categorize("unknown.xyz")
      {"file", false}
  """
  @spec categorize(Path.t()) :: {String.t(), boolean()}
  def categorize(path) do
    filename = Path.basename(path)
    ext = path |> Path.extname() |> String.trim_leading(".")

    cond do
      MapSet.member?(Constants.important_files(), filename) ->
        {"project-file", false}

      ext != "" and Map.has_key?(Constants.extension_map(), ext) ->
        Map.get(Constants.extension_map(), ext)

      true ->
        {"file", false}
    end
  end

  @doc """
  Returns true if the given file kind supports symbol extraction.

  ## Examples

      iex> FileCategorizer.should_extract_symbols?("python")
      true

      iex> FileCategorizer.should_extract_symbols?("docs")
      false
  """
  @spec should_extract_symbols?(String.t()) :: boolean()
  def should_extract_symbols?(kind) when is_binary(kind) do
    kind in ["python", "rust", "javascript", "typescript", "tsx", "elixir"]
  end
end
