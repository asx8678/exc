defmodule CodePuppyControl.FileOps.Reader do
  @moduledoc """
  Handles single and batch file reading with EOL normalization.

  This module provides functions to read individual files with optional line
  range selection and EOL normalization, as well as batch reading capabilities
  with concurrent processing.

  Features:
  - Single file reading with line range support (start_line, num_lines)
  - EOL normalization (converts CRLF/CR to LF, strips BOM)
  - Batch file reading with concurrent Task.async_stream
  - Security validation via Security.validate_path/2
  """

  alias CodePuppyControl.FileOps.Security
  alias CodePuppyControl.Text.EOL

  # Maximum read file size (10MB)
  @max_read_file_size 10 * 1024 * 1024

  @doc """
  Read a single file's contents.

  Options:
  - :start_line - integer, 1-based
  - :num_lines - integer limit
  - :encoding - atom, default :utf8
  - :normalize_eol - boolean, default false. When true, strips BOM and
    normalizes CRLF/CR to LF for text files. Returns the BOM that was
    stripped in the result for later restoration.

  ## Examples

      iex> FileOps.read_file("/path/to/file.ex")
      {:ok, %{path: "file.ex", content: "...", num_lines: 100, size: 1234, truncated: false}}

      iex> FileOps.read_file("/path/to/file.ex", start_line: 1, num_lines: 10)
      {:ok, %{path: "file.ex", content: "...", num_lines: 10, size: 500, truncated: true}}

      iex> FileOps.read_file("/path/to/file.txt", normalize_eol: true)
      {:ok, %{path: "file.txt", content: "...", num_lines: 100, size: 1234, truncated: false, bom: <<0xEF, 0xBB, 0xBF>>}}
  """
  @spec read_file(String.t(), keyword()) ::
          {:ok, CodePuppyControl.FileOps.read_result()} | {:error, term()}
  def read_file(path, opts \\ []) do
    start_line = Keyword.get(opts, :start_line)
    num_lines = Keyword.get(opts, :num_lines)
    normalize_eol = Keyword.get(opts, :normalize_eol, false)

    with {:ok, file_path} <- Security.validate_path(path, "read"),
         {:ok, result} <- do_read_file(file_path, start_line, num_lines, normalize_eol) do
      {:ok, result}
    end
  end

  defp do_read_file(file_path, start_line, num_lines, normalize_eol) do
    cond do
      not File.exists?(file_path) ->
        {:error, "File not found: #{file_path}"}

      not File.regular?(file_path) ->
        {:error, "Not a file: #{file_path}"}

      true ->
        case File.stat(file_path) do
          {:ok, %{size: size}} when size > @max_read_file_size ->
            {:error,
             "File too large (> #{@max_read_file_size} bytes). Read in chunks using start_line/num_lines options."}

          {:ok, stat} ->
            content_result =
              case File.read(file_path) do
                {:ok, content} ->
                  process_content(content, start_line, num_lines, normalize_eol)

                {:error, reason} ->
                  {:error, "Failed to read file: #{inspect(reason)}"}
              end

            case content_result do
              {:ok, {content, truncated, bom}} ->
                {:ok,
                 %{
                   path: file_path,
                   content: content,
                   num_lines: count_lines(content),
                   size: stat.size,
                   truncated: truncated,
                   error: nil,
                   bom: bom
                 }}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, "Failed to stat file: #{inspect(reason)}"}
        end
    end
  end

  defp process_content(content, start_line, num_lines, normalize_eol) do
    {content_for_processing, bom} =
      if normalize_eol do
        EOL.normalize_with_bom(content)
      else
        {content, nil}
      end

    if is_nil(start_line) and is_nil(num_lines) do
      {:ok, {content_for_processing, false, bom}}
    else
      lines = String.split(content_for_processing, "\n")
      total_lines = length(lines)

      effective_start = max(start_line || 1, 1)
      effective_num = num_lines || total_lines

      if effective_start > total_lines do
        {:ok, {"", true, bom}}
      else
        end_line = min(effective_start + effective_num - 1, total_lines)
        selected = Enum.slice(lines, effective_start - 1, end_line - effective_start + 1)
        result = Enum.join(selected, "\n")
        truncated = end_line < total_lines or effective_start > 1

        {:ok, {result, truncated, bom}}
      end
    end
  end

  defp count_lines(""), do: 0

  defp count_lines(content) do
    parts = String.split(content, "\n")
    if List.last(parts) == "", do: length(parts) - 1, else: length(parts)
  end

  @doc """
  Batch read multiple files concurrently.

  Options:
  - :max_concurrency - integer, default System.schedulers_online()
  - :timeout - milliseconds per file
  - :normalize_eol - boolean, default false. Applies EOL normalization
    to all files being read.

  ## Examples

      iex> FileOps.read_files(["file1.ex", "file2.ex"])
      {:ok, [%{path: "file1.ex", content: "...", ...}, %{path: "file2.ex", content: "...", ...}]}
  """
  @spec read_files([String.t()], keyword()) :: {:ok, [CodePuppyControl.FileOps.read_result()]}
  def read_files(paths, opts \\ []) do
    max_concurrency =
      Keyword.get(opts, :max_concurrency, CodePuppyControl.Runtime.Limits.io_concurrency())

    timeout = Keyword.get(opts, :timeout, 30_000)
    read_opts = Keyword.take(opts, [:start_line, :num_lines, :normalize_eol])

    {valid_paths, invalid_results} =
      Enum.reduce(paths, {[], []}, fn path, {valid, invalid} ->
        case Security.validate_path(path, "read") do
          {:ok, normalized} ->
            {[normalized | valid], invalid}

          {:error, reason} ->
            {valid,
             [
               %{
                 path: path,
                 content: nil,
                 num_lines: 0,
                 size: 0,
                 truncated: false,
                 error: reason,
                 bom: nil
               }
               | invalid
             ]}
        end
      end)

    if valid_paths == [] and invalid_results != [] do
      {:ok, Enum.reverse(invalid_results)}
    else
      results =
        valid_paths
        |> Task.async_stream(
          fn path ->
            case read_file(path, read_opts) do
              {:ok, result} ->
                result

              {:error, reason} ->
                %{
                  path: path,
                  content: nil,
                  num_lines: 0,
                  size: 0,
                  truncated: false,
                  error: reason,
                  bom: nil
                }
            end
          end,
          max_concurrency: max_concurrency,
          timeout: timeout,
          on_timeout: :kill_task
        )
        |> Enum.to_list()
        |> Enum.map(fn
          {:ok, result} ->
            result

          {:exit, reason} ->
            %{
              path: "",
              content: nil,
              num_lines: 0,
              size: 0,
              truncated: false,
              error: "Task failed: #{inspect(reason)}",
              bom: nil
            }
        end)

      {:ok, Enum.reverse(invalid_results) ++ results}
    end
  end
end
