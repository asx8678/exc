defmodule CodePuppyControl.Agent.MessageProcessor do
  @moduledoc """
  Message history processing: filtering, dedup, and history maintenance.

  Ports Python's BaseAgent methods for message history management:
  - `ensure_history_ends_with_request`
  - `filter_huge_messages`
  - `message_history_processor` (context management / compaction trigger)
  - `message_history_accumulator` (dedup + compaction integration)

  These functions are **pure** — they operate on message lists and return
  transformed message lists. The Agent.Loop GenServer calls them at
  appropriate points in the turn lifecycle.

  ## Message format

  Messages are maps with `"role"` (string key) following the provider
  convention. Parts-style messages use `"parts"` with `part_kind` values.

  ## Integration with Agent.Loop

  The loop calls `maybe_process_history/3` at the start of each turn,
  before the LLM call. It calls `accumulate_messages/3` after receiving
  new messages from pydantic-ai / the LLM adapter.

  ## Compaction

  Message history processing integrates with `CodePuppyControl.Compaction`
  for context management. When the history exceeds the compaction threshold,
  the processor triggers compaction before the next LLM call.

  This mirrors the Python pattern where `message_history_processor` is
  registered as a pydantic-ai history processor.
  """

  alias CodePuppyControl.Agent.ToolCallTracker
  alias CodePuppyControl.Compaction

  require Logger

  # ---------------------------------------------------------------------------
  # History Maintenance
  # ---------------------------------------------------------------------------

  @doc """
  Ensure message history ends with a user/system message (ModelRequest equivalent).

  Provider APIs (especially Anthropic) require that the last message in the
  conversation is a user or system message, not an assistant message. If the
  history ends with an assistant message (e.g. from a model swap mid-conversation),
  trim trailing assistant messages.

  This is the Elixir port of Python's `ensure_history_ends_with_request`.

  ## Examples

      iex> messages = [
      ...>   %{"role" => "user", "content" => "hello"},
      ...>   %{"role" => "assistant", "content" => "hi"}
      ...> ]
      iex> MessageProcessor.ensure_ends_with_request(messages)
      [%{"role" => "user", "content" => "hello"}]

      iex> messages = [%{"role" => "user", "content" => "hello"}]
      iex> MessageProcessor.ensure_ends_with_request(messages)
      [%{"role" => "user", "content" => "hello"}]
  """
  @spec ensure_ends_with_request([map()]) :: [map()]
  def ensure_ends_with_request(messages) when is_list(messages) do
    # Trim trailing assistant and tool messages so the history
    # ends with a user/system message (required by most provider APIs).
    # We reverse, take while the role is assistant/tool (from the end),
    # then reverse the remainder back.
    {_leading_to_drop, rest} =
      messages
      |> Enum.reverse()
      |> Enum.split_while(fn msg ->
        role = msg["role"] || msg[:role]
        role == "assistant" or role == "tool"
      end)

    Enum.reverse(rest)
  end

  # ---------------------------------------------------------------------------
  # Filtering
  # ---------------------------------------------------------------------------

  @doc """
  Filter out messages that exceed the token threshold.

  Messages with estimated token counts above `max_tokens` are dropped.
  After filtering, interrupted tool calls are pruned to maintain
  tool_use/tool_result pairing.

  Default threshold: 50,000 tokens (matching Python's filter_huge_messages).

  ## Examples

      iex> small_msg = %{"role" => "user", "content" => "hi"}
      iex> MessageProcessor.filter_huge([small_msg], max_tokens: 50000) |> length()
      1
  """
  @spec filter_huge([map()], keyword()) :: [map()]
  def filter_huge(messages, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 50_000)

    filtered =
      Enum.filter(messages, fn msg ->
        estimate_message_tokens(msg) < max_tokens
      end)

    ToolCallTracker.prune_interrupted(filtered)
  end

  # ---------------------------------------------------------------------------
  # History Processing (Compaction Integration)
  # ---------------------------------------------------------------------------

  @doc """
  Process message history for context management.

  Called at the start of each turn by the agent loop. Checks whether
  the history exceeds the compaction threshold and, if so, triggers
  compaction (summarization or truncation).

  Returns `{processed_messages, was_compacted}` where `was_compacted`
  indicates whether compaction was applied.

  This is the Elixir port of Python's `message_history_processor`, adapted
  to the existing `Compaction` module.

  ## Options

    * `:compaction_enabled` — Whether compaction is enabled (default: `true`)
    * `:compaction_opts` — Options passed to `Compaction.compact/2`
    * `:model_context_length` — Model context window size (default: 128_000)
    * `:compaction_threshold` — Fraction of context that triggers compaction (default: 0.8)
  """
  @spec process_history([map()], keyword()) :: {[map()], boolean()}
  def process_history(messages, opts \\ []) do
    compaction_enabled = Keyword.get(opts, :compaction_enabled, true)
    compaction_opts = Keyword.get(opts, :compaction_opts, [])
    model_context_length = Keyword.get(opts, :model_context_length, 128_000)
    compaction_threshold = Keyword.get(opts, :compaction_threshold, 0.8)

    if not compaction_enabled or messages == [] do
      {messages, false}
    else
      estimated_tokens = estimate_batch_tokens(messages)
      proportion_used = estimated_tokens / model_context_length

      if proportion_used > compaction_threshold do
        # Check for pending tool calls before compaction
        {has_pending, _count} = ToolCallTracker.check_pending(messages)

        if has_pending do
          Logger.warning("MessageProcessor: compaction deferred — pending tool calls")
          {messages, false}
        else
          do_compact(messages, compaction_opts)
        end
      else
        {messages, false}
      end
    end
  end

  defp do_compact(messages, compaction_opts) do
    # Filter huge messages first, then compact
    filtered = filter_huge(messages)

    if Compaction.should_compact?(filtered, compaction_opts) do
      case Compaction.compact(filtered, compaction_opts) do
        {:ok, compacted, _stats} ->
          # Prune any tool call mismatches introduced by compaction
          result = ToolCallTracker.prune_interrupted(compacted)
          {result, true}
      end
    else
      {filtered, false}
    end
  end

  # ---------------------------------------------------------------------------
  # Message Accumulator
  # ---------------------------------------------------------------------------

  @doc """
  Accumulate new messages into existing history with deduplication.

  Uses hash-based deduplication to avoid re-adding messages that
  already exist in the history. The hash set is maintained externally
  (by `Agent.State`) for O(1) lookup.

  This is the Elixir port of Python's `message_history_accumulator`,
  simplified to work with the Agent.State hash set.

  ## Parameters

    * `history` — Current message history list
    * `hashes` — MapSet of existing message hashes
    * `new_messages` — Messages to accumulate
    * `hash_fn` — Function to compute message hash (default: `&Agent.State.message_hash/1`)

  ## Returns

    * `{updated_history, updated_hashes, added_count}`

  ## Examples

      iex> alias CodePuppyControl.Agent.State
      iex> history = [%{"role" => "user", "content" => "hello"}]
      iex> hashes = MapSet.new([State.message_hash(hd(history))])
      iex> new = [%{"role" => "user", "content" => "now what"}]
      iex> {h, _hashes, count} = MessageProcessor.accumulate(history, hashes, new)
      iex> count
      1
      iex> length(h)
      2
  """
  @spec accumulate([map()], MapSet.t(), [map()], (map() -> String.t())) ::
          {[map()], MapSet.t(), non_neg_integer()}
  def accumulate(history, hashes, new_messages, hash_fn \\ nil) do
    hash_fn = hash_fn || default_hash_fn()

    {updated_history, updated_hashes, count} =
      Enum.reduce(new_messages, {history, hashes, 0}, fn msg, {h, ha, c} ->
        hash = hash_fn.(msg)

        if MapSet.member?(ha, hash) do
          {h, ha, c}
        else
          {h ++ [msg], MapSet.put(ha, hash), c + 1}
        end
      end)

    # Safety: ensure history ends with a non-assistant message
    final_history = ensure_ends_with_request(updated_history)

    {final_history, updated_hashes, count}
  end

  # ---------------------------------------------------------------------------
  # Truncation
  # ---------------------------------------------------------------------------

  @doc """
  Truncate message history to manage token usage.

  Protects:
  - The first message (system prompt) — always kept
  - Recent messages up to `protected_tokens` limit

  After truncation, interrupted tool calls are pruned.

  ## Examples

      iex> messages = [
      ...>   %{"role" => "system", "content" => "You are helpful"},
      ...>   %{"role" => "user", "content" => "hello"},
      ...>   %{"role" => "assistant", "content" => "hi"},
      ...>   %{"role" => "user", "content" => "do something very long"}
      ...> ]
      iex> MessageProcessor.truncation(messages, protected_tokens: 10) |> length()
      2
  """
  @spec truncation([map()], keyword()) :: [map()]
  def truncation(messages, opts \\ []) do
    protected_tokens = Keyword.get(opts, :protected_tokens, 32_000)

    if messages == [] do
      messages
    else
      # Always keep the first message (system prompt)
      [system_msg | rest] = messages

      # Scan backwards from the end, accumulating tokens
      {kept, _tokens} =
        Enum.reduce(Enum.reverse(rest), {[], 0}, fn msg, {kept, tokens} ->
          msg_tokens = estimate_message_tokens(msg)

          if tokens + msg_tokens > protected_tokens do
            {kept, tokens}
          else
            {[msg | kept], tokens + msg_tokens}
          end
        end)

      result = [system_msg | kept]
      ToolCallTracker.prune_interrupted(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Token Estimation (internal, mirrors Python's estimate_token_count)
  # ---------------------------------------------------------------------------

  @doc """
  Estimate the token count for a single message.

  Uses the simple `length / 2.5` heuristic (matching Python's `_estimate_token_count`),
  examining all text content in the message.

  ## Examples

      iex> MessageProcessor.estimate_message_tokens(%{"role" => "user", "content" => "hello"})
      2

      iex> MessageProcessor.estimate_message_tokens(%{"role" => "system", "content" => ""})
      1
  """
  @spec estimate_message_tokens(map()) :: non_neg_integer()
  def estimate_message_tokens(message) when is_map(message) do
    content = message["content"] || message[:content] || ""

    text =
      if is_binary(content) do
        content
      else
        inspect(content)
      end

    # Also count tool call arguments as tokens
    tool_text =
      case Map.get(message, "tool_calls") || Map.get(message, :tool_calls) do
        nil ->
          ""

        calls when is_list(calls) ->
          Enum.map(calls, fn tc ->
            name = Map.get(tc, :name) || Map.get(tc, "name") || ""
            args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{}
            "#{name} #{inspect(args)}"
          end)
          |> Enum.join(" ")

        _ ->
          ""
      end

    combined = text <> tool_text
    max(1, ceil(String.length(combined) / 2.5))
  end

  @doc """
  Estimate total tokens for a batch of messages.

  ## Examples

      iex> msgs = [
      ...>   %{"role" => "user", "content" => "hello"},
      ...>   %{"role" => "assistant", "content" => "hi there"}
      ...> ]
      iex> MessageProcessor.estimate_batch_tokens(msgs)
      4
  """
  @spec estimate_batch_tokens([map()]) :: non_neg_integer()
  def estimate_batch_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message_tokens(msg) end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp default_hash_fn do
    &CodePuppyControl.Agent.State.message_hash/1
  rescue
    _ -> fn msg -> :erlang.phash2(msg) |> Integer.to_string() end
  end
end
