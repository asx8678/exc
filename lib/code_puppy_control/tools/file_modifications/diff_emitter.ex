defmodule CodePuppyControl.Tools.FileModifications.DiffEmitter do
  @moduledoc """
  Structured diff message emission for file modifications.

  Port of `code_puppy/tools/file_modifications.py:_emit_diff_message`.

  Emits diff events to the event bus for UI display. Parses unified
  diff text into structured line objects for rich rendering.

  ## Design

  - Parses unified diff into structured `DiffLine` objects
  - Emits via `CodePuppyControl.EventBus` for TUI consumption
  - Empty diffs are silently skipped

  > **Note:** The Python implementation skips emission when the diff was
  > already shown during a permission prompt. The Elixir permission layer
  > does not have a pre-view prompt, so this skip behavior is not applicable.
  """

  require Logger

  # Regex for parsing git diff hunk headers: @@ -start,count +start,count @@
  @hunk_header_regex ~r/@@ -\d+(?:,\d+)? \+(\d+)/

  @doc """
  Emit a structured diff message for UI display.

  ## Parameters

    * `file_path` — Path to the modified file
    * `operation` — One of `:create`, `:modify`, `:delete`
    * `diff_text` — Raw unified diff text
    * `opts` — Options: `:old_content`, `:new_content`

  ## Examples

      iex> DiffEmitter.emit_diff("/tmp/test.txt", :modify, "--- a/test.txt\\n+++ b/test.txt\\n@@ -1 +1 @@\\n-old\\n+new")
      :ok
  """
  @spec emit_diff(Path.t(), :create | :modify | :delete, String.t(), keyword()) :: :ok
  def emit_diff(file_path, operation, diff_text, opts \\ []) do
    if diff_text == nil or String.trim(diff_text) == "" do
      :ok
    else
      do_emit_diff(file_path, operation, diff_text, opts)
    end
  end

  @doc """
  Parse unified diff text into structured diff line maps.

  Each line map has:
  - `:line_number` — Line number (1-based)
  - `:type` — One of `:add`, `:remove`, `:context`
  - `:content` — Line content

  ## Examples

      iex> DiffEmitter.parse_diff_lines("--- a/test.txt\\n+++ b/test.txt\\n@@ -1 +1 @@\\n-old\\n+new")
      [%{line_number: 1, type: :remove, content: "old"}, %{line_number: 1, type: :add, content: "new"}]
  """
  @spec parse_diff_lines(String.t()) :: [map()]
  def parse_diff_lines(diff_text) when is_binary(diff_text) do
    if String.trim(diff_text) == "" do
      []
    else
      diff_text
      |> String.split("\n")
      |> Enum.reduce({0, []}, fn line, {line_num, acc} ->
        parse_diff_line(line, line_num, acc)
      end)
      |> elem(1)
      |> Enum.reverse()
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp do_emit_diff(file_path, operation, diff_text, opts) do
    diff_lines = parse_diff_lines(diff_text)

    event = %{
      type: :file_diff,
      path: file_path,
      operation: operation,
      diff_lines: diff_lines,
      raw_diff_text: diff_text,
      old_content: Keyword.get(opts, :old_content),
      new_content: Keyword.get(opts, :new_content),
      timestamp: System.monotonic_time(:millisecond)
    }

    # Emit to event bus (if available)
    case Process.whereis(CodePuppyControl.EventBus) do
      nil ->
        Logger.debug(
          "DiffEmitter: EventBus not available, skipping diff emission for #{file_path}"
        )

      _pid ->
        if function_exported?(CodePuppyControl.EventBus, :broadcast_event, 2) do
          CodePuppyControl.EventBus.broadcast_event(event)
        end
    end

    :ok
  end

  # Parse individual diff lines
  defp parse_diff_line(line, line_num, acc) do
    cond do
      # Add line (starts with + but not +++)
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
        new_num = line_num + 1
        content = String.slice(line, 1..-1//1)
        entry = %{line_number: new_num, type: :add, content: content}
        {new_num, [entry | acc]}

      # Remove line (starts with - but not ---)
      String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
        new_num = line_num + 1
        content = String.slice(line, 1..-1//1)
        entry = %{line_number: new_num, type: :remove, content: content}
        {new_num, [entry | acc]}

      # Hunk header — extract line number
      String.starts_with?(line, "@@") ->
        new_num =
          case Regex.run(@hunk_header_regex, line) do
            [_, num_str] -> String.to_integer(num_str) - 1
            _ -> line_num
          end

        entry = %{line_number: max(1, new_num), type: :context, content: line}
        {new_num, [entry | acc]}

      # File headers (--- and +++)
      String.starts_with?(line, "---") or String.starts_with?(line, "+++") ->
        entry = %{line_number: line_num, type: :context, content: line}
        {line_num, [entry | acc]}

      # Context line
      true ->
        new_num = line_num + 1
        entry = %{line_number: max(1, new_num), type: :context, content: line}
        {new_num, [entry | acc]}
    end
  end
end
