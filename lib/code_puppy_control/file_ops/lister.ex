defmodule CodePuppyControl.FileOps.Lister do
  @moduledoc """
  Handles directory listing operations and file walking.

  This module provides functionality for listing files in directories,
  supporting both shallow (single-level) and recursive directory traversal.
  It handles gitignore patterns, hidden file filtering, and security checks.

  The `walk_directory/6` function can also be used by other modules
  (such as `FileOps.Grep`) to traverse directories while applying
  custom filtering logic.
  """

  require Logger

  alias CodePuppyControl.FileOps.Security
  alias CodePuppyControl.Gitignore
  alias CodePuppyControl.Indexer.Constants

  @max_list_files_entries 10_000

  @doc """
  Lists files in a directory.

  ## Options

    * `:recursive` - Whether to list files recursively (default: `true`)
    * `:include_hidden` - Whether to include hidden files (default: `false`)
    * `:ignore_patterns` - List of directory names to ignore (default: common ignored dirs)
    * `:max_files` - Maximum number of files to return (default: 10,000)
    * `:gitignore` - Whether to respect .gitignore files (default: `true`)

  ## Examples

      iex> Lister.list_files("/path/to/dir")
      {:ok, [%{path: "file.txt", size: 123, type: :file, modified: ~U[...]}]}

  """
  def list_files(directory, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    include_hidden = Keyword.get(opts, :include_hidden, false)

    custom_ignore_patterns =
      Keyword.get(opts, :ignore_patterns, Constants.ignored_dirs() |> MapSet.to_list())

    max_files = Keyword.get(opts, :max_files, @max_list_files_entries)
    use_gitignore = Keyword.get(opts, :gitignore, true)

    with {:ok, dir_path} <- Security.validate_path(directory, "list"),
         :ok <- check_directory_exists(dir_path) do
      gitignore_matcher = if use_gitignore, do: Gitignore.for_directory(dir_path), else: nil

      results =
        if recursive do
          list_files_recursive(
            dir_path,
            include_hidden,
            custom_ignore_patterns,
            max_files,
            gitignore_matcher
          )
        else
          list_files_shallow(dir_path, include_hidden, max_files, gitignore_matcher)
        end

      {:ok, results}
    end
  end

  defp check_directory_exists(dir_path) do
    cond do
      not File.dir?(dir_path) ->
        {:error, "Not a directory: #{dir_path}"}

      not File.exists?(dir_path) ->
        {:error, "Directory does not exist: #{dir_path}"}

      true ->
        :ok
    end
  end

  defp list_files_shallow(dir_path, include_hidden, max_files, gitignore_matcher) do
    case File.ls(dir_path) do
      {:ok, entries} ->
        entries
        |> Stream.reject(fn entry ->
          not include_hidden and String.starts_with?(entry, ".")
        end)
        |> Stream.reject(fn entry ->
          gitignore_matcher && Gitignore.ignored?(gitignore_matcher, entry)
        end)
        |> Stream.take(max_files)
        |> Stream.map(fn entry ->
          full_path = Path.join(dir_path, entry)
          build_file_info(full_path, entry, 0)
        end)
        |> Stream.reject(&is_nil/1)
        |> Enum.to_list()

      {:error, reason} ->
        Logger.warning("Failed to list directory #{dir_path}: #{inspect(reason)}")
        []
    end
  end

  defp list_files_recursive(
         dir_path,
         include_hidden,
         custom_ignore_patterns,
         max_files,
         gitignore_matcher
       ) do
    ignored = MapSet.new(custom_ignore_patterns)

    dir_path
    |> walk_directory(ignored, include_hidden, 0, dir_path, gitignore_matcher)
    |> Stream.take(max_files)
    |> Enum.to_list()
  end

  @doc false
  def walk_directory(path, ignored, include_hidden, depth, base_dir, gitignore_matcher) do
    Stream.resource(
      fn -> {[{{path, depth}, :dir}], %{}} end,
      fn
        {[], _matchers} ->
          {:halt, []}

        {[{{current, d}, :dir} | rest], matchers} ->
          rel_current = Path.relative_to(current, base_dir)

          if should_ignore?(current, ignored, include_hidden) do
            {[], {rest, matchers}}
          else
            {dir_matcher, updated_matchers} =
              if gitignore_matcher do
                get_or_create_matcher(current, matchers)
              else
                {nil, matchers}
              end

            case File.ls(current) do
              {:ok, entries} ->
                children =
                  entries
                  |> Stream.reject(fn e ->
                    not include_hidden and hidden?(e)
                  end)
                  |> Stream.reject(fn e ->
                    dir_matcher && Gitignore.ignored?(dir_matcher, e)
                  end)
                  |> Stream.map(&Path.join(current, &1))
                  |> Stream.map(fn p ->
                    case File.lstat(p) do
                      {:ok, %File.Stat{type: :directory}} ->
                        {{p, d + 1}, :dir}

                      {:ok, %File.Stat{type: :regular}} ->
                        {{p, d + 1}, :file}

                      _ ->
                        nil
                    end
                  end)
                  |> Stream.reject(&is_nil/1)
                  |> Enum.to_list()
                  |> Enum.sort_by(fn {{p, _}, _} -> Path.basename(p) end)

                dir_info =
                  if rel_current != "." do
                    [build_file_info(current, rel_current, d)]
                  else
                    []
                  end

                {dir_info, {children ++ rest, updated_matchers}}

              {:error, _} ->
                {[], {rest, updated_matchers}}
            end
          end

        {[{{current, d}, :file} | rest], matchers} ->
          rel_path = Path.relative_to(current, base_dir)
          parent_dir = Path.dirname(current)

          dir_matcher = Map.get(matchers, parent_dir)
          basename = Path.basename(current)

          skip =
            if dir_matcher do
              Gitignore.ignored?(dir_matcher, basename)
            else
              gitignore_matcher && Gitignore.ignored?(gitignore_matcher, rel_path)
            end

          if skip do
            {[], {rest, matchers}}
          else
            file_info = build_file_info(current, rel_path, d)
            {[file_info], {rest, matchers}}
          end
      end,
      fn _ -> :ok end
    )
    |> Stream.reject(&is_nil/1)
  end

  defp get_or_create_matcher(dir, matchers) do
    case Map.fetch(matchers, dir) do
      {:ok, matcher} ->
        {matcher, matchers}

      :error ->
        matcher = Gitignore.for_directory(dir)
        {matcher, Map.put(matchers, dir, matcher)}
    end
  end

  defp should_ignore?(path, ignored, _include_hidden) do
    basename = Path.basename(path)
    MapSet.member?(ignored, basename)
  end

  defp hidden?("." <> _), do: true
  defp hidden?(_), do: false

  defp build_file_info(full_path, relative_path, _depth) do
    case File.lstat(full_path, time: :posix) do
      {:ok, stat} ->
        type = if stat.type == :directory, do: :directory, else: :file

        modified =
          case DateTime.from_unix(stat.mtime) do
            {:ok, dt} -> dt
            _ -> DateTime.utc_now()
          end

        size = if type == :file, do: stat.size, else: 0

        if not Security.sensitive_path?(full_path) do
          %{
            path: relative_path,
            size: size,
            type: type,
            modified: modified
          }
        else
          nil
        end

      {:error, _} ->
        nil
    end
  end
end
