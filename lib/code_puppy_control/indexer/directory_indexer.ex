defmodule CodePuppyControl.Indexer.DirectoryIndexer do
  @moduledoc """
  Indexes a directory and returns file summaries with symbols.

  Elixir-native directory indexer.

  ## Features

  - Concurrent file processing using `Task.async_stream`
  - Memory-efficient streaming with early termination
  - Configurable file limits and symbol limits
  - Custom ignore patterns

  ## Example

      iex> DirectoryIndexer.index("/path/to/project", max_files: 50)
      {:ok, [%FileSummary{path: "lib/app.ex", kind: "elixir", symbols: ["defmodule App", "def start"]}]}
  """

  alias CodePuppyControl.Indexer.{
    DirectoryWalker,
    FileCategorizer,
    FileSummary,
    SymbolExtractor
  }

  require Logger

  @typedoc "Options for directory indexing"
  @type opts :: [
          max_files: pos_integer(),
          max_symbols_per_file: pos_integer(),
          ignored_dirs: [String.t()] | MapSet.t(String.t())
        ]

  @default_max_files 40
  @default_max_symbols 8
  @candidate_multiplier 3

  @doc """
  Indexes a directory and returns file summaries.

  ## Options

    - :max_files - Maximum number of files to return (default: 40)
    - :max_symbols_per_file - Maximum symbols per file (default: 8)
    - :ignored_dirs - Additional directories to ignore (default: [])

  ## Returns

    - {:ok, [FileSummary.t()]} on success
    - {:error, reason} on failure

  ## Examples

      iex> DirectoryIndexer.index("/path/to/project")
      {:ok, [%FileSummary{path: "lib/app.ex", kind: "elixir", symbols: []}]}

      iex> DirectoryIndexer.index("/not/a/directory")
      {:error, {:not_a_directory, "/not/a/directory"}}
  """
  @spec index(Path.t(), opts()) :: {:ok, [FileSummary.t()]} | {:error, term()}
  def index(root, opts \\ []) do
    root = Path.expand(root)

    if not File.dir?(root) do
      {:error, {:not_a_directory, root}}
    else
      max_files = Keyword.get(opts, :max_files, @default_max_files)
      max_symbols = Keyword.get(opts, :max_symbols_per_file, @default_max_symbols)
      ignored = opts |> Keyword.get(:ignored_dirs, []) |> to_mapset()

      summaries =
        root
        |> DirectoryWalker.walk(ignored)
        |> Stream.map(fn {path, depth} -> {path, depth, Path.relative_to(path, root)} end)
        |> Enum.sort_by(fn {_, depth, rel} -> {depth, rel} end)
        |> Enum.take(max_files * @candidate_multiplier)
        |> Task.async_stream(
          fn {path, _depth, rel_path} -> process_file(path, rel_path, max_symbols) end,
          max_concurrency: CodePuppyControl.Runtime.Limits.io_concurrency(),
          timeout: 5_000,
          on_timeout: :kill_task
        )
        |> Stream.filter(fn
          {:ok, {:ok, _}} -> true
          _ -> false
        end)
        |> Stream.map(fn {:ok, {:ok, summary}} -> summary end)
        |> Enum.take(max_files)

      {:ok, summaries}
    end
  end

  @doc """
  Indexes a directory, raising on error.

  ## Examples

      iex> DirectoryIndexer.index!("/path/to/project")
      [%FileSummary{path: "lib/app.ex", kind: "elixir", symbols: []}]

      iex> DirectoryIndexer.index!("/not/a/directory")
      ** (RuntimeError) Index failed: {:not_a_directory, "/not/a/directory"}
  """
  @spec index!(Path.t(), opts()) :: [FileSummary.t()]
  def index!(root, opts \\ []) do
    case index(root, opts) do
      {:ok, summaries} -> summaries
      {:error, reason} -> raise "Index failed: #{inspect(reason)}"
    end
  end

  # Private functions

  defp process_file(path, rel_path, max_symbols) do
    {kind, extract?} = FileCategorizer.categorize(path)

    symbols =
      if extract? do
        case File.read(path) do
          {:ok, content} ->
            SymbolExtractor.extract(content, kind, max_symbols)

          {:error, _} ->
            []
        end
      else
        []
      end

    {:ok, %FileSummary{path: rel_path, kind: kind, symbols: symbols}}
  rescue
    error ->
      Logger.warning("Failed to index #{rel_path}: #{inspect(error)}")
      {:error, :processing_failed}
  end

  defp to_mapset(list) when is_list(list), do: MapSet.new(list)
  defp to_mapset(%MapSet{} = set), do: set
end
