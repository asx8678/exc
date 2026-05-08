defmodule CodePuppyControl.MessageCore.Pruner do
  @moduledoc """
  Single-pass pruning, filtering, truncation, and summarization splitting.

  This is a delegation wrapper around `CodePuppyControl.Messages.Pruner`.
  All functionality is delegated to the existing implementation.

  ## Usage

      alias CodePuppyControl.MessageCore.Pruner

      # Prune and filter messages
      result = Pruner.prune_and_filter(messages, max_tokens_per_message)

      # Calculate truncation indices
      indices = Pruner.truncation_indices(per_message_tokens, protected_tokens, second_has_thinking)

      # Split for summarization
      split = Pruner.split_for_summarization(per_message_tokens, messages, protected_tokens_limit)

  ## Migration Path

  Use `MessageCore.Pruner` for new code to match the Python namespace structure.
  The existing `Messages.Pruner` remains available for backward compatibility.
  """

  alias CodePuppyControl.Messages.Pruner, as: Impl

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

  @doc """
  Prune and filter messages.

  Delegates to `CodePuppyControl.Messages.Pruner.prune_and_filter/2`.
  """
  @spec prune_and_filter([map()], integer()) :: prune_result()
  defdelegate prune_and_filter(messages, max_tokens_per_message \\ 50_000), to: Impl

  @doc """
  Calculate truncation indices.

  Delegates to `CodePuppyControl.Messages.Pruner.truncation_indices/3`.
  """
  @spec truncation_indices([integer()], integer(), boolean()) :: [non_neg_integer()]
  defdelegate truncation_indices(
                per_message_tokens,
                protected_tokens,
                second_has_thinking \\ false
              ),
              to: Impl

  @doc """
  Split messages for summarization.

  Delegates to `CodePuppyControl.Messages.Pruner.split_for_summarization/3`.
  """
  @spec split_for_summarization([integer()], [map()], integer()) :: split_result()
  defdelegate split_for_summarization(per_message_tokens, messages, protected_tokens_limit),
    to: Impl
end
