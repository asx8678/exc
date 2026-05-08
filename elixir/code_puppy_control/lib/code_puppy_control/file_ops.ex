defmodule CodePuppyControl.FileOps do
  @moduledoc """
  Native Elixir file operations.

  Provides list_files, grep, read_file, read_files with:
  - Concurrent processing via Task.async_stream
  - Memory-efficient streaming for large directories
  - Proper error handling
  - Security validation (no sensitive paths)

  Ported from Python code_puppy/tools/file_operations.py

  ## Submodules

  Implementation is split across focused submodules:
  - `CodePuppyControl.FileOps.Security` - Sensitive path detection and validation
  - `CodePuppyControl.FileOps.Lister` - Directory listing and file walking
  - `CodePuppyControl.FileOps.Grep` - Text pattern search
  - `CodePuppyControl.FileOps.Reader` - File reading (single and batch)
  """

  @type file_info :: %{
          path: String.t(),
          size: non_neg_integer(),
          type: :file | :directory,
          modified: DateTime.t()
        }

  @type grep_match :: %{
          file: String.t(),
          line_number: non_neg_integer(),
          line_content: String.t(),
          match_start: non_neg_integer(),
          match_end: non_neg_integer()
        }

  @type read_result :: %{
          path: String.t(),
          content: String.t() | nil,
          num_lines: non_neg_integer(),
          size: non_neg_integer(),
          truncated: boolean(),
          error: String.t() | nil,
          bom: binary() | nil
        }

  # Security
  defdelegate sensitive_path?(file_path), to: CodePuppyControl.FileOps.Security
  defdelegate validate_path(file_path, operation), to: CodePuppyControl.FileOps.Security

  # Listing
  defdelegate list_files(directory, opts \\ []), to: CodePuppyControl.FileOps.Lister

  # Grep
  defdelegate grep(pattern, directory, opts \\ []), to: CodePuppyControl.FileOps.Grep

  # Reading
  defdelegate read_file(path, opts \\ []), to: CodePuppyControl.FileOps.Reader
  defdelegate read_files(paths, opts \\ []), to: CodePuppyControl.FileOps.Reader
end
