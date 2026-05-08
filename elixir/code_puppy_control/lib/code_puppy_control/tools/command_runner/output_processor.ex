defmodule CodePuppyControl.Tools.CommandRunner.OutputProcessor do
  @moduledoc """
  Output processing for shell command execution.

  Handles line truncation, batched output collection, and output
  formatting for the CommandRunner pipeline.

  ## Design

  Mirrors the Python command_runner's output handling:
  - `MAX_LINE_LENGTH` (256 chars) per line to prevent massive token usage
  - `SHELL_BATCH_SIZE` (10 lines) for batched emission to reduce bus overhead
  - Bounded deques (max 256 lines) for stdout/stderr capture
  - Truncation hint with guidance for the model

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  # Maximum line length for shell command output to prevent massive token usage
  @max_line_length 256

  # Hint appended when a line is truncated
  @line_truncation_hint "... [line truncated, command output too long, try filtering with grep]"

  # Batch size for shell output emissions to reduce bus overhead
  @shell_batch_size 10

  # Maximum number of output lines to retain (deque equivalent)
  @max_output_lines 256

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Truncates a line to the maximum allowed length.

  If the line exceeds `max_length`, it is sliced and the truncation
  hint is appended.  Otherwise returns the line unchanged.
  """
  @spec truncate_line(String.t(), non_neg_integer()) :: String.t()
  def truncate_line(line, max_length \\ @max_line_length) when is_binary(line) do
    if String.length(line) > max_length do
      String.slice(line, 0, max_length) <> @line_truncation_hint
    else
      line
    end
  end

  @doc """
  Returns the configured maximum line length.
  """
  @spec max_line_length() :: non_neg_integer()
  def max_line_length, do: @max_line_length

  @doc """
  Returns the configured line truncation hint.
  """
  @spec line_truncation_hint() :: String.t()
  def line_truncation_hint, do: @line_truncation_hint

  @doc """
  Returns the configured shell batch size.
  """
  @spec shell_batch_size() :: non_neg_integer()
  def shell_batch_size, do: @shell_batch_size

  @doc """
  Returns the configured maximum output lines (deque bound).
  """
  @spec max_output_lines() :: non_neg_integer()
  def max_output_lines, do: @max_output_lines

  @doc """
  Processes raw stdout/stderr output into a structured result map.

  Splits output into lines, truncates each line, and retains at most
  `max_output_lines` lines (keeping the tail).
  """
  @spec process_output(String.t(), keyword()) :: %{lines: [String.t()], text: String.t()}
  def process_output(output, _opts \\ []) when is_binary(output) do
    lines =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.filter(&(&1 != ""))
      |> Enum.map(&truncate_line/1)
      |> Enum.take(-@max_output_lines)

    %{lines: lines, text: Enum.join(lines, "\n")}
  end

  @doc """
  Processes a stream of output chunks, collecting lines with truncation.

  Given a list of raw output chunks (strings), splits each into lines,
  truncates, and maintains a bounded buffer of `max_output_lines` lines.

  This mirrors the Python streaming output reader's deque(maxlen=256) pattern.
  """
  @spec process_chunks([String.t()], keyword()) :: %{lines: [String.t()], text: String.t()}
  def process_chunks(chunks, _opts \\ []) when is_list(chunks) do
    lines =
      chunks
      |> Enum.flat_map(fn chunk ->
        chunk
        |> String.split("\n")
        |> Enum.map(&String.trim_trailing/1)
        |> Enum.filter(&(&1 != ""))
        |> Enum.map(&truncate_line/1)
      end)
      |> Enum.take(-@max_output_lines)

    %{lines: lines, text: Enum.join(lines, "\n")}
  end

  @doc """
  Formats a result map for the CommandRunner return value.

  Applies output processing to stdout and stderr strings.
  """
  @spec format_result(map()) :: map()
  def format_result(result) when is_map(result) do
    stdout = Map.get(result, :stdout, "")
    stderr = Map.get(result, :stderr, "")

    processed_stdout = process_output(stdout)
    processed_stderr = process_output(stderr)

    result
    |> Map.put(:stdout, processed_stdout.text)
    |> Map.put(:stderr, processed_stderr.text)
  end

  @doc """
  Strips ANSI escape sequences from output.

  Useful for PTY output which may contain color codes and cursor movement.
  """
  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(output) when is_binary(output) do
    output
    |> String.replace(~r/\x1B\[[0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\x1B\]\d+;[^\x07]*\x07/, "")
    |> String.replace(~r/\x1B\[\?[0-9;]*[hl]/, "")
  end
end
