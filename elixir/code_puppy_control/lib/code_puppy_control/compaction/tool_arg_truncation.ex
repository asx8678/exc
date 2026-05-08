defmodule CodePuppyControl.Compaction.ToolArgTruncation do
  @moduledoc """
  Pre-summarization optimization: truncate large tool call args and results.

  This is a cheap pass that reclaims significant tokens without an LLM call.
  Targets write_file/edit_file tool calls where the 'content' arg can be huge,
  and tool returns (read_file, grep, list_files) where return content can be very large.

  Port of `code_puppy/compaction/tool_arg_truncation.py`.

  ## Usage

      {messages, count} = ToolArgTruncation.pretruncate_messages(messages, keep_recent: 10)
  """

  # Tool names whose args are commonly large
  @target_tools MapSet.new(~w(write_file edit_file replace_in_file create_file apply_patch))

  # Keys within tool call args to truncate if oversized
  @target_keys MapSet.new(~w(content new_content old_string new_string patch text))

  # Defaults
  @default_max_arg_length 500
  @default_truncation_text " ...(argument truncated during compaction)"
  @default_max_return_length 5000
  @default_return_head_chars 500
  @default_return_tail_chars 200
  @default_return_truncation_text "\n...(truncated during compaction)...\n"

  @doc """
  Truncate a single string value if it exceeds max_length.

  Returns `{new_value, was_modified}`.
  """
  @spec truncate_value(String.t(), pos_integer(), String.t()) :: {String.t(), boolean()}
  def truncate_value(
        value,
        max_length \\ @default_max_arg_length,
        truncation_text \\ @default_truncation_text
      )

  def truncate_value(value, max_length, truncation_text) when is_binary(value) do
    if String.length(value) <= max_length do
      {value, false}
    else
      {String.slice(value, 0, max_length) <> truncation_text, true}
    end
  end

  def truncate_value(value, _max_length, _truncation_text), do: {value, false}

  @doc """
  Truncate target keys in a tool call's args if it's a target tool.

  Returns `{new_args_map, was_modified}`.
  """
  @spec truncate_tool_call_args(String.t(), map() | any(), keyword()) :: {any(), boolean()}
  def truncate_tool_call_args(tool_name, args, opts \\ [])

  def truncate_tool_call_args(tool_name, args, opts) when is_map(args) do
    if MapSet.member?(@target_tools, tool_name) do
      max_length = Keyword.get(opts, :max_length, @default_max_arg_length)
      truncation_text = Keyword.get(opts, :truncation_text, @default_truncation_text)
      target_keys = Keyword.get(opts, :target_keys, @target_keys)

      {new_args, any_modified} =
        Enum.reduce(args, {%{}, false}, fn {key, value}, {acc, modified?} ->
          if MapSet.member?(target_keys, key) do
            {new_value, was_truncated} = truncate_value(value, max_length, truncation_text)
            {Map.put(acc, key, new_value), modified? or was_truncated}
          else
            {Map.put(acc, key, value), modified?}
          end
        end)

      {new_args, any_modified}
    else
      {args, false}
    end
  end

  def truncate_tool_call_args(_tool_name, args, _opts), do: {args, false}

  @doc """
  Truncate tool return content if it's a string and too long.

  Preserves the first head_chars and last tail_chars with a truncation marker.

  Returns `{new_content, was_modified}`.
  """
  @spec truncate_tool_return_content(any(), keyword()) :: {any(), boolean()}
  def truncate_tool_return_content(content, opts \\ [])

  def truncate_tool_return_content(content, opts) when is_binary(content) do
    max_length = Keyword.get(opts, :max_length, @default_max_return_length)
    head_chars = Keyword.get(opts, :head_chars, @default_return_head_chars)
    tail_chars = Keyword.get(opts, :tail_chars, @default_return_tail_chars)
    truncation_text = Keyword.get(opts, :truncation_text, @default_return_truncation_text)

    if String.length(content) <= max_length do
      {content, false}
    else
      total = String.length(content)
      head = String.slice(content, 0, head_chars)
      tail = String.slice(content, -tail_chars, tail_chars)
      truncated = head <> truncation_text <> tail
      {"[Truncated: tool return was #{total} chars]\n" <> truncated, true}
    end
  end

  def truncate_tool_return_content(content, _opts), do: {content, false}

  @doc """
  Pre-truncate tool call args AND tool returns in older messages.

  This is an OPTIONAL cheap pass to run BEFORE full summarization. It tries to
  reclaim tokens without an LLM call.

  ## Options

    * `:keep_recent` — Don't touch the last N messages (default: 10)
    * `:max_length` — Max characters per target arg (default: 500)
    * `:max_return_length` — Max characters for tool returns (default: 5000)
    * `:return_head_chars` — Characters to keep from start of returns (default: 500)
    * `:return_tail_chars` — Characters to keep from end of returns (default: 200)

  Returns `{modified_messages, truncation_count}`.
  """
  @spec pretruncate_messages([map()], keyword()) :: {[map()], non_neg_integer()}
  def pretruncate_messages(messages, opts \\ []) when is_list(messages) do
    keep_recent = Keyword.get(opts, :keep_recent, 10)

    if length(messages) <= keep_recent do
      {messages, 0}
    else
      {older, recent} = Enum.split(messages, length(messages) - keep_recent)

      {modified_older, count} =
        Enum.reduce(older, {[], 0}, fn msg, {acc, trunc_count} ->
          new_msg = truncate_message_parts(msg, opts)

          if new_msg != msg do
            {[new_msg | acc], trunc_count + 1}
          else
            {[msg | acc], trunc_count}
          end
        end)

      {Enum.reverse(modified_older) ++ recent, count}
    end
  end

  @doc """
  Truncate a single message's parts in-place.

  Processes both tool-call args and tool-return content.
  """
  @spec truncate_message_parts(map(), keyword()) :: map()
  def truncate_message_parts(message, opts \\ []) do
    parts = get_field(message, :parts) || []

    {new_parts, any_modified?} =
      Enum.reduce(parts, {[], false}, fn part, {acc, modified?} ->
        {new_part, was_modified} = truncate_part(part, opts)
        {[new_part | acc], modified? or was_modified}
      end)

    if any_modified? do
      put_field(message, :parts, Enum.reverse(new_parts))
    else
      message
    end
  end

  # --- Private ---

  defp truncate_part(part, opts) do
    kind = get_field(part, :part_kind)

    cond do
      kind == "tool-call" ->
        truncate_tool_call_part(part, opts)

      kind == "tool-return" or kind == "tool_return" ->
        truncate_tool_return_part(part, opts)

      true ->
        {part, false}
    end
  end

  defp truncate_tool_call_part(part, opts) do
    tool_name = get_field(part, :tool_name) || ""
    args = get_field(part, :args) || %{}

    {new_args, modified?} = truncate_tool_call_args(tool_name, args, opts)

    if modified? do
      {put_field(part, :args, new_args), true}
    else
      {part, false}
    end
  end

  defp truncate_tool_return_part(part, opts) do
    content = get_field(part, :content)

    {new_content, modified?} = truncate_tool_return_content(content, opts)

    if modified? do
      {put_field(part, :content, new_content), true}
    else
      {part, false}
    end
  end

  # Handle both atom and string keys for cross-module compatibility
  defp get_field(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      val -> val
    end
  end

  defp put_field(map, key, value) when is_atom(key) do
    if Map.has_key?(map, key) do
      Map.put(map, key, value)
    else
      Map.put(map, Atom.to_string(key), value)
    end
  end
end
