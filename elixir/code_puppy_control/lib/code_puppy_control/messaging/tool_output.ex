defmodule CodePuppyControl.Messaging.ToolOutput do
  @moduledoc """
  Tool output message constructors for Agent→UI messaging.

  Provides validated constructors for all message families in the
  `tool_output` category. Mirrors the Python models in
  `code_puppy/messaging/messages.py`.

  | Python class              | Elixir function              |
  |---------------------------|------------------------------|
  | `FileListingMessage`      | `file_listing_message/1`     |
  | `FileContentMessage`      | `file_content_message/1`     |
  | `GrepResultMessage`       | `grep_result_message/1`      |
  | `DiffMessage`             | `diff_message/1`             |
  | `ShellStartMessage`       | `shell_start_message/1`      |
  | `ShellLineMessage`        | `shell_line_message/1`       |
  | `ShellOutputMessage`      | `shell_output_message/1`     |
  | `UniversalConstructorMessage` | `universal_constructor_message/1` |

  All constructors return `{:ok, map}` or `{:error, reason}` — never raise.
  Category defaults to `\"tool_output\"`; providing a mismatched category is rejected.
  """

  alias CodePuppyControl.Messaging.{Entries, Validation}

  @default_category "tool_output"

  # ── FileListingMessage ─────────────────────────────────────────────────────

  @doc """
  Builds a FileListingMessage internal map.

  ## Required fields

  - `"directory"` — string
  - `"recursive"` — boolean

  ## Fields with numeric constraints

  - `"total_size"` — integer ≥ 0 (default: 0)
  - `"dir_count"` — integer ≥ 0 (default: 0)
  - `"file_count"` — integer ≥ 0 (default: 0)

  ## Nested lists

  - `"files"` — list of FileEntry maps (default: `[]`)
  """
  @spec file_listing_message(map()) :: {:ok, map()} | {:error, term()}
  def file_listing_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, directory} <- Validation.require_string(fields, "directory"),
         {:ok, recursive} <- Validation.require_boolean(fields, "recursive"),
         {:ok, files} <- Validation.validate_list(fields, "files", &Entries.file_entry/1),
         {:ok, total_size} <- Validation.require_integer(fields, "total_size", min: 0),
         {:ok, dir_count} <- Validation.require_integer(fields, "dir_count", min: 0),
         {:ok, file_count} <- Validation.require_integer(fields, "file_count", min: 0) do
      {:ok,
       Map.merge(base, %{
         "directory" => directory,
         "files" => files,
         "recursive" => recursive,
         "total_size" => total_size,
         "dir_count" => dir_count,
         "file_count" => file_count
       })}
    end
  end

  def file_listing_message(other), do: {:error, {:not_a_map, other}}

  # ── FileContentMessage ─────────────────────────────────────────────────────

  @doc """
  Builds a FileContentMessage internal map.

  ## Required fields

  - `"path"` — string
  - `"content"` — string
  - `"total_lines"` — integer ≥ 0
  - `"num_tokens"` — integer ≥ 0

  ## Optional fields

  - `"start_line"` — integer ≥ 1 or nil (default: nil)
  - `"num_lines"` — integer ≥ 1 or nil (default: nil)
  """
  @spec file_content_message(map()) :: {:ok, map()} | {:error, term()}
  def file_content_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, path} <- Validation.require_string(fields, "path"),
         {:ok, content} <- Validation.require_string(fields, "content"),
         {:ok, start_line} <- Validation.optional_integer(fields, "start_line", min: 1),
         {:ok, num_lines} <- Validation.optional_integer(fields, "num_lines", min: 1),
         {:ok, total_lines} <- Validation.require_integer(fields, "total_lines", min: 0),
         {:ok, num_tokens} <- Validation.require_integer(fields, "num_tokens", min: 0) do
      {:ok,
       Map.merge(base, %{
         "path" => path,
         "content" => content,
         "start_line" => start_line,
         "num_lines" => num_lines,
         "total_lines" => total_lines,
         "num_tokens" => num_tokens
       })}
    end
  end

  def file_content_message(other), do: {:error, {:not_a_map, other}}

  # ── GrepResultMessage ──────────────────────────────────────────────────────

  @doc """
  Builds a GrepResultMessage internal map.

  ## Required fields

  - `"search_term"` — string
  - `"directory"` — string
  - `"total_matches"` — integer ≥ 0
  - `"files_searched"` — integer ≥ 0

  ## Optional fields

  - `"matches"` — list of GrepMatch maps (default: `[]`)
  - `"verbose"` — boolean (default: `false`)
  """
  @spec grep_result_message(map()) :: {:ok, map()} | {:error, term()}
  def grep_result_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, search_term} <- Validation.require_string(fields, "search_term"),
         {:ok, directory} <- Validation.require_string(fields, "directory"),
         {:ok, matches} <- Validation.validate_list(fields, "matches", &Entries.grep_match/1),
         {:ok, total_matches} <- Validation.require_integer(fields, "total_matches", min: 0),
         {:ok, files_searched} <- Validation.require_integer(fields, "files_searched", min: 0),
         {:ok, verbose} <- Validation.optional_boolean(fields, "verbose", false) do
      {:ok,
       Map.merge(base, %{
         "search_term" => search_term,
         "directory" => directory,
         "matches" => matches,
         "total_matches" => total_matches,
         "files_searched" => files_searched,
         "verbose" => verbose
       })}
    end
  end

  def grep_result_message(other), do: {:error, {:not_a_map, other}}

  # ── DiffMessage ────────────────────────────────────────────────────────────

  @diff_operations ~w(create modify delete)

  @doc """
  Builds a DiffMessage internal map.

  ## Required fields

  - `"path"` — string
  - `"operation"` — literal `"create"`, `"modify"`, or `"delete"`

  ## Optional fields

  - `"old_content"` — string or nil (default: nil)
  - `"new_content"` — string or nil (default: nil)
  - `"diff_lines"` — list of DiffLine maps (default: `[]`)
  - `"raw_diff_text"` — string (default: `""`)
  """
  @spec diff_message(map()) :: {:ok, map()} | {:error, term()}
  def diff_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, path} <- Validation.require_string(fields, "path"),
         {:ok, operation} <- Validation.require_literal(fields, "operation", @diff_operations),
         {:ok, old_content} <- Validation.optional_string(fields, "old_content"),
         {:ok, new_content} <- Validation.optional_string(fields, "new_content"),
         {:ok, diff_lines} <- Validation.validate_list(fields, "diff_lines", &Entries.diff_line/1),
         {:ok, raw_diff_text} <- validate_raw_diff_text(fields) do
      {:ok,
       Map.merge(base, %{
         "path" => path,
         "operation" => operation,
         "old_content" => old_content,
         "new_content" => new_content,
         "diff_lines" => diff_lines,
         "raw_diff_text" => raw_diff_text
       })}
    end
  end

  def diff_message(other), do: {:error, {:not_a_map, other}}

  defp validate_raw_diff_text(fields) do
    case Map.fetch(fields, "raw_diff_text") do
      :error -> {:ok, ""}
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, "raw_diff_text", other}}
    end
  end

  # ── ShellStartMessage ──────────────────────────────────────────────────────

  @doc """
  Builds a ShellStartMessage internal map.

  ## Required fields

  - `"command"` — string

  ## Optional fields

  - `"cwd"` — string or nil (default: nil)
  - `"timeout"` — integer (default: 60)
  - `"background"` — boolean (default: `false`)
  """
  @spec shell_start_message(map()) :: {:ok, map()} | {:error, term()}
  def shell_start_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, command} <- Validation.require_string(fields, "command"),
         {:ok, cwd} <- Validation.optional_string(fields, "cwd"),
         {:ok, timeout} <- validate_timeout(fields),
         {:ok, background} <- Validation.optional_boolean(fields, "background", false) do
      {:ok,
       Map.merge(base, %{
         "command" => command,
         "cwd" => cwd,
         "timeout" => timeout,
         "background" => background
       })}
    end
  end

  def shell_start_message(other), do: {:error, {:not_a_map, other}}

  defp validate_timeout(fields) do
    case Map.fetch(fields, "timeout") do
      :error -> {:ok, 60}
      {:ok, v} when is_integer(v) -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, "timeout", other}}
    end
  end

  # ── ShellLineMessage ──────────────────────────────────────────────────────

  @shell_streams ~w(stdout stderr)

  @doc """
  Builds a ShellLineMessage internal map.

  ## Required fields

  - `"line"` — string

  ## Optional fields

  - `"stream"` — literal `"stdout"` or `"stderr"` (default: `"stdout"`)
  """
  @spec shell_line_message(map()) :: {:ok, map()} | {:error, term()}
  def shell_line_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, line} <- Validation.require_string(fields, "line"),
         {:ok, stream} <- validate_stream(fields) do
      {:ok, Map.merge(base, %{"line" => line, "stream" => stream})}
    end
  end

  def shell_line_message(other), do: {:error, {:not_a_map, other}}

  defp validate_stream(fields) do
    case Map.fetch(fields, "stream") do
      :error -> {:ok, "stdout"}
      {:ok, v} when v in @shell_streams -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_literal, "stream", other, @shell_streams}}
    end
  end

  # ── ShellOutputMessage ─────────────────────────────────────────────────────

  @doc """
  Builds a ShellOutputMessage internal map.

  ## Required fields

  - `"command"` — string
  - `"exit_code"` — integer
  - `"duration_seconds"` — number ≥ 0

  ## Optional fields

  - `"stdout"` — string (default: `""`)
  - `"stderr"` — string (default: `""`)
  """
  @spec shell_output_message(map()) :: {:ok, map()} | {:error, term()}
  def shell_output_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, command} <- Validation.require_string(fields, "command"),
         {:ok, stdout} <- validate_default_string(fields, "stdout"),
         {:ok, stderr} <- validate_default_string(fields, "stderr"),
         {:ok, exit_code} <- Validation.require_integer(fields, "exit_code"),
         {:ok, duration_seconds} <- Validation.require_number(fields, "duration_seconds", min: 0) do
      {:ok,
       Map.merge(base, %{
         "command" => command,
         "stdout" => stdout,
         "stderr" => stderr,
         "exit_code" => exit_code,
         "duration_seconds" => duration_seconds
       })}
    end
  end

  def shell_output_message(other), do: {:error, {:not_a_map, other}}

  defp validate_default_string(fields, key) do
    case Map.fetch(fields, key) do
      :error -> {:ok, ""}
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, key, other}}
    end
  end

  # ── UniversalConstructorMessage ────────────────────────────────────────────

  @doc """
  Builds a UniversalConstructorMessage internal map.

  ## Required fields

  - `"action"` — string (the UC action performed)
  - `"success"` — boolean
  - `"summary"` — string

  ## Optional fields

  - `"tool_name"` — string or nil (default: nil)
  - `"details"` — string or nil (default: nil)
  """
  @spec universal_constructor_message(map()) :: {:ok, map()} | {:error, term()}
  def universal_constructor_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, action} <- Validation.require_string(fields, "action"),
         {:ok, tool_name} <- Validation.optional_string(fields, "tool_name"),
         {:ok, success} <- Validation.require_boolean(fields, "success"),
         {:ok, summary} <- Validation.require_string(fields, "summary"),
         {:ok, details} <- Validation.optional_string(fields, "details") do
      {:ok,
       Map.merge(base, %{
         "action" => action,
         "tool_name" => tool_name,
         "success" => success,
         "summary" => summary,
         "details" => details
       })}
    end
  end

  def universal_constructor_message(other), do: {:error, {:not_a_map, other}}
end
