defmodule CodePuppyControl.Messages.Pruner do
  @moduledoc """
  Single-pass pruning, filtering, truncation, and summarization splitting.
  Port of code_puppy_core/src/pruning.rs.
  """

  alias CodePuppyControl.Tokens.Estimator

  @type prune_result :: %{
          surviving_indices: [non_neg_integer()],
          dropped_count: non_neg_integer(),
          had_pending_tool_calls: boolean(),
          pending_tool_call_count: non_neg_integer()
        }

  @type split_result :: %{
          summarize_indices: [non_neg_integer()],
          protected_indices: [non_neg_integer()],
          protected_token_count: integer()
        }

  @default_max_tokens_per_message 50_000

  @doc """
  Prune and filter messages.

  Algorithm:
  1. Collect all tool_call_ids → two sets: call_ids and return_ids
  2. Find mismatched IDs (symmetric_difference of call_ids and return_ids)
  3. For each message:
     - Skip if any part has a mismatched tool_call_id
     - Skip if total tokens >= max_tokens_per_message
     - Skip if it's a single empty "thinking" part
     - Otherwise, add to surviving_indices
  4. Count pending = call_ids - return_ids
  5. Return PruneResult
  """
  @spec prune_and_filter([map()], integer()) :: prune_result()
  def prune_and_filter(messages, max_tokens_per_message \\ @default_max_tokens_per_message) do
    # Collect tool call IDs
    {call_ids, return_ids} =
      Enum.reduce(messages, {MapSet.new(), MapSet.new()}, fn msg, {calls, returns} ->
        parts = msg["parts"] || []

        Enum.reduce(parts, {calls, returns}, fn part, {c, r} ->
          id = part["tool_call_id"]
          kind = part["part_kind"]

          cond do
            id && id != "" && kind == "tool-call" ->
              {MapSet.put(c, id), r}

            id && id != "" ->
              {c, MapSet.put(r, id)}

            true ->
              {c, r}
          end
        end)
      end)

    # Find mismatched IDs using symmetric_difference
    mismatched =
      MapSet.union(
        MapSet.difference(call_ids, return_ids),
        MapSet.difference(return_ids, call_ids)
      )

    # Process each message
    {surviving, dropped} =
      Enum.with_index(messages)
      |> Enum.reduce({[], 0}, fn {msg, idx}, {surv, drop} ->
        parts = msg["parts"] || []

        # Check if any part has mismatched tool_call_id
        has_mismatch =
          Enum.any?(parts, fn part ->
            id = part["tool_call_id"]
            id && MapSet.member?(mismatched, id)
          end)

        # Calculate total tokens
        tokens =
          parts
          |> Enum.map(&Estimator.stringify_part_for_tokens/1)
          |> Enum.map(&Estimator.estimate_tokens/1)
          |> Enum.sum()

        # Check for single empty thinking part
        is_empty_thinking =
          length(parts) == 1 &&
            List.first(parts)
            |> then(fn p ->
              p && p["part_kind"] == "thinking" &&
                (p["content"] == nil || p["content"] == "")
            end)

        cond do
          has_mismatch -> {surv, drop + 1}
          tokens >= max_tokens_per_message -> {surv, drop + 1}
          is_empty_thinking -> {surv, drop + 1}
          true -> {[idx | surv], drop}
        end
      end)

    surviving_indices = Enum.reverse(surviving)
    pending_ids = MapSet.difference(call_ids, return_ids)
    pending_count = MapSet.size(pending_ids)

    %{
      surviving_indices: surviving_indices,
      dropped_count: dropped,
      had_pending_tool_calls: pending_count > 0,
      pending_tool_call_count: pending_count
    }
  end

  @doc """
  Calculate truncation indices.

  Algorithm:
  1. Always keep index 0
  2. If second_has_thinking, also keep index 1
  3. Walk from the END backwards, accumulating tokens until budget exhausted
  4. Return the kept indices (sorted)
  """
  @spec truncation_indices([integer()], integer(), boolean()) :: [non_neg_integer()]
  def truncation_indices(per_message_tokens, protected_tokens, second_has_thinking \\ false)

  def truncation_indices([], _, _), do: []

  def truncation_indices(per_message_tokens, protected_tokens, second_has_thinking) do
    result = [0]

    {start_idx, result} =
      if second_has_thinking && length(per_message_tokens) > 1 do
        {2, [1 | result]}
      else
        {1, result}
      end

    # Get the slice from start_idx to end, then reverse it to walk from end
    tail_tokens =
      per_message_tokens
      |> Enum.slice(start_idx, length(per_message_tokens) - start_idx)
      |> Enum.reverse()

    # Walk from end backwards, halt when budget exceeded
    {_, tail} =
      Enum.reduce_while(
        Enum.with_index(tail_tokens),
        {protected_tokens, []},
        fn {tokens, idx}, {budget, tail_acc} ->
          actual_idx = length(per_message_tokens) - 1 - idx
          new_budget = budget - tokens

          if new_budget >= 0 do
            {:cont, {new_budget, [actual_idx | tail_acc]}}
          else
            {:halt, {budget, tail_acc}}
          end
        end
      )

    # Tail is already in correct order due to how we built it
    (tail ++ result)
    |> Enum.sort()
  end

  @doc """
  Split messages for summarization.

  Algorithm:
  1. Always protect index 0
  2. Walk from END backwards, adding to protected tail until budget exceeded
  3. Adjust boundary backwards to not split tool-call/tool-return pairs
  4. Return: summarize_indices (middle), protected_indices (start + tail), protected_token_count
  """
  @spec split_for_summarization([integer()], [map()], integer()) :: split_result()
  def split_for_summarization(per_message_tokens, messages, protected_tokens_limit)

  def split_for_summarization([], _, _) do
    %{
      summarize_indices: [],
      protected_indices: [],
      protected_token_count: 0
    }
  end

  def split_for_summarization([token_count], _, _) do
    %{
      summarize_indices: [],
      protected_indices: [0],
      protected_token_count: token_count
    }
  end

  def split_for_summarization(per_message_tokens, messages, protected_tokens_limit) do
    # Always protect index 0
    first_token = List.first(per_message_tokens) || 0

    # Walk from end backwards, building protected tail
    # Get tokens from index 1 to end, paired with their original indices
    tokens_with_idx =
      per_message_tokens
      |> Enum.slice(1, length(per_message_tokens) - 1)
      # Start indices at 1
      |> Enum.with_index(1)
      # Reverse to walk from end
      |> Enum.reverse()

    # Walk from end, stop when budget exceeded (don't look at earlier messages)
    {_prot_tok, prot_tail} =
      Enum.reduce_while(
        tokens_with_idx,
        {first_token, []},
        fn {tokens, actual_idx}, {acc_tok, acc_indices} ->
          new_tok = acc_tok + tokens

          if new_tok <= protected_tokens_limit do
            {:cont, {new_tok, [actual_idx | acc_indices]}}
          else
            {:halt, {acc_tok, acc_indices}}
          end
        end
      )

    # Determine the boundary for summarization
    prot_start = List.first(prot_tail) || length(per_message_tokens)
    adj = adjust_boundary(prot_start, messages, prot_tail)

    # prot_tok tracks accumulated tokens, prot_tail contains indices from the end

    # Calculate indices
    # For summarize_indices: from 1 up to adj-1, but stop before protected tail
    summarize_indices = if adj > 1, do: Enum.to_list(1..(adj - 1)//1), else: []
    protected_indices = [0 | Enum.to_list(adj..(length(per_message_tokens) - 1)//1)]

    # Calculate protected token count
    protected_token_count =
      Enum.reduce(protected_indices, 0, fn i, acc ->
        acc + Enum.at(per_message_tokens, i, 0)
      end)

    %{
      summarize_indices: summarize_indices,
      protected_indices: protected_indices,
      protected_token_count: protected_token_count
    }
  end

  # Adjust boundary backwards to not split tool-call/tool-return pairs
  defp adjust_boundary(prot_start, messages, prot_tail) when prot_start > 1 do
    # Extract tool call IDs from protected tail messages
    ret_ids =
      Enum.reduce(prot_tail, MapSet.new(), fn idx, acc ->
        msg = Enum.at(messages, idx)
        parts = (msg && msg["parts"]) || []

        Enum.reduce(parts, acc, fn part, ids ->
          id = part["tool_call_id"]
          kind = part["part_kind"]

          cond do
            id && (kind == "tool-return" || kind == "tool_return") ->
              MapSet.put(ids, id)

            true ->
              ids
          end
        end)
      end)

    # Walk backwards from prot_start to find paired tool calls, halt on non-matching
    Enum.reduce_while((prot_start - 1)..1//-1, prot_start, fn i, adj ->
      msg = Enum.at(messages, i)
      parts = (msg && msg["parts"]) || []

      has_matching_call =
        Enum.any?(parts, fn part ->
          id = part["tool_call_id"]
          kind = part["part_kind"]
          id && (kind == "tool-call" || kind == "tool_call") && MapSet.member?(ret_ids, id)
        end)

      if has_matching_call, do: {:cont, i}, else: {:halt, adj}
    end)
  end

  defp adjust_boundary(prot_start, _, _), do: prot_start
end
