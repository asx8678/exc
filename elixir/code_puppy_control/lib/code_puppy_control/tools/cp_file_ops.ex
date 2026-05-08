defmodule CodePuppyControl.Tools.CpFileOps do
  @moduledoc """
  `:cp_`-prefixed Tool-behaviour wrappers for file operations.

  These modules expose the existing `CodePuppyControl.FileOps` services
  through the Tool behaviour so the CodePuppy agent can call
  `cp_list_files`, `cp_read_file`, and `cp_grep` via the tool registry.

  The `:cp_` namespace distinguishes agent-facing tool names from
  internal tool module names, matching the naming convention used in
  `CodePuppyControl.Agents.CodePuppy.allowed_tools/0`.

  ## Permission Gating (Phase E — code_puppy-mmk.1)

  Each submodule implements `permission_check/2` as a **hard gate**
  that validates file paths via `FileOps.Security.validate_path/2`.
  Sensitive paths (SSH keys, cloud credentials, system secrets) are
  **always** denied at this layer — no policy override can bypass it.

  The Tool.Runner then applies a **second layer**: the FilePermission
  callback chain (policy engine + plugin callbacks). Together these
  form a two-layer permission stack:

  1. **Tool `permission_check/2`** — hard gate (sensitive-path deny)
  2. **FilePermission callback chain** — policy gate (allow/deny/ask)

  Refs: code_puppy-4s8.7 (Phase C CI gate), code_puppy-mmk.1 (Phase E)
  """

  alias CodePuppyControl.FileOps.Security

  @doc """
  Validates `path` against `Security.validate_path/2` and returns
  `:ok` or `{:deny, reason}` for use in `permission_check/2` implementations.

  Deduplicates the common pattern shared across all three submodules.
  """
  @spec validate_path_for_permission(String.t(), String.t()) :: :ok | {:deny, String.t()}
  def validate_path_for_permission(path, operation) do
    case Security.validate_path(path, operation) do
      {:ok, _} -> :ok
      {:error, reason} -> {:deny, reason}
    end
  end

  defmodule CpListFiles do
    @moduledoc """
    Lists files and directories within a project.

    Delegates to `CodePuppyControl.FileOps.Lister.list_files/2`.

    Permission check validates the directory path against sensitive-path
    rules (hard gate). The Tool.Runner then applies the FilePermission
    callback chain (policy gate) as a second layer.
    """

    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_list_files

    @impl true
    def description do
      "List files and directories in a project directory with " <>
        "intelligent filtering and safety features. Automatically " <>
        "ignores build artifacts, caches, and common noise."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "directory" => %{
            "type" => "string",
            "description" => "Directory path to list (default: current directory)"
          },
          "recursive" => %{
            "type" => "boolean",
            "description" => "Whether to list recursively (default: true)"
          }
        },
        "required" => []
      }
    end

    @impl true
    def permission_check(args, _context) do
      CodePuppyControl.Tools.CpFileOps.validate_path_for_permission(
        Map.get(args, "directory", "."),
        "list"
      )
    end

    @impl true
    def invoke(args, _context) do
      directory = Map.get(args, "directory", ".")
      recursive = Map.get(args, "recursive", true)

      case CodePuppyControl.FileOps.list_files(directory, recursive: recursive) do
        {:ok, files} -> {:ok, %{files: files, count: length(files)}}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defmodule CpReadFile do
    @moduledoc """
    Reads file contents with optional line-range selection.

    Delegates to `CodePuppyControl.FileOps.Reader.read_file/2`.

    Permission check validates the file path against sensitive-path
    rules (hard gate). The Tool.Runner then applies the FilePermission
    callback chain (policy gate) as a second layer.
    """

    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_read_file

    @impl true
    def description do
      "Read file contents with optional line-range selection and " <>
        "token safety. Use start_line/num_lines for large files to " <>
        "avoid overwhelming context."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Path to the file to read"
          },
          "start_line" => %{
            "type" => "integer",
            "description" => "1-based starting line number (optional)"
          },
          "num_lines" => %{
            "type" => "integer",
            "description" => "Number of lines to read (optional)"
          }
        },
        "required" => ["file_path"]
      }
    end

    @impl true
    def permission_check(args, _context) do
      CodePuppyControl.Tools.CpFileOps.validate_path_for_permission(
        Map.get(args, "file_path", ""),
        "read"
      )
    end

    @impl true
    def invoke(args, _context) do
      path = Map.get(args, "file_path", "")

      opts =
        []
        |> maybe_put(:start_line, Map.get(args, "start_line"))
        |> maybe_put(:num_lines, Map.get(args, "num_lines"))

      case CodePuppyControl.FileOps.read_file(path, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  end

  defmodule CpGrep do
    @moduledoc """
    Recursively searches for text patterns across files.

    Delegates to `CodePuppyControl.FileOps.Grep.grep/3`.

    Permission check validates the directory path against sensitive-path
    rules (hard gate). The Tool.Runner then applies the FilePermission
    callback chain (policy gate) as a second layer.
    """

    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_grep

    @impl true
    def description do
      "Recursively search for text patterns across files using " <>
        "ripgrep (rg). search_string supports ripgrep flag syntax " <>
        "(regex, -i for case-insensitive, etc)."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "search_string" => %{
            "type" => "string",
            "description" => "Pattern to search for (supports regex)"
          },
          "directory" => %{
            "type" => "string",
            "description" => "Directory to search in (default: current directory)"
          }
        },
        "required" => ["search_string"]
      }
    end

    @impl true
    def permission_check(args, _context) do
      CodePuppyControl.Tools.CpFileOps.validate_path_for_permission(
        Map.get(args, "directory", "."),
        "search"
      )
    end

    @impl true
    def invoke(args, _context) do
      pattern = Map.get(args, "search_string", "")
      directory = Map.get(args, "directory", ".")

      case CodePuppyControl.FileOps.grep(pattern, directory) do
        {:ok, matches} -> {:ok, %{matches: matches, count: length(matches)}}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end
end
