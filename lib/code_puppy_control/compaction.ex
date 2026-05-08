defmodule CodePuppyControl.Compaction do
  @moduledoc """
  Top-level facade for message compaction/pruning.

  Provides the primary API for deciding when to compact and executing
  compaction. Composes on top of existing `Messages.Pruner` for base
  pruning and filtering.

  ## Design

  Compaction has three phases:
  1. **Filter** — Drop mismatched tool pairs, huge messages, empty thinking
     (delegates to `Messages.Pruner.prune_and_filter/2`)
  2. **Truncate** — Shorten old tool args/returns to reclaim tokens cheaply
     (via `Compaction.ToolArgTruncation`)
  3. **Split** — Identify messages for summarization vs protected recent ones
     (via `Messages.Pruner.split_for_summarization/3`)

  ## Usage

      # Check if compaction is needed
      if Compaction.should_compact?(messages) do
        {:ok, compacted, stats} = Compaction.compact(messages)
        # compacted is the new message list, stats has details
      end
  """

  alias CodePuppyControl.Compaction.{FileOpsTracker, ShadowMode, ToolArgTruncation}
  alias CodePuppyControl.Messages.Pruner
  alias CodePuppyControl.Tokens.Estimator

  require Logger

  # Default thresholds
  @default_trigger_messages 150
  @default_keep_fraction 0.20
  @default_min_keep 10

  @type compact_opts :: [
          trigger_messages: pos_integer(),
          keep_fraction: float(),
          min_keep: pos_integer(),
          shadow_mode: boolean(),
          pretruncate: boolean(),
          keep_recent_for_truncation: pos_integer()
        ]

  @type compact_stats :: %{
          original_count: non_neg_integer(),
          filtered_count: non_neg_integer(),
          dropped_by_filter: non_neg_integer(),
          truncated_count: non_neg_integer(),
          summarize_count: non_neg_integer(),
          protected_count: non_neg_integer(),
          has_pending_tool_calls: boolean(),
          pending_tool_call_count: non_neg_integer(),
          file_ops: FileOpsTracker.t() | nil
        }

  @doc """
  Determine if message history needs compaction.

  Uses message count as primary heuristic. Model-aware token thresholds
  are deferred to .

  ## Options

    * `:trigger_messages` — Message count threshold (default: 150)
  """
  @spec should_compact?([map()], keyword()) :: boolean()
  def should_compact?(messages, opts \\ []) do
    trigger = Keyword.get(opts, :trigger_messages, @default_trigger_messages)
    length(messages) >= trigger
  end

  @doc """
  Compact message history through filtering, truncation, and splitting.

  Returns `{:ok, compacted_messages, stats}` on success.
  The `compacted_messages` list is ready to send to the LLM.

  ## Options

    * `:keep_fraction` — Fraction of recent messages to protect (default: 0.20)
    * `:min_keep` — Minimum messages to keep even with small fraction (default: 10)
    * `:shadow_mode` — Enable shadow mode comparison logging (default: false)
    * `:pretruncate` — Enable tool arg truncation pass (default: true)
    * `:keep_recent_for_truncation` — Recent messages to skip during truncation (default: 10)

  ## Tool Pair Integrity

  This module preserves tool-call/tool-return pair integrity:
  - Phase 1 (filter) drops messages with mismatched `tool_call_id`
  - Phase 2 (truncation) processes both parts of a pair independently
    but does not break structural pairing
  - Phase 3 (split) adjusts boundaries to avoid splitting pairs
  """
  @spec compact([map()], compact_opts()) :: {:ok, [map()], compact_stats()}
  def compact(messages, opts \\ []) do
    pretruncate = Keyword.get(opts, :pretruncate, true)
    shadow_mode = Keyword.get(opts, :shadow_mode, false)

    original_count = length(messages)

    # --- Phase 0: Extract file ops for tracking ---
    file_ops = FileOpsTracker.extract_from_messages(messages)

    # --- Phase 1: Base pruning/filtering ---
    prune_result = Pruner.prune_and_filter(messages)

    filtered_messages =
      prune_result.surviving_indices
      |> Enum.map(&Enum.at(messages, &1))

    filtered_count = length(filtered_messages)

    if shadow_mode do
      ShadowMode.compare_and_log(messages,
        old_result: prune_result,
        new_result: prune_result,
        enabled: true,
        label: "compaction-phase1"
      )
    end

    # --- Phase 2: Pre-truncation (cheap token reclaim) ---
    {truncated_messages, truncated_count} =
      if pretruncate and filtered_count > 0 do
        keep_recent = Keyword.get(opts, :keep_recent_for_truncation, 10)

        ToolArgTruncation.pretruncate_messages(filtered_messages,
          keep_recent: keep_recent
        )
      else
        {filtered_messages, 0}
      end

    # --- Phase 3: Split for summarization ---
    {final_messages, stats} =
      split_or_return(truncated_messages, opts, %{
        original_count: original_count,
        filtered_count: filtered_count,
        dropped_by_filter: prune_result.dropped_count,
        truncated_count: truncated_count,
        summarize_count: 0,
        protected_count: filtered_count,
        has_pending_tool_calls: prune_result.had_pending_tool_calls,
        pending_tool_call_count: prune_result.pending_tool_call_count,
        file_ops: file_ops
      })

    Logger.info(
      "Compaction: #{original_count} -> #{length(final_messages)} messages " <>
        "(dropped=#{prune_result.dropped_count}, truncated=#{truncated_count}, " <>
        "pending_tools=#{prune_result.pending_tool_call_count})"
    )

    {:ok, final_messages, stats}
  end

  @doc """
  Get a compact summary of file operations for embedding in a system message.

  Returns XML-formatted string or empty string if no file ops tracked.
  """
  @spec file_ops_summary(FileOpsTracker.t()) :: String.t()
  def file_ops_summary(%FileOpsTracker{} = tracker) do
    FileOpsTracker.format_xml(tracker)
  end

  # --- Private ---

  defp split_or_return(messages, opts, stats) do
    keep_fraction = Keyword.get(opts, :keep_fraction, @default_keep_fraction)
    min_keep = Keyword.get(opts, :min_keep, @default_min_keep)
    total = length(messages)

    if total <= min_keep do
      {messages, stats}
    else
      # Estimate tokens per message for split algorithm
      per_message_tokens = Enum.map(messages, &Estimator.estimate_message_tokens/1)

      total_tokens = Enum.sum(per_message_tokens)
      keep_tokens = max(floor(total_tokens * keep_fraction), min_keep * 100)

      split_result = Pruner.split_for_summarization(per_message_tokens, messages, keep_tokens)

      summarize_indices = MapSet.new(split_result.summarize_indices)
      protected_indices = MapSet.new(split_result.protected_indices)

      final_messages =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {_msg, idx} -> MapSet.member?(protected_indices, idx) end)
        |> Enum.map(fn {msg, _idx} -> msg end)

      stats = %{
        stats
        | summarize_count: MapSet.size(summarize_indices),
          protected_count: MapSet.size(protected_indices)
      }

      {final_messages, stats}
    end
  end
end
