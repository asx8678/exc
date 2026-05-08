defmodule CodePuppyControl.LLM.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Each provider (OpenAI, Anthropic, etc.) implements this behaviour to provide
  a unified interface for chat completions and streaming.

  ## Design Notes

  - Messages follow the OpenAI convention: `%{role: "user"|"assistant"|"system"|"tool", content: "..."}`
  - Tool calls in assistant messages use `%{id: "...", type: "function", function: %{name: "...", arguments: "..."}}`
  - Stream events are normalized across providers to a common shape
  - The `:http_client` option allows injecting a custom HTTP module for testing;
    defaults to `CodePuppyControl.HttpClient`

  ## No New Dependencies

  Uses `CodePuppyControl.HttpClient` (Finch-based) for all HTTP operations.
  No additional HTTP libraries needed.
  """

  # ── Shared Types ──────────────────────────────────────────────────────────

  @typedoc "Chat message with role and content"
  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t() | nil,
          optional(:tool_call_id) => String.t() | nil,
          optional(:tool_calls) => [tool_call_request()] | nil
        }

  @typedoc "Tool definition for function calling"
  @type tool :: %{
          required(:type) => String.t(),
          required(:function) => %{
            required(:name) => String.t(),
            required(:description) => String.t(),
            required(:parameters) => map()
          }
        }

  @typedoc "A tool call requested by the model in an assistant message"
  @type tool_call_request :: %{
          required(:id) => String.t(),
          required(:type) => String.t(),
          required(:function) => %{
            required(:name) => String.t(),
            required(:arguments) => String.t()
          }
        }

  @typedoc "Completed tool call for tool result messages"
  @type tool_call :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:arguments) => map() | String.t()
        }

  @typedoc "Stream event emitted during streaming"
  @type stream_event ::
          {:part_start,
           %{type: :text | :tool_call, index: non_neg_integer(), id: String.t() | nil}}
          | {:part_delta,
             %{
               type: :text | :tool_call,
               index: non_neg_integer(),
               text: String.t() | nil,
               name: String.t() | nil,
               arguments: String.t() | nil
             }}
          | {:part_end,
             %{
               type: :text | :tool_call,
               index: non_neg_integer(),
               id: String.t() | nil,
               name: String.t() | nil,
               arguments: String.t() | nil
             }}
          | {:done, response()}

  @typedoc "Response from a non-streaming chat completion"
  @type response :: %{
          required(:id) => String.t(),
          required(:model) => String.t(),
          required(:content) => String.t() | nil,
          required(:tool_calls) => [tool_call()],
          required(:finish_reason) => String.t() | nil,
          required(:usage) => %{
            prompt_tokens: non_neg_integer(),
            completion_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          }
        }

  # ── Callbacks ─────────────────────────────────────────────────────────────

  @doc """
  Non-streaming chat completion.

  Returns the complete response with content, tool calls, and usage.
  """
  @callback chat([message()], [tool()], keyword()) ::
              {:ok, response()} | {:error, term()}

  @doc """
  Streaming chat completion.

  Calls `callback_fn` for each stream event as it arrives. The final event
  is always `{:done, response()}` with the aggregated response.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback stream_chat([message()], [tool()], keyword(), (stream_event() -> any())) ::
              :ok | {:error, term()}

  @doc """
  Whether this provider supports function/tool calling.
  """
  @callback supports_tools?() :: boolean()

  @doc """
  Whether this provider supports image/vision inputs.
  """
  @callback supports_vision?() :: boolean()
end
