defmodule CodePuppyControl.Messaging.Agent do
  @moduledoc """
  Agent message constructors for Agent→UI messaging.

  Provides validated constructors for all message families in the
  `agent` category. Mirrors the Python models in
  `code_puppy/messaging/messages.py`.

  | Python class                 | Elixir function               |
  |------------------------------|-------------------------------|
  | `AgentReasoningMessage`      | `agent_reasoning_message/1`   |
  | `AgentResponseMessage`       | `agent_response_message/1`    |
  | `SubAgentInvocationMessage`  | `sub_agent_invocation_message/1` |
  | `SubAgentResponseMessage`    | `sub_agent_response_message/1` |
  | `SubAgentStatusMessage`      | `sub_agent_status_message/1`   |

  All constructors return `{:ok, map}` or `{:error, reason}` — never raise.
  Category defaults to `\"agent\"`; providing a mismatched category is rejected.
  """

  alias CodePuppyControl.Messaging.Validation

  @default_category "agent"

  # ── AgentReasoningMessage ──────────────────────────────────────────────────

  @doc """
  Builds an AgentReasoningMessage internal map.

  ## Required fields

  - `"reasoning"` — string, the agent's current reasoning/thought process

  ## Optional fields

  - `"next_steps"` — string or nil (default: nil)
  """
  @spec agent_reasoning_message(map()) :: {:ok, map()} | {:error, term()}
  def agent_reasoning_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, reasoning} <- Validation.require_string(fields, "reasoning"),
         {:ok, next_steps} <- Validation.optional_string(fields, "next_steps") do
      {:ok, Map.merge(base, %{"reasoning" => reasoning, "next_steps" => next_steps})}
    end
  end

  def agent_reasoning_message(other), do: {:error, {:not_a_map, other}}

  # ── AgentResponseMessage ───────────────────────────────────────────────────

  @doc """
  Builds an AgentResponseMessage internal map.

  ## Required fields

  - `"content"` — string, the response content

  ## Optional fields with defaults

  - `"is_markdown"` — boolean (default: `false`)
  - `"was_streamed"` — boolean (default: `false`)
  - `"streamed_line_count"` — integer ≥ 0 (default: 0)
  """
  @spec agent_response_message(map()) :: {:ok, map()} | {:error, term()}
  def agent_response_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, content} <- Validation.require_string(fields, "content"),
         {:ok, is_markdown} <- Validation.optional_boolean(fields, "is_markdown", false),
         {:ok, was_streamed} <- Validation.optional_boolean(fields, "was_streamed", false),
         {:ok, streamed_line_count} <-
           validate_streamed_line_count(fields, "streamed_line_count") do
      {:ok,
       Map.merge(base, %{
         "content" => content,
         "is_markdown" => is_markdown,
         "was_streamed" => was_streamed,
         "streamed_line_count" => streamed_line_count
       })}
    end
  end

  def agent_response_message(other), do: {:error, {:not_a_map, other}}

  # ── SubAgentInvocationMessage ──────────────────────────────────────────────

  @doc """
  Builds a SubAgentInvocationMessage internal map.

  ## Required fields

  - `"agent_name"` — string
  - `"session_id"` — string
  - `"prompt"` — string
  - `"is_new_session"` — boolean

  ## Optional fields with defaults

  - `"message_count"` — integer ≥ 0 (default: 0)
  """
  @spec sub_agent_invocation_message(map()) :: {:ok, map()} | {:error, term()}
  def sub_agent_invocation_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, agent_name} <- Validation.require_string(fields, "agent_name"),
         {:ok, session_id} <- Validation.require_string(fields, "session_id"),
         {:ok, prompt} <- Validation.require_string(fields, "prompt"),
         {:ok, is_new_session} <- Validation.require_boolean(fields, "is_new_session"),
         {:ok, message_count} <-
           Validation.optional_integer(fields, "message_count", min: 0) do
      {:ok,
       Map.merge(base, %{
         "agent_name" => agent_name,
         "session_id" => session_id,
         "prompt" => prompt,
         "is_new_session" => is_new_session,
         "message_count" => message_count || 0
       })}
    end
  end

  def sub_agent_invocation_message(other), do: {:error, {:not_a_map, other}}

  # ── SubAgentResponseMessage ────────────────────────────────────────────────

  @doc """
  Builds a SubAgentResponseMessage internal map.

  ## Required fields

  - `"agent_name"` — string
  - `"session_id"` — string
  - `"response"` — string

  ## Optional fields with defaults

  - `"message_count"` — integer ≥ 0 (default: 0)
  - `"was_streamed"` — boolean (default: `false`)
  - `"streamed_line_count"` — integer ≥ 0 (default: 0)
  """
  @spec sub_agent_response_message(map()) :: {:ok, map()} | {:error, term()}
  def sub_agent_response_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, agent_name} <- Validation.require_string(fields, "agent_name"),
         {:ok, session_id} <- Validation.require_string(fields, "session_id"),
         {:ok, response} <- Validation.require_string(fields, "response"),
         {:ok, message_count} <-
           Validation.optional_integer(fields, "message_count", min: 0),
         {:ok, was_streamed} <- Validation.optional_boolean(fields, "was_streamed", false),
         {:ok, streamed_line_count} <-
           validate_streamed_line_count(fields, "streamed_line_count") do
      {:ok,
       Map.merge(base, %{
         "agent_name" => agent_name,
         "session_id" => session_id,
         "response" => response,
         "message_count" => message_count || 0,
         "was_streamed" => was_streamed,
         "streamed_line_count" => streamed_line_count
       })}
    end
  end

  def sub_agent_response_message(other), do: {:error, {:not_a_map, other}}

  # ── SubAgentStatusMessage ──────────────────────────────────────────────────

  @sub_agent_statuses ~w(starting running thinking tool_calling completed error)

  @doc """
  Builds a SubAgentStatusMessage internal map.

  ## Required fields

  - `"session_id"` — string
  - `"agent_name"` — string
  - `"model_name"` — string
  - `"status"` — literal `"starting"`, `"running"`, `"thinking"`,
    `"tool_calling"`, `"completed"`, or `"error"`

  ## Optional fields with defaults

  - `"tool_call_count"` — integer ≥ 0 (default: 0)
  - `"token_count"` — integer ≥ 0 (default: 0)
  - `"current_tool"` — string or nil (default: nil)
  - `"elapsed_seconds"` — number ≥ 0 (default: 0.0)
  - `"error_message"` — string or nil (default: nil)
  """
  @spec sub_agent_status_message(map()) :: {:ok, map()} | {:error, term()}
  def sub_agent_status_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, session_id} <- Validation.require_string(fields, "session_id"),
         {:ok, agent_name} <- Validation.require_string(fields, "agent_name"),
         {:ok, model_name} <- Validation.require_string(fields, "model_name"),
         {:ok, status} <- Validation.require_literal(fields, "status", @sub_agent_statuses),
         {:ok, tool_call_count} <-
           Validation.optional_integer(fields, "tool_call_count", min: 0),
         {:ok, token_count} <- Validation.optional_integer(fields, "token_count", min: 0),
         {:ok, current_tool} <- Validation.optional_string(fields, "current_tool"),
         {:ok, elapsed_seconds} <-
           Validation.optional_number(fields, "elapsed_seconds", min: 0),
         {:ok, error_message} <- Validation.optional_string(fields, "error_message") do
      {:ok,
       Map.merge(base, %{
         "session_id" => session_id,
         "agent_name" => agent_name,
         "model_name" => model_name,
         "status" => status,
         "tool_call_count" => tool_call_count || 0,
         "token_count" => token_count || 0,
         "current_tool" => current_tool,
         "elapsed_seconds" => elapsed_seconds || 0.0,
         "error_message" => error_message
       })}
    end
  end

  def sub_agent_status_message(other), do: {:error, {:not_a_map, other}}

  # ── Private helpers ────────────────────────────────────────────────────────

  defp validate_streamed_line_count(fields, key) do
    case Map.fetch(fields, key) do
      :error ->
        {:ok, 0}

      {:ok, nil} ->
        {:ok, 0}

      {:ok, v} when is_integer(v) and v >= 0 ->
        {:ok, v}

      {:ok, v} when is_integer(v) ->
        {:error, {:value_below_min, key, v, 0}}

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}
    end
  end
end
