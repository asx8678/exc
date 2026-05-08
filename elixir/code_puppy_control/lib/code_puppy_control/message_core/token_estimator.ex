defmodule CodePuppyControl.MessageCore.TokenEstimator do
  @moduledoc """
  Token estimation and batch message processing.

  This is a delegation wrapper around `CodePuppyControl.Tokens.Estimator`.
  All functionality is delegated to the existing implementation.

  ## Usage

      alias CodePuppyControl.MessageCore.TokenEstimator

      # Estimate tokens in a string
      tokens = TokenEstimator.estimate_tokens("Hello, world!")

      # Process a batch of messages
      batch = TokenEstimator.process_messages_batch(messages, tools, mcp_tools, system)

  ## Migration Path

  Use `MessageCore.TokenEstimator` for new code to match the Python namespace structure.
  The existing `Tokens.Estimator` remains available for backward compatibility.
  """

  alias CodePuppyControl.Tokens.Estimator, as: Impl
  alias CodePuppyControl.MessageCore.Types

  @doc """
  Estimate the number of tokens in a text string.

  Delegates to `CodePuppyControl.Tokens.Estimator.estimate_tokens/1`.
  """
  @spec estimate_tokens(String.t()) :: integer()
  defdelegate estimate_tokens(text), to: Impl

  @doc """
  Return the estimated characters-per-token ratio for the text.

  Delegates to `CodePuppyControl.Tokens.Estimator.chars_per_token/1`.
  """
  @spec chars_per_token(String.t()) :: float()
  defdelegate chars_per_token(text), to: Impl

  @doc """
  Heuristic: does the text look like source code?

  Delegates to `CodePuppyControl.Tokens.Estimator.is_code_heavy/1`.
  """
  @spec is_code_heavy(String.t()) :: boolean()
  defdelegate is_code_heavy(text), to: Impl

  @doc """
  Convert a message part to a string representation for token estimation.

  Delegates to `CodePuppyControl.Tokens.Estimator.stringify_part_for_tokens/1`.
  """
  @spec stringify_part_for_tokens(Types.message_part()) :: String.t()
  defdelegate stringify_part_for_tokens(part), to: Impl

  @doc """
  Estimate context overhead from tool definitions and system prompt.

  Delegates to `CodePuppyControl.Tokens.Estimator.estimate_context_overhead/3`.
  """
  @spec estimate_context_overhead(
          [Types.tool_definition()],
          [Types.tool_definition()],
          String.t()
        ) :: integer()
  defdelegate estimate_context_overhead(tool_defs, mcp_tool_defs, system_prompt),
    to: Impl

  @doc """
  Process a batch of messages and estimate tokens.

  Returns a map with token counts, context overhead, and message hashes.

  Delegates to `CodePuppyControl.Tokens.Estimator.process_messages_batch/4`.
  """
  @spec process_messages_batch(
          [Types.message()],
          [Types.tool_definition()],
          [Types.tool_definition()],
          String.t()
        ) :: map()
  defdelegate process_messages_batch(msgs, tool_defs, mcp_defs, system_prompt), to: Impl

  @doc """
  Estimate tokens for a single message.

  Delegates to `CodePuppyControl.Tokens.Estimator.estimate_message_tokens/1`.
  """
  @spec estimate_message_tokens(Types.message()) :: integer()
  defdelegate estimate_message_tokens(msg), to: Impl

  @doc """
  Ensure the ETS cache table exists.

  Delegates to `CodePuppyControl.Tokens.Estimator.ensure_table_exists/0`.
  """
  defdelegate ensure_table_exists(), to: Impl
end
