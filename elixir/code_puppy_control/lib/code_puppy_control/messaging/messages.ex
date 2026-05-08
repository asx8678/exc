defmodule CodePuppyControl.Messaging.Messages do
  @moduledoc """
  Structured message constructors for Agent→UI messaging.

  Provides `base_message/1` and `text_message/1` constructors that build
  validated internal maps, auto-generating `id` and `timestamp_unix_ms`
  when absent. Also serves as a facade delegating to family-specific modules
  for the full message catalogue.

  These maps are consumed by `WireEvent.to_wire/1` to produce the JSON-safe
  wire envelope for transport.

  ## Relationship to Python

  Mirrors `code_puppy/messaging/messages.py`:

  | Python class     | Elixir function       |
  |------------------|-----------------------|
  | `BaseMessage`    | `base_message/1`      |
  | `TextMessage`    | `text_message/1`      |
  | `MessageLevel`   | `Types.validate_level/1` |
  | `MessageCategory`| `Types.validate_category/1` |

  For the full message catalogue, see the family-specific modules:

  - `CodePuppyControl.Messaging.ToolOutput` — file, grep, diff, shell, UC messages
  - `CodePuppyControl.Messaging.Agent` — reasoning, response, sub-agent messages
  - `CodePuppyControl.Messaging.UserInteraction` — input, confirmation, selection, ask_user_question
  - `CodePuppyControl.Messaging.Control` — spinner, divider, status, version
  - `CodePuppyControl.Messaging.Skill` — skill list, skill activate
  - `CodePuppyControl.Messaging.Entries` — FileEntry, GrepMatch, DiffLine, SkillEntry, QuestionOption, Question, QuestionAnswer

  ## Design Notes

  - Internal maps use **string keys** for JSON-safety at the wire boundary.
  - `id` defaults to a UUID generated via `:erlang.unique_integer` + hex,
    avoiding Ecto dependency.
  - `timestamp_unix_ms` defaults to `System.system_time(:millisecond)`.
  - All constructors return `{:ok, map}` or `{:error, reason}` — never raise.
  """

  alias CodePuppyControl.Messaging.Types

  # ── BaseMessage ───────────────────────────────────────────────────────────

  @doc """
  Builds a BaseMessage internal map with auto-generated defaults.

  ## Required Fields

  - `"category"` — must be a valid MessageCategory string

  ## Auto-Generated (if absent)

  - `"id"` — unique message identifier (hex string)
  - `"timestamp_unix_ms"` — Unix timestamp in milliseconds

  ## Optional Fields

  - `"run_id"` — execution run identifier (default: `nil`)
  - `"session_id"` — session grouping (default: `nil`)

  ## Examples

      iex> {:ok, msg} = CodePuppyControl.Messaging.Messages.base_message(%{"category" => "system"})
      iex> is_binary(msg["id"])
      true
      iex> is_integer(msg["timestamp_unix_ms"])
      true
      iex> msg["category"]
      "system"
  """
  @spec base_message(map()) :: {:ok, map()} | {:error, term()}
  def base_message(fields) when is_map(fields) do
    with {:ok, category} <- validate_category(fields),
         {:ok, ts} <- validate_timestamp_unix_ms(fields) do
      msg =
        %{
          "id" => fields["id"] || generate_id(),
          "category" => category,
          "run_id" => Map.get(fields, "run_id"),
          "session_id" => Map.get(fields, "session_id"),
          "timestamp_unix_ms" => ts || System.system_time(:millisecond)
        }

      {:ok, msg}
    end
  end

  def base_message(other), do: {:error, {:not_a_map, other}}

  # ── TextMessage ───────────────────────────────────────────────────────────

  @default_text_message_category "system"

  @doc """
  Builds a TextMessage internal map with auto-generated defaults.

  Extends `base_message/1` with text-specific fields.

  ## Required Fields

  - `"level"` — must be a valid MessageLevel string
  - `"text"` — message content string

  ## Defaults

  - `"category"` — defaults to `"system"`
  - `"is_markdown"` — defaults to `false`
  - `"id"` — auto-generated if absent
  - `"timestamp_unix_ms"` — auto-generated if absent

  ## Optional Fields

  - `"run_id"`, `"session_id"` — default to `nil`

  ## Examples

      iex> {:ok, msg} = CodePuppyControl.Messaging.Messages.text_message(%{"level" => "info", "text" => "Hello!"})
      iex> msg["level"]
      "info"
      iex> msg["text"]
      "Hello!"
      iex> msg["category"]
      "system"
      iex> msg["is_markdown"]
      false
  """
  @spec text_message(map()) :: {:ok, map()} | {:error, term()}
  def text_message(fields) when is_map(fields) do
    with {:ok, _base} <- validate_text_message_fields(fields),
         {:ok, level} <- validate_level(fields),
         {:ok, category} <- validate_category_with_default(fields),
         {:ok, ts} <- validate_timestamp_unix_ms(fields) do
      msg =
        %{
          "id" => fields["id"] || generate_id(),
          "category" => category,
          "level" => level,
          "text" => fields["text"],
          "is_markdown" => Map.get(fields, "is_markdown", false),
          "run_id" => Map.get(fields, "run_id"),
          "session_id" => Map.get(fields, "session_id"),
          "timestamp_unix_ms" => ts || System.system_time(:millisecond)
        }

      {:ok, msg}
    end
  end

  def text_message(other), do: {:error, {:not_a_map, other}}

  # ── Facade delegates ─────────────────────────────────────────────────────

  # Tool output family
  @doc false
  defdelegate file_listing_message(fields),
    to: CodePuppyControl.Messaging.ToolOutput

  @doc false
  defdelegate file_content_message(fields),
    to: CodePuppyControl.Messaging.ToolOutput

  @doc false
  defdelegate grep_result_message(fields),
    to: CodePuppyControl.Messaging.ToolOutput

  @doc false
  defdelegate diff_message(fields),
    to: CodePuppyControl.Messaging.ToolOutput

  @doc false
  defdelegate shell_start_message(fields),
    to: CodePuppyControl.Messaging.ToolOutput

  @doc false
  defdelegate shell_line_message(fields),
    to: CodePuppyControl.Messaging.ToolOutput

  @doc false
  defdelegate shell_output_message(fields),
    to: CodePuppyControl.Messaging.ToolOutput

  @doc false
  defdelegate universal_constructor_message(fields),
    to: CodePuppyControl.Messaging.ToolOutput

  # Agent family
  @doc false
  defdelegate agent_reasoning_message(fields),
    to: CodePuppyControl.Messaging.Agent

  @doc false
  defdelegate agent_response_message(fields),
    to: CodePuppyControl.Messaging.Agent

  @doc false
  defdelegate sub_agent_invocation_message(fields),
    to: CodePuppyControl.Messaging.Agent

  @doc false
  defdelegate sub_agent_response_message(fields),
    to: CodePuppyControl.Messaging.Agent

  @doc false
  defdelegate sub_agent_status_message(fields),
    to: CodePuppyControl.Messaging.Agent

  # User interaction family
  @doc false
  defdelegate user_input_request(fields),
    to: CodePuppyControl.Messaging.UserInteraction

  @doc false
  defdelegate confirmation_request(fields),
    to: CodePuppyControl.Messaging.UserInteraction

  @doc false
  defdelegate selection_request(fields),
    to: CodePuppyControl.Messaging.UserInteraction

  @doc false
  defdelegate ask_user_question_request(fields),
    to: CodePuppyControl.Messaging.UserInteraction

  # Control family
  @doc false
  defdelegate spinner_control(fields),
    to: CodePuppyControl.Messaging.Control

  @doc false
  defdelegate divider_message(fields),
    to: CodePuppyControl.Messaging.Control

  @doc false
  defdelegate status_panel_message(fields),
    to: CodePuppyControl.Messaging.Control

  @doc false
  defdelegate version_check_message(fields),
    to: CodePuppyControl.Messaging.Control

  # Skill family
  @doc false
  defdelegate skill_list_message(fields),
    to: CodePuppyControl.Messaging.Skill

  @doc false
  defdelegate skill_activate_message(fields),
    to: CodePuppyControl.Messaging.Skill

  # Entry models
  @doc false
  defdelegate file_entry(fields),
    to: CodePuppyControl.Messaging.Entries

  @doc false
  defdelegate grep_match(fields),
    to: CodePuppyControl.Messaging.Entries

  @doc false
  defdelegate diff_line(fields),
    to: CodePuppyControl.Messaging.Entries

  @doc false
  defdelegate skill_entry(fields),
    to: CodePuppyControl.Messaging.Entries

  @doc false
  defdelegate question_option_entry(fields),
    to: CodePuppyControl.Messaging.Entries

  @doc false
  defdelegate question_entry(fields),
    to: CodePuppyControl.Messaging.Entries

  @doc false
  defdelegate question_answer_entry(fields),
    to: CodePuppyControl.Messaging.Entries

  # ── Private helpers ────────────────────────────────────────────────────────

  defp generate_id do
    # Generate a UUID-like hex string without requiring Ecto.UUID.
    # Uses erlang's unique_integer for randomness + timestamp for uniqueness.
    ts = System.system_time(:nanosecond)
    uniq = :erlang.unique_integer([:positive])

    :crypto.hash(:sha256, "#{ts}-#{uniq}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp validate_category(fields) do
    case Map.get(fields, "category") do
      nil -> {:error, :missing_category}
      cat -> Types.validate_category(cat)
    end
  end

  defp validate_category_with_default(fields) do
    category = Map.get(fields, "category", @default_text_message_category)
    Types.validate_category(category)
  end

  defp validate_level(fields) do
    case Map.get(fields, "level") do
      nil -> {:error, :missing_level}
      level -> Types.validate_level(level)
    end
  end

  defp validate_timestamp_unix_ms(fields) do
    case Map.get(fields, "timestamp_unix_ms") do
      nil -> {:ok, nil}
      ts when is_integer(ts) -> {:ok, ts}
      other -> {:error, {:invalid_timestamp_unix_ms, other}}
    end
  end

  defp validate_text_message_fields(fields) do
    cond do
      not Map.has_key?(fields, "text") -> {:error, :missing_text}
      not is_binary(fields["text"]) -> {:error, {:invalid_text, fields["text"]}}
      true -> {:ok, :ok}
    end
  end
end
