defmodule CodePuppyControl.Agent.Loop.Compaction do
  @moduledoc """
  Message compaction logic for Agent.Loop.

  Before each LLM call, the loop checks whether the message history has
  grown beyond the compaction threshold. If so, it runs the three-phase
  compaction pipeline (filter, truncate, split) from `Compaction.compact/2`
  to reclaim tokens and keep the context window manageable.

  Extracted from `Agent.Loop` to keep it under the 600-line hard cap.
  """

  require Logger

  alias CodePuppyControl.Agent.Events
  alias CodePuppyControl.Compaction

  @doc """
  Conditionally compact messages if the threshold is exceeded.

  Returns the state unchanged when compaction is disabled or the
  message count is below the trigger threshold.
  """
  @spec maybe_compact_messages(map()) :: map()
  def maybe_compact_messages(%{compaction_enabled: false} = state), do: state

  def maybe_compact_messages(%{compaction_enabled: true} = state) do
    if Compaction.should_compact?(state.messages, state.compaction_opts) do
      compact_messages(state)
    else
      state
    end
  end

  @doc """
  Run compaction on the message history and publish stats.

  Returns the state with `messages` replaced by the compacted list.
  """
  @spec compact_messages(map()) :: map()
  def compact_messages(state) do
    case Compaction.compact(state.messages, state.compaction_opts) do
      {:ok, compacted, stats} ->
        Logger.info(
          "Agent.Loop compaction: run_id=#{state.run_id} " <>
            "#{stats.original_count} -> #{length(compacted)} messages " <>
            "(dropped=#{stats.dropped_by_filter}, truncated=#{stats.truncated_count})"
        )

        Events.publish(
          Events.messages_compacted(state.run_id, state.session_id, %{
            original_count: stats.original_count,
            compacted_count: length(compacted),
            dropped_by_filter: stats.dropped_by_filter,
            truncated_count: stats.truncated_count,
            summarize_count: stats.summarize_count,
            protected_count: stats.protected_count
          })
        )

        %{state | messages: compacted}
    end
  end
end
