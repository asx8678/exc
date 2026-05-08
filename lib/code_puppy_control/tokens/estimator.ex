defmodule CodePuppyControl.Tokens.Estimator do
  @moduledoc """
  Token estimation and batch message processing.
  Port of code_puppy_core/src/token_estimation.rs.

  Uses ETS memoization keyed on content hash for performance.
  """

  alias CodePuppyControl.Messages.{Hasher, Types}

  # Threshold above which we switch to line-sampling
  @sampling_threshold 500

  # Minimum ratio for code detection: >30% of lines must have code indicators
  @code_detection_ratio 0.3

  # Characters per token ratios
  @chars_per_token_code 4.5
  @chars_per_token_prose 4.0

  # ETS table name for memoization
  @ets_table :token_estimate_cache

  @doc """
  Initialize the ETS cache table for token estimates.
  Called automatically on module load.
  """
  def init_ets do
    try do
      :ets.new(@ets_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    rescue
      ArgumentError ->
        # Table already exists
        @ets_table
    end
  end

  # Auto-initialize on module load
  @on_load :init_on_load

  @doc false
  def init_on_load do
    init_ets()
    :ok
  end

  @doc """
  Ensure the ETS table exists. Called internally before cache operations.
  """
  def ensure_table_exists do
    if :ets.whereis(@ets_table) == :undefined do
      init_ets()
    end

    @ets_table
  end

  @doc """
  Estimate the number of tokens in a text string.

  For short texts (<=500 chars) uses a direct character-ratio heuristic.
  For longer texts, samples ~1% of lines and extrapolates.
  Code-heavy text uses 4.5 chars/token, prose uses 4.0 chars/token.

  Results are memoized in ETS for performance.
  """
  @spec estimate_tokens(String.t()) :: integer()
  def estimate_tokens(text) do
    ensure_table_exists()

    # Check cache first using content hash
    cache_key = :erlang.phash2(text)

    case safe_lookup(@ets_table, cache_key) do
      {:ok, cached_value} ->
        cached_value

      :miss ->
        result = do_estimate_tokens(text)
        safe_insert(@ets_table, {cache_key, result})
        result
    end
  end

  # Safe ETS wrappers that tolerate the table being destroyed by
  # a concurrent test teardown between ensure_table_exists and the
  # actual ETS call. Falls through to compute the result without
  # caching when the table is gone.
  defp safe_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, cached_value}] -> {:ok, cached_value}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp safe_insert(table, entry) do
    :ets.insert(table, entry)
  rescue
    ArgumentError -> :ok
  end

  @spec do_estimate_tokens(String.t()) :: integer()
  defp do_estimate_tokens(""), do: 1

  defp do_estimate_tokens(text) do
    text_len = String.length(text)
    ratio = chars_per_token(text)

    # Fast path for short texts — direct division
    if text_len <= @sampling_threshold do
      max(1, floor(text_len / ratio))
    else
      # Sampling path for large texts
      estimate_with_sampling(text, text_len, ratio)
    end
  end

  @spec estimate_with_sampling(String.t(), integer(), float()) :: integer()
  defp estimate_with_sampling(text, text_len, ratio) do
    lines = String.split(text, "\n")
    num_lines = length(lines)

    # Sample ~1% of lines, minimum 1 line
    step = max(div(num_lines, 100), 1)

    sample_text_len =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {_, i} -> rem(i, step) == 0 end)
      # +1 for newline
      |> Enum.map(fn {line, _} -> String.length(line) + 1 end)
      |> Enum.sum()

    if sample_text_len == 0 do
      max(1, floor(text_len / ratio))
    else
      # Tokens in the sample
      sample_tokens = sample_text_len / ratio
      # Scale up: (sample_tokens / sample_chars) * total_chars
      estimated = sample_tokens / sample_text_len * text_len
      max(1, floor(estimated))
    end
  end

  @doc """
  Return the estimated characters-per-token ratio for the text.
  """
  @spec chars_per_token(String.t()) :: float()
  def chars_per_token(text) do
    if is_code_heavy(text) do
      @chars_per_token_code
    else
      @chars_per_token_prose
    end
  end

  @doc """
  Heuristic: does the text look like source code?

  Uses first 2000 chars to determine, requires >30% of lines to have code indicators.
  """
  @spec is_code_heavy(String.t()) :: boolean()
  def is_code_heavy(text) do
    char_count = String.length(text)

    if char_count < 20 do
      false
    else
      # Use first 2000 chars for detection
      sample = String.slice(text, 0, 2000)
      lines = String.split(sample, "\n")
      line_count = max(length(lines), 1)

      code_lines = Enum.count(lines, &line_has_code_indicators?/1)

      code_lines / line_count > @code_detection_ratio
    end
  end

  @doc """
  Check if a line contains code indicators (braces, brackets, semicolons, keywords).
  """
  @spec line_has_code_indicators?(String.t()) :: boolean()
  def line_has_code_indicators?(line) do
    # Check for braces, brackets, parentheses, semicolons
    has_code_chars = String.match?(line, ~r/[{}\[\]();]/)

    if has_code_chars do
      true
    else
      # Check for language keywords at start of line (after optional whitespace)
      trimmed = String.trim_leading(line)

      # Python keywords
      has_python_keyword =
        String.starts_with?(trimmed, "def ") or
          String.starts_with?(trimmed, "class ") or
          String.starts_with?(trimmed, "import ") or
          String.starts_with?(trimmed, "from ") or
          String.starts_with?(trimmed, "if ") or
          String.starts_with?(trimmed, "for ") or
          String.starts_with?(trimmed, "while ") or
          String.starts_with?(trimmed, "return ")

      # JS/TS keywords
      has_js_keyword =
        String.starts_with?(trimmed, "function ") or
          String.starts_with?(trimmed, "const ") or
          String.starts_with?(trimmed, "let ") or
          String.starts_with?(trimmed, "var ") or
          String.starts_with?(trimmed, "=>")

      # C/C++ keywords
      has_cpp_keyword = String.starts_with?(trimmed, "#include")

      has_python_keyword or has_js_keyword or has_cpp_keyword
    end
  end

  @doc """
  Convert a message part to a string representation for token estimation.

  Accepts maps with either atom or string keys for cross-module compatibility.
  """
  @spec stringify_part_for_tokens(Types.message_part()) :: String.t()
  def stringify_part_for_tokens(part) do
    part_kind = field(part, :part_kind)
    content = field(part, :content)
    content_json = field(part, :content_json)
    tool_name = field(part, :tool_name)
    args = field(part, :args)

    result = "#{part_kind}: "

    result =
      cond do
        is_binary(content) and content != "" ->
          content

        is_binary(content_json) and content_json != "" ->
          content_json

        true ->
          result
      end

    # Append tool_name + args unconditionally (matching Rust behavior)
    if is_binary(tool_name) and tool_name != "" do
      if is_binary(args) and args != "" do
        result <> tool_name <> " " <> args
      else
        result <> tool_name
      end
    else
      result
    end
  end

  @doc """
  Estimate context overhead from tool definitions and system prompt.
  """
  @spec estimate_context_overhead(
          [Types.tool_definition()],
          [Types.tool_definition()],
          String.t()
        ) :: integer()
  def estimate_context_overhead(tool_defs, mcp_tool_defs, system_prompt) do
    total =
      if is_binary(system_prompt) and system_prompt != "" do
        estimate_tokens(system_prompt)
      else
        0
      end

    Enum.reduce(tool_defs ++ mcp_tool_defs, total, fn tool, acc ->
      acc = acc + estimate_tokens(field(tool, :name) || "")

      acc =
        case field(tool, :description) do
          desc when is_binary(desc) and desc != "" ->
            acc + estimate_tokens(desc)

          _ ->
            acc
        end

      case field(tool, :input_schema) do
        nil ->
          acc

        schema ->
          case Jason.encode(schema) do
            {:ok, json} -> acc + estimate_tokens(json)
            {:error, _} -> acc
          end
      end
    end)
  end

  @doc """
  Process a batch of messages and estimate tokens.

  Returns a map with:
  - per_message_tokens: List of token counts per message
  - total_tokens: Sum of all message tokens
  - context_overhead: Tokens from system prompt and tool definitions
  - message_hashes: List of hash values for each message
  """
  @spec process_messages_batch(
          [Types.message()],
          [Types.tool_definition()],
          [Types.tool_definition()],
          String.t()
        ) :: map()
  def process_messages_batch(msgs, tool_defs, mcp_defs, system_prompt) do
    {per_message_tokens, message_hashes, total_message_tokens} =
      Enum.reduce(msgs, {[], [], 0}, fn msg, {tokens_acc, hashes_acc, total} ->
        msg_tokens = estimate_message_tokens(msg)
        msg_hash = Hasher.hash_message(msg)

        {[msg_tokens | tokens_acc], [msg_hash | hashes_acc], total + msg_tokens}
      end)

    per_message_tokens = Enum.reverse(per_message_tokens)
    message_hashes = Enum.reverse(message_hashes)

    context_overhead = estimate_context_overhead(tool_defs, mcp_defs, system_prompt)

    %{
      per_message_tokens: per_message_tokens,
      total_tokens: total_message_tokens,
      context_overhead: context_overhead,
      message_hashes: message_hashes
    }
  end

  @doc """
  Estimate tokens for a single message.
  """
  @spec estimate_message_tokens(Types.message()) :: integer()
  def estimate_message_tokens(msg) do
    tokens =
      (field(msg, :parts) || [])
      |> Enum.map(&stringify_part_for_tokens/1)
      |> Enum.filter(fn s -> s != "" end)
      |> Enum.map(&estimate_tokens/1)
      |> Enum.sum()

    max(1, tokens)
  end

  # Access a field from a map that may use atom or string keys.
  # This allows cross-module compatibility when data comes from JSON (string keys)
  # or from Elixir code (atom keys).
  @doc false
  defp field(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      val -> val
    end
  end
end
