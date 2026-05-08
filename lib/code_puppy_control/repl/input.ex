defmodule CodePuppyControl.REPL.Input do
  @moduledoc """
  Terminal input handling for the REPL.

  Supports:
  - Basic line input via :io.get_line/2
  - Multi-line input detection (unclosed brackets/quotes)
  - Prompt rendering with context (agent, model, session)

  Phase 2-3 will add raw mode for arrow keys, tab completion,
  and full readline features.
  """

  # ── Prompt Rendering ─────────────────────────────────────────────────────

  @doc """
  Renders the REPL prompt string with context.

  Format: `🐶 [agent@model] > `

  ## Options

    * `:agent` - Current agent name (default: "code-puppy")
    * `:model` - Current model name (default: "default")
    * `:session_id` - Session identifier (shown abbreviated)
    * `:multiline` - Whether in multiline continuation mode
  """
  @spec display_prompt(keyword()) :: String.t()
  def display_prompt(opts \\ []) do
    agent = Keyword.get(opts, :agent, "code-puppy")
    model = Keyword.get(opts, :model, "default")
    multiline = Keyword.get(opts, :multiline, false)

    prompt_prefix = if multiline, do: "... ", else: "🐶"
    model_short = shorten_model_name(model)

    "#{prompt_prefix} [#{agent}@#{model_short}] > "
  end

  @doc """
  Reads a line of input from stdin.

  Returns `{:ok, line}` with the trimmed line, `:eof` on end of input,
  or `{:error, reason}` on failure.

  Uses `:io.get_line/2` as the basic input mechanism. Raw mode with
  arrow keys and completion is deferred to Phase 2.
  """
  @spec read_line(String.t()) :: {:ok, String.t()} | :eof | {:error, term()}
  def read_line(prompt) do
    case :io.get_line(prompt) do
      :eof ->
        :eof

      {:error, reason} ->
        {:error, reason}

      line when is_binary(line) ->
        {:ok, String.trim_trailing(line, "\n")}

      line when is_list(line) ->
        # :io.get_line can return a charlist
        {:ok, line |> List.to_string() |> String.trim_trailing("\n")}
    end
  end

  @doc """
  Reads input with multi-line continuation support.

  If the first line has unclosed brackets, parens, braces, or quotes,
  continues reading until all delimiters are closed.

  Returns the complete input with newlines joining the lines.
  """
  @spec read_multiline(String.t(), keyword()) :: {:ok, String.t()} | :eof | {:error, term()}
  def read_multiline(prompt, opts \\ []) do
    case read_line(prompt) do
      {:ok, line} ->
        read_continuation(line, opts)

      other ->
        other
    end
  end

  @doc """
  Determines if a line needs continuation (unclosed delimiters).

  Tracks opening/closing of `()`, `[]`, `{}`, and `""` quotes.
  Ignores delimiters inside strings.

  ## Examples

      iex> multiline_continue?("def foo do")
      true

      iex> multiline_continue?("print('hello')")
      false

      iex> multiline_continue?("x = [1, 2,")
      true
  """
  @spec multiline_continue?(String.t()) :: boolean()
  def multiline_continue?(line) do
    depth = delimiter_depth(line)
    depth != 0
  end

  @doc """
  Returns the current nesting depth of delimiters in a string.

  Positive = more opening than closing, negative = more closing (invalid).
  Zero = balanced.
  """
  @spec delimiter_depth(String.t()) :: integer()
  def delimiter_depth(line) do
    line
    |> String.codepoints()
    |> Enum.reduce({0, nil}, fn
      # Inside a string — track opening/closing
      "\"", {depth, nil} -> {depth, :string}
      "\"", {depth, :string} -> {depth, nil}
      "'", {depth, nil} -> {depth, :single_string}
      "'", {depth, :single_string} -> {depth, nil}
      # Opening delimiters (not inside string)
      "(", {depth, nil} -> {depth + 1, nil}
      "[", {depth, nil} -> {depth + 1, nil}
      "{", {depth, nil} -> {depth + 1, nil}
      # Closing delimiters (not inside string)
      ")", {depth, nil} -> {depth - 1, nil}
      "]", {depth, nil} -> {depth - 1, nil}
      "}", {depth, nil} -> {depth - 1, nil}
      # Any other character
      _, acc -> acc
    end)
    |> elem(0)
  end

  # ── Private Helpers ───────────────────────────────────────────────────────

  defp read_continuation(acc, opts) do
    if multiline_continue?(acc) do
      continuation_prompt = display_prompt(Keyword.put(opts, :multiline, true))

      case read_line(continuation_prompt) do
        {:ok, line} ->
          read_continuation(acc <> "\n" <> line, opts)

        :eof ->
          # EOF during continuation — return what we have
          {:ok, acc}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, acc}
    end
  end

  # Shorten model names for display:
  # "claude-sonnet-4-20250514" → "claude-sonnet-4"
  # "gpt-4o-2024-05-13" → "gpt-4o"
  # Short names pass through unchanged
  @spec shorten_model_name(String.t()) :: String.t()
  defp shorten_model_name(name) do
    # Strip date suffixes like -20250514 or -2024-05-13
    String.replace(name, ~r/-\d{4}-\d{2}-\d{2}$/, "")
    |> String.replace(~r/-\d{8}$/, "")
  end
end
