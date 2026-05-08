defmodule CodePuppyControl.Indexer do
  @moduledoc """
  Directory indexing for repository structure analysis.

  Provides fast file discovery, categorization, and symbol extraction.
  This is an Elixir-native implementation, replacing the Python bridge.

  ## Usage

  Simple indexing with defaults:

      iex> {:ok, summaries} = Indexer.index("/path/to/project")
      iex> Enum.map(summaries, & &1.path)
      ["lib/app.ex", "README.md"]

  With custom options:

      iex> opts = [max_files: 100, max_symbols_per_file: 16, ignored_dirs: ["vendor"]]
      iex> {:ok, summaries} = Indexer.index("/path/to/project", opts)

  Bang variant that raises on error:

      iex> summaries = Indexer.index!("/path/to/project")

  ## Architecture

  The indexer consists of several specialized modules:

  - `DirectoryWalker` - Memory-efficient filesystem traversal using Streams
  - `FileCategorizer` - Determines file types from extensions and names
  - `SymbolExtractor` - Extracts code symbols (functions, classes) using regex
  - `FileSummary` - Data structure for indexed file results
  - `DirectoryIndexer` - Main coordination with concurrent processing

  All modules are designed to be composable and can be used independently.
  """

  alias CodePuppyControl.Indexer.{DirectoryIndexer, RepoCompass}

  @doc """
  Indexes a directory and returns file summaries.

  See `DirectoryIndexer.index/2` for options.
  """
  defdelegate index(root, opts \\ []), to: DirectoryIndexer

  @doc """
  Indexes a directory, raising on error.

  See `DirectoryIndexer.index!/2` for options.
  """
  defdelegate index!(root, opts \\ []), to: DirectoryIndexer

  @doc """
  Builds the compact Repo Compass structure map.

  This delegate targets the prompt-oriented Elixir port of the Python
  `repo_compass/indexer.py` implementation.
  """
  defdelegate repo_compass_index(root, opts \\ []), to: RepoCompass, as: :index

  @doc """
  Bang variant of `repo_compass_index/2`.
  """
  defdelegate repo_compass_index!(root, opts \\ []), to: RepoCompass, as: :index!
end
