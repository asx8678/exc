defmodule CodePuppyControl.Tools.FileModifications.EditFile do
  @moduledoc """
  Comprehensive file editing tool supporting multiple modification strategies.

  Dispatches to the appropriate handler based on the `diff` argument:

  - **Content payload** — `{"content": "full file contents", "overwrite": true}`
    Creates or overwrites a file with the given content.
  - **Replacements payload** — `{"replacements": [{"old_str": "...", "new_str": "..."}]}`
    Applies targeted in-file text replacements.
  - **Delete snippet payload** — `{"delete_snippet": "text to remove"}`
    Removes the first occurrence of a text snippet.

  The `file_path` is always required alongside the payload.

  ## Design

  This tool is a convenience dispatcher. For more precise control, use
  `create_file`, `replace_in_file`, or `delete_snippet` directly.
  """

  use CodePuppyControl.Tool

  require Logger

  alias CodePuppyControl.FileOps.Security
  alias CodePuppyControl.Tools.FileModifications.{CreateFile, ReplaceInFile, DeleteSnippet}

  @impl true
  def name, do: :edit_file

  @impl true
  def description do
    "Comprehensive file editing tool. Supports: " <>
      "content (create/overwrite), replacements (targeted edits), " <>
      "delete_snippet (remove text). Prefer replacements for existing files."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "file_path" => %{
          "type" => "string",
          "description" => "Path to the file to edit (required)"
        },
        "content" => %{
          "type" => "string",
          "description" =>
            "Full file content for create/overwrite (mutually exclusive with replacements/delete_snippet)"
        },
        "overwrite" => %{
          "type" => "boolean",
          "description" => "If true with content, overwrite existing file. Default: false"
        },
        "replacements" => %{
          "type" => "array",
          "description" =>
            "List of replacement objects with old_str and new_str (mutually exclusive with content/delete_snippet)",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "old_str" => %{"type" => "string"},
              "new_str" => %{"type" => "string"}
            },
            "required" => ["old_str", "new_str"]
          }
        },
        "delete_snippet" => %{
          "type" => "string",
          "description" =>
            "Text snippet to remove from file (mutually exclusive with content/replacements)"
        }
      },
      "required" => ["file_path"]
    }
  end

  @impl true
  def permission_check(args, context) do
    # Delegate to the underlying tool based on payload type
    file_path = Map.get(args, "file_path", "")

    cond do
      Map.has_key?(args, "content") ->
        CreateFile.permission_check(%{"file_path" => file_path}, context)

      Map.has_key?(args, "replacements") ->
        ReplaceInFile.permission_check(%{"file_path" => file_path}, context)

      Map.has_key?(args, "delete_snippet") ->
        DeleteSnippet.permission_check(%{"file_path" => file_path}, context)

      true ->
        # No payload — default check on file_path alone
        case Security.validate_path(file_path, "edit") do
          {:ok, _} -> :ok
          {:error, reason} -> {:deny, reason}
        end
    end
  end

  @impl true
  def invoke(args, context) do
    file_path = Map.get(args, "file_path", "")

    cond do
      Map.has_key?(args, "content") ->
        CreateFile.invoke(
          %{
            "file_path" => file_path,
            "content" => Map.get(args, "content", ""),
            "overwrite" => Map.get(args, "overwrite", false)
          },
          context
        )

      Map.has_key?(args, "replacements") ->
        ReplaceInFile.invoke(
          %{
            "file_path" => file_path,
            "replacements" => Map.get(args, "replacements", [])
          },
          context
        )

      Map.has_key?(args, "delete_snippet") ->
        DeleteSnippet.invoke(
          %{
            "file_path" => file_path,
            "snippet" => Map.get(args, "delete_snippet", "")
          },
          context
        )

      true ->
        {:error,
         %{
           success: false,
           path: file_path,
           message:
             "Must provide one of: 'content', 'replacements', or 'delete_snippet' along with 'file_path'",
           changed: false
         }}
    end
  end
end
