defmodule CodePuppyControl.Tools.FileModifications.DeleteSnippet do
  @moduledoc """
  Tool for removing the first occurrence of a text snippet from a file.

  Finds the first exact match of the snippet in the file content and removes it.
  Generates a unified diff showing what was removed.

  ## Security

  - Path validated via `FileOps.Security`
  - Permission check via `PolicyEngine`
  - `FileLock.with_lock/2` serializes concurrent mutations
  """

  use CodePuppyControl.Tool

  require Logger

  alias CodePuppyControl.{FileOps.Security, Text.Diff, Text.EOL}
  alias CodePuppyControl.Tools.FileModifications.{SafeWrite, DiffEmitter, Validation, FileLock}

  @impl true
  def name, do: :delete_snippet

  @impl true
  def description do
    "Remove the first occurrence of a text snippet from a file."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "file_path" => %{
          "type" => "string",
          "description" => "Path to the file to modify"
        },
        "snippet" => %{
          "type" => "string",
          "description" => "Text snippet to remove (first occurrence only)"
        }
      },
      "required" => ["file_path", "snippet"]
    }
  end

  @impl true
  def permission_check(args, _context) do
    file_path = Map.get(args, "file_path", "")

    case Security.validate_path(file_path, "delete snippet from") do
      {:ok, _} -> :ok
      {:error, reason} -> {:deny, reason}
    end
  end

  @impl true
  def invoke(args, _context) do
    file_path = Map.get(args, "file_path", "")
    snippet = Map.get(args, "snippet", "")

    with {:ok, expanded_path} <- Security.validate_path(file_path, "delete snippet from") do
      FileLock.with_lock(expanded_path, fn ->
        do_delete_snippet(expanded_path, snippet)
      end)
    end
  end

  defp do_delete_snippet(_file_path, ""), do: {:error, "snippet cannot be empty"}

  defp do_delete_snippet(file_path, snippet) do
    case File.read(file_path) do
      {:ok, content} ->
        # Strip BOM for matching (LLM output never has BOM)
        {content_no_bom, bom} = EOL.strip_bom(content)

        if String.contains?(content_no_bom, snippet) do
          modified = String.replace(content_no_bom, snippet, "", global: false)
          # Strip LLM-hallucinated blank lines
          modified = EOL.strip_added_blank_lines(content_no_bom, modified)

          diff =
            Diff.unified_diff(content_no_bom, modified,
              from_file: "a/#{Path.basename(file_path)}",
              to_file: "b/#{Path.basename(file_path)}"
            )

          # Restore BOM on write
          final_content = EOL.restore_bom(modified, bom)

          case SafeWrite.safe_write(file_path, final_content) do
            :ok ->
              # Emit diff for UI display
              DiffEmitter.emit_diff(file_path, :modify, diff)

              result = %{
                success: true,
                path: file_path,
                message: "Snippet removed successfully",
                changed: true,
                diff: diff
              }

              # Post-edit syntax validation (advisory only)
              result = Validation.maybe_attach_warning(result, file_path)

              {:ok, result}

            {:error, :symlink_detected} ->
              {:error,
               %{
                 success: false,
                 path: file_path,
                 message: "Refusing to write to symlink (security: symlink attack prevention)",
                 changed: false
               }}

            {:error, reason} when is_binary(reason) ->
              {:error,
               %{
                 success: false,
                 path: file_path,
                 message: reason,
                 changed: false
               }}

            {:error, reason} ->
              {:error,
               %{
                 success: false,
                 path: file_path,
                 message: "Failed to write file: #{inspect(reason)}",
                 changed: false
               }}
          end
        else
          {:error,
           %{
             success: false,
             path: file_path,
             message: "Snippet not found in file",
             changed: false
           }}
        end

      {:error, :enoent} ->
        {:error,
         %{
           success: false,
           path: file_path,
           message: "File not found",
           changed: false
         }}

      {:error, reason} ->
        {:error,
         %{
           success: false,
           path: file_path,
           message: "Failed to read file: #{:file.format_error(reason)}",
           changed: false
         }}
    end
  end
end
