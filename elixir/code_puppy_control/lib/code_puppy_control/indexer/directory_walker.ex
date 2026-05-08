defmodule CodePuppyControl.Indexer.DirectoryWalker do
  @moduledoc """
  Walks directories while respecting ignore patterns.

  This module provides memory-efficient directory traversal using `Stream`.
  It skips hidden directories (starting with .) and configured ignore patterns.

  The walker returns a lazy enumerable of {path, depth} tuples for all files.
  """

  alias CodePuppyControl.Indexer.Constants

  @doc """
  Walks a directory tree, yielding {path, depth} tuples for each file.

  ## Parameters

    - root: The root directory path to start from
    - custom_ignored: Additional directory names to ignore (optional)

  ## Returns

  A lazy `Stream` of {path, depth} tuples for regular files only.

  ## Examples

      iex> walker = DirectoryWalker.walk("/path/to/project")
      iex> files = Enum.take(walker, 10)
      [{"/path/to/project/file1.ex", 0}, {"/path/to/project/lib/file2.ex", 1}]
  """
  @spec walk(Path.t(), MapSet.t(String.t())) :: Enumerable.t({Path.t(), non_neg_integer()})
  def walk(root, custom_ignored \\ MapSet.new()) do
    ignored = MapSet.union(Constants.ignored_dirs(), custom_ignored)

    root
    |> Path.expand()
    |> do_walk(ignored, 0)
    # Filter for regular files using the path from the tuple
    |> Stream.filter(fn {path, _depth} -> File.regular?(path) end)
  end

  @doc """
  Returns a stream of file paths with their depth and relative path.

  This is a convenience function that includes the relative path calculation.
  """
  @spec walk_with_relative(Path.t(), MapSet.t(String.t()), Path.t()) ::
          Enumerable.t({Path.t(), non_neg_integer(), String.t()})
  def walk_with_relative(root, custom_ignored \\ MapSet.new(), relative_to \\ nil) do
    root = Path.expand(root)
    base = relative_to || root

    walk(root, custom_ignored)
    |> Stream.map(fn {path, depth} ->
      rel = Path.relative_to(path, base)
      {path, depth, rel}
    end)
  end

  # Private implementation using Stream.resource for lazy traversal

  defp do_walk(path, ignored, depth) do
    Stream.resource(
      fn -> [{{path, depth}, :dir}] end,
      fn
        [] ->
          {:halt, []}

        [{{current, d}, :dir} | rest] ->
          if should_ignore?(current, ignored) do
            {[], rest}
          else
            case File.ls(current) do
              {:ok, entries} ->
                children =
                  entries
                  |> Enum.reject(&hidden?/1)
                  |> Enum.map(&Path.join(current, &1))
                  |> Enum.map(fn p ->
                    case File.lstat(p) do
                      {:ok, %File.Stat{type: :directory}} -> {{p, d + 1}, :dir}
                      {:ok, %File.Stat{type: :regular}} -> {{p, d + 1}, :file}
                      # Skip symlinks, devices, sockets, etc.
                      _ -> nil
                    end
                  end)
                  |> Enum.reject(&is_nil/1)
                  |> Enum.sort_by(fn {{p, _}, _} -> Path.basename(p) end)

                {[], children ++ rest}

              {:error, _} ->
                {[], rest}
            end
          end

        [{{current, d}, :file} | rest] ->
          {[{current, d}], rest}
      end,
      fn _ -> :ok end
    )
  end

  defp should_ignore?(path, ignored) do
    basename = Path.basename(path)
    MapSet.member?(ignored, basename) or hidden?(basename)
  end

  defp hidden?("." <> _), do: true
  defp hidden?(_), do: false
end
