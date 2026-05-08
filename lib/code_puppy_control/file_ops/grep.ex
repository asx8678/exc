defmodule CodePuppyControl.FileOps.Grep do
  @moduledoc """
  Handles text pattern search across files.

  This module provides grep-like functionality for searching file contents
  using regular expressions, with support for gitignore filtering,
  file pattern matching, and configurable match limits.
  """

  alias CodePuppyControl.FileOps.Security
  alias CodePuppyControl.FileOps.Lister
  alias CodePuppyControl.Gitignore
  alias CodePuppyControl.Indexer.Constants

  @max_grep_matches 1_000
  @max_grep_file_size 10 * 1024 * 1024

  @doc """
  Searches for a pattern across files in a directory.

  ## Options
    - :case_sensitive - Whether the pattern matching is case sensitive (default: true)
    - :max_matches - Maximum number of matches to return (default: 1000)
    - :file_pattern - Pattern to filter files by name (default: "*")
    - :context_lines - Number of context lines around each match (default: 0)
    - :gitignore - Whether to respect .gitignore files (default: true)
  """
  def grep(pattern, directory, opts \\ []) do
    case_sensitive = Keyword.get(opts, :case_sensitive, true)
    max_matches = Keyword.get(opts, :max_matches, @max_grep_matches)
    file_pattern = Keyword.get(opts, :file_pattern, "*")
    context_lines = Keyword.get(opts, :context_lines, 0)
    use_gitignore = Keyword.get(opts, :gitignore, true)

    with {:ok, dir_path} <- Security.validate_path(directory, "grep"),
         :ok <- check_directory_exists(dir_path),
         {:ok, regex} <- build_regex(pattern, case_sensitive) do
      gitignore_matcher = if use_gitignore, do: Gitignore.for_directory(dir_path), else: nil

      matches =
        dir_path
        |> stream_files_for_grep(file_pattern, gitignore_matcher)
        |> Stream.flat_map(fn file_path ->
          search_file(file_path, regex, context_lines, dir_path)
        end)
        |> Stream.take(max_matches)
        |> Enum.to_list()

      {:ok, matches}
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

  defp build_regex(pattern, case_sensitive) do
    try do
      opts = if case_sensitive, do: [], else: [:caseless]
      {:ok, Regex.compile!(pattern, opts)}
    rescue
      Regex.CompileError ->
        {:error, "Invalid regex pattern: #{pattern}"}
    end
  end

  defp stream_files_for_grep(dir_path, file_pattern, gitignore_matcher) do
    base_ignored = Constants.ignored_dirs()

    dir_path
    |> Lister.walk_directory(base_ignored, false, 0, dir_path, gitignore_matcher)
    |> Stream.filter(fn %{type: type} -> type == :file end)
    |> Stream.map(fn %{path: path} -> Path.join(dir_path, path) end)
    |> Stream.filter(fn path -> matches_file_pattern?(path, file_pattern) end)
  end

  defp matches_file_pattern?(_path, "*"), do: true

  defp matches_file_pattern?(path, pattern) do
    basename = Path.basename(path)

    # Convert glob pattern to regex: escape special chars, then replace glob wildcards
    regex_str =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    case Regex.compile("^" <> regex_str <> "$") do
      {:ok, regex} -> Regex.match?(regex, basename)
      {:error, _} -> String.contains?(path, pattern)
    end
  end

  defp search_file(file_path, regex, context_lines, base_dir) do
    case File.stat(file_path) do
      {:ok, %{size: size}} when size > @max_grep_file_size ->
        []

      {:ok, _} ->
        do_search_file(file_path, regex, context_lines, base_dir)

      {:error, _} ->
        []
    end
  end

  defp do_search_file(file_path, regex, _context_lines, base_dir) do
    case File.read(file_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        rel_path = Path.relative_to(file_path, base_dir)

        lines
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_num} ->
          case Regex.run(regex, line, return: :index) do
            nil ->
              []

            [{start, len} | _] ->
              stripped = String.trim(line)

              truncated =
                if String.length(stripped) > 512,
                  do: String.slice(stripped, 0, 512),
                  else: stripped

              [
                %{
                  file: rel_path,
                  line_number: line_num,
                  line_content: truncated,
                  match_start: start,
                  match_end: start + len
                }
              ]
          end
        end)
        |> Enum.reject(fn match -> Security.sensitive_path?(match.file) end)

      {:error, _} ->
        []
    end
  end
end
