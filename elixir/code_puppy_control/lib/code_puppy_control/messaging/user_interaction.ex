defmodule CodePuppyControl.Messaging.UserInteraction do
  @moduledoc """
  User interaction message constructors for Agent→UI messaging.

  Provides validated constructors for all message families in the
  `user_interaction` category. Mirrors the Python models in
  `code_puppy/messaging/messages.py`.

  | Python class             | Elixir function           |
  |--------------------------|---------------------------|
  | `UserInputRequest`       | `user_input_request/1`   |
  | `ConfirmationRequest`    | `confirmation_request/1` |
  | `SelectionRequest`       | `selection_request/1`     |
  | `AskUserQuestionRequest` | `ask_user_question_request/1` |

  All constructors return `{:ok, map}` or `{:error, reason}` — never raise.
  Category defaults to `\"user_interaction\"`; providing a mismatched category is rejected.
  """

  alias CodePuppyControl.Messaging.{Entries, Validation}

  @default_category "user_interaction"

  @input_types ~w(text password)

  # ── UserInputRequest ───────────────────────────────────────────────────────

  @doc """
  Builds a UserInputRequest internal map.

  ## Required fields

  - `"prompt_id"` — string, unique ID for matching responses
  - `"prompt_text"` — string, the prompt to display

  ## Optional fields

  - `"default_value"` — string or nil (default: nil)
  - `"input_type"` — literal `"text"` or `"password"` (default: `"text"`)
  """
  @spec user_input_request(map()) :: {:ok, map()} | {:error, term()}
  def user_input_request(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, prompt_id} <- Validation.require_string(fields, "prompt_id"),
         {:ok, prompt_text} <- Validation.require_string(fields, "prompt_text"),
         {:ok, default_value} <- Validation.optional_string(fields, "default_value"),
         {:ok, input_type} <- validate_input_type(fields) do
      {:ok,
       Map.merge(base, %{
         "prompt_id" => prompt_id,
         "prompt_text" => prompt_text,
         "default_value" => default_value,
         "input_type" => input_type
       })}
    end
  end

  def user_input_request(other), do: {:error, {:not_a_map, other}}

  defp validate_input_type(fields) do
    case Map.fetch(fields, "input_type") do
      :error -> {:ok, "text"}
      {:ok, v} when v in @input_types -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_literal, "input_type", other, @input_types}}
    end
  end

  # ── ConfirmationRequest ────────────────────────────────────────────────────

  @doc """
  Builds a ConfirmationRequest internal map.

  ## Required fields

  - `"prompt_id"` — string
  - `"title"` — string
  - `"description"` — string

  ## Optional fields with defaults

  - `"options"` — list of strings (default: `[\"Yes\", \"No\"]`)
  - `"allow_feedback"` — boolean (default: `false`)
  """
  @spec confirmation_request(map()) :: {:ok, map()} | {:error, term()}
  def confirmation_request(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, prompt_id} <- Validation.require_string(fields, "prompt_id"),
         {:ok, title} <- Validation.require_string(fields, "title"),
         {:ok, description} <- Validation.require_string(fields, "description"),
         {:ok, options} <- validate_options(fields),
         {:ok, allow_feedback} <- Validation.optional_boolean(fields, "allow_feedback", false) do
      {:ok,
       Map.merge(base, %{
         "prompt_id" => prompt_id,
         "title" => title,
         "description" => description,
         "options" => options,
         "allow_feedback" => allow_feedback
       })}
    end
  end

  def confirmation_request(other), do: {:error, {:not_a_map, other}}

  defp validate_options(fields) do
    case Map.fetch(fields, "options") do
      :error ->
        {:ok, ["Yes", "No"]}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, {:invalid_field_type, "options", :not_all_strings}}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, "options", other}}
    end
  end

  # ── SelectionRequest ───────────────────────────────────────────────────────

  @doc """
  Builds a SelectionRequest internal map.

  ## Required fields

  - `"prompt_id"` — string
  - `"prompt_text"` — string
  - `"options"` — list of strings (must be present)

  ## Optional fields with defaults

  - `"allow_cancel"` — boolean (default: `true`)
  """
  @spec selection_request(map()) :: {:ok, map()} | {:error, term()}
  def selection_request(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, prompt_id} <- Validation.require_string(fields, "prompt_id"),
         {:ok, prompt_text} <- Validation.require_string(fields, "prompt_text"),
         {:ok, options} <- validate_required_string_list(fields, "options"),
         {:ok, allow_cancel} <- Validation.optional_boolean(fields, "allow_cancel", true) do
      {:ok,
       Map.merge(base, %{
         "prompt_id" => prompt_id,
         "prompt_text" => prompt_text,
         "options" => options,
         "allow_cancel" => allow_cancel
       })}
    end
  end

  def selection_request(other), do: {:error, {:not_a_map, other}}

  defp validate_required_string_list(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, {:invalid_field_type, key, :not_all_strings}}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}

      :error ->
        {:error, {:missing_required_field, key}}
    end
  end

  # ── AskUserQuestionRequest ────────────────────────────────────────────────

  @doc """
  Builds an AskUserQuestionRequest internal map.

  Mirrors the Python `AskUserQuestionInput` model from
  `code_puppy/tools/ask_user_question/models.py`. Carries a batch
  of structured questions with selectable options, supporting
  both single- and multi-select.

  ## Required fields

  - `"prompt_id"` — string, unique ID for matching responses
  - `"questions"` — list of QuestionEntry maps (1-10 questions)

  ## Optional fields with defaults

  - `"timeout"` — integer, inactivity timeout in seconds (default: `300`)
  """
  @spec ask_user_question_request(map()) :: {:ok, map()} | {:error, term()}
  def ask_user_question_request(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, prompt_id} <- Validation.require_string(fields, "prompt_id"),
         {:ok, questions} <- validate_questions(fields),
         {:ok, timeout} <- validate_timeout_seconds(fields) do
      {:ok,
       Map.merge(base, %{
         "prompt_id" => prompt_id,
         "questions" => questions,
         "timeout" => timeout
       })}
    end
  end

  def ask_user_question_request(other), do: {:error, {:not_a_map, other}}

  defp validate_questions(fields) do
    case Map.fetch(fields, "questions") do
      {:ok, list} when is_list(list) ->
        with {:ok, validated} <-
               Validation.validate_list(fields, "questions", &Entries.question_entry/1) do
          count = length(validated)

          cond do
            count < 1 -> {:error, {:value_below_min, "questions", count, 1}}
            count > 10 -> {:error, {:value_above_max, "questions", count, 10}}
            true -> {:ok, validated}
          end
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, "questions", other}}

      :error ->
        {:error, {:missing_required_field, "questions"}}
    end
  end

  defp validate_timeout_seconds(fields) do
    case Map.fetch(fields, "timeout") do
      :error -> {:ok, 300}
      {:ok, v} when is_integer(v) and v > 0 -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, "timeout", other}}
    end
  end
end
