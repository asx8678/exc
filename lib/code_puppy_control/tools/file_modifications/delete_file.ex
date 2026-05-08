defmodule CodePuppyControl.Tools.FileModifications.DeleteFile do
  @moduledoc """
  Tool for safely deleting files with comprehensive logging and diff generation.

  Uses `File.stat/1` and incremental line counting instead of reading the
  entire file into memory — matching the Python large-file behavior.
  Returns a summary diff only; does NOT return `deleted_content`.

  ## Security

  - Path validated via `FileOps.Security` to block sensitive paths
  - Never deletes directories (only regular files)
  - `FileLock.with_lock/2` serializes concurrent mutations
  """

  use CodePuppyControl.Tool

  require Logger

  alias CodePuppyControl.FileOps.Security
  alias CodePuppyControl.Tools.FileModifications.{SafeWrite, DiffEmitter, FileLock}

  @impl true
  def name, do: :delete_file

  @impl true
  def description do
    "Safely delete a file with comprehensive logging and diff generation. " <>
      "Returns a summary diff (line count, byte size) — does not return full deleted content."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "file_path" => %{
          "type" => "string",
          "description" => "Path to the file to delete"
        }
      },
      "required" => ["file_path"]
    }
  end

  @impl true
  def permission_check(args, _context) do
    file_path = Map.get(args, "file_path", "")

    case Security.validate_path(file_path, "delete") do
      {:ok, _} -> :ok
      {:error, reason} -> {:deny, reason}
    end
  end

  @impl true
  def invoke(args, _context) do
    file_path = Map.get(args, "file_path", "")

    with {:ok, expanded_path} <- Security.validate_path(file_path, "delete") do
      FileLock.with_lock(expanded_path, fn ->
        do_delete(expanded_path)
      end)
    end
  end

  defp do_delete(file_path) do
    cond do
      not File.exists?(file_path) ->
        {:error,
         %{
           success: false,
           path: file_path,
           message: "File not found",
           changed: false
         }}

      File.dir?(file_path) ->
        {:error,
         %{
           success: false,
           path: file_path,
           message: "Cannot delete directory — only files are supported",
           changed: false
         }}

      SafeWrite.symlink?(file_path) ->
        {:error,
         %{
           success: false,
           path: file_path,
           message: "Refusing to delete symlink (security: symlink attack prevention)",
           changed: false
         }}

      true ->
        # Use stat for file size, then count lines incrementally (streaming)
        # This avoids reading the entire file into memory (Python large-file behavior)
        case File.stat(file_path) do
          {:ok, %File.Stat{size: file_size}} ->
            line_count = count_lines_streaming(file_path)

            diff =
              summary_diff(file_path, line_count, file_size)

            case File.rm(file_path) do
              :ok ->
                # Emit diff for UI display
                DiffEmitter.emit_diff(file_path, :delete, diff)

                {:ok,
                 %{
                   success: true,
                   path: file_path,
                   message: "File deleted successfully",
                   changed: true,
                   diff: diff
                 }}

              {:error, reason} ->
                {:error,
                 %{
                   success: false,
                   path: file_path,
                   message: "Failed to delete file: #{:file.format_error(reason)}",
                   changed: false
                 }}
            end

          {:error, reason} ->
            {:error,
             %{
               success: false,
               path: file_path,
               message: "Failed to stat file before deletion: #{:file.format_error(reason)}",
               changed: false
             }}
        end
    end
  end

  # Count lines by streaming through the file — avoids loading entire content into memory.
  defp count_lines_streaming(file_path) do
    case File.open(file_path, [:read, :raw, :read_ahead]) do
      {:ok, file} ->
        try do
          count = IO.binstream(file, :line) |> Enum.count()
          count
        after
          File.close(file)
        end

      {:error, _} ->
        # Fallback: if streaming fails, report 0 (better than crashing)
        0
    end
  end

  defp summary_diff(file_path, line_count, file_size) do
    "--- a/#{Path.basename(file_path)}\n+++ /dev/null\n" <>
      "@@ -1,#{line_count} +0,0 @@\n" <>
      "< File deleted: #{line_count} lines, #{file_size} bytes >\n"
  end
end
