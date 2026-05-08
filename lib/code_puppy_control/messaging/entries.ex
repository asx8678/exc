defmodule CodePuppyControl.Messaging.Entries do
  @moduledoc """
  Nested entry model constructors for Agent→UI messages.

  Provides validated constructors for the structured entry types that appear
  inside list fields of message families. Each constructor enforces
  Pydantic-style `extra='forbid'` semantics, rejecting unknown keys.

  Mirrors the Python entry models in `code_puppy/messaging/messages.py`:

  | Python class       | Elixir function              |
  |--------------------|------------------------------|
  | `FileEntry`        | `file_entry/1`               |
  | `GrepMatch`        | `grep_match/1`               |
  | `DiffLine`         | `diff_line/1`                |
  | `SkillEntry`       | `skill_entry/1`              |
  | `QuestionOption`   | `question_option_entry/1`    |
  | `Question`         | `question_entry/1`           |
  | `QuestionAnswer`   | `question_answer_entry/1`    |

  All constructors return `{:ok, map}` or `{:error, reason}` — never raise.
  """

  alias CodePuppyControl.Messaging.Validation

  # ── FileEntry ──────────────────────────────────────────────────────────────

  @file_entry_allowed_keys MapSet.new(~w(path type size depth))

  @doc """
  Builds a validated FileEntry map.

  ## Required fields

  - `"path"` — string, file or directory path
  - `"type"` — literal `"file"` or `"dir"`
  - `"size"` — integer ≥ -1 (0 for dirs, -1 for unknown)
  - `"depth"` — integer ≥ 0 (nesting depth from listing root)

  ## Extra keys

  Rejected with `{:error, {:extra_fields_not_allowed, keys}}`.
  """
  @spec file_entry(map()) :: {:ok, map()} | {:error, term()}
  def file_entry(fields) when is_map(fields) do
    with :ok <- Validation.reject_extra_keys(fields, @file_entry_allowed_keys),
         {:ok, path} <- Validation.require_string(fields, "path"),
         {:ok, type} <- Validation.require_literal(fields, "type", ~w(file dir)),
         {:ok, size} <- Validation.require_integer(fields, "size", min: -1),
         {:ok, depth} <- Validation.require_integer(fields, "depth", min: 0) do
      {:ok, %{"path" => path, "type" => type, "size" => size, "depth" => depth}}
    end
  end

  def file_entry(other), do: {:error, {:not_a_map, other}}

  # ── GrepMatch ─────────────────────────────────────────────────────────────

  @grep_match_allowed_keys MapSet.new(~w(file_path line_number line_content))

  @doc """
  Builds a validated GrepMatch map.

  ## Required fields

  - `"file_path"` — string, path to matched file
  - `"line_number"` — integer ≥ 1 (1-based)
  - `"line_content"` — string, full line content with match

  ## Extra keys

  Rejected with `{:error, {:extra_fields_not_allowed, keys}}`.
  """
  @spec grep_match(map()) :: {:ok, map()} | {:error, term()}
  def grep_match(fields) when is_map(fields) do
    with :ok <- Validation.reject_extra_keys(fields, @grep_match_allowed_keys),
         {:ok, file_path} <- Validation.require_string(fields, "file_path"),
         {:ok, line_number} <- Validation.require_integer(fields, "line_number", min: 1),
         {:ok, line_content} <- Validation.require_string(fields, "line_content") do
      {:ok,
       %{
         "file_path" => file_path,
         "line_number" => line_number,
         "line_content" => line_content
       }}
    end
  end

  def grep_match(other), do: {:error, {:not_a_map, other}}

  # ── DiffLine ───────────────────────────────────────────────────────────────

  @diff_line_allowed_keys MapSet.new(~w(line_number type content))
  @diff_line_types ~w(add remove context)

  @doc """
  Builds a validated DiffLine map.

  ## Required fields

  - `"line_number"` — integer ≥ 0
  - `"type"` — literal `"add"`, `"remove"`, or `"context"`
  - `"content"` — string, the line content

  ## Extra keys

  Rejected with `{:error, {:extra_fields_not_allowed, keys}}`.
  """
  @spec diff_line(map()) :: {:ok, map()} | {:error, term()}
  def diff_line(fields) when is_map(fields) do
    with :ok <- Validation.reject_extra_keys(fields, @diff_line_allowed_keys),
         {:ok, line_number} <- Validation.require_integer(fields, "line_number", min: 0),
         {:ok, type} <- Validation.require_literal(fields, "type", @diff_line_types),
         {:ok, content} <- Validation.require_string(fields, "content") do
      {:ok, %{"line_number" => line_number, "type" => type, "content" => content}}
    end
  end

  def diff_line(other), do: {:error, {:not_a_map, other}}

  # ── SkillEntry ────────────────────────────────────────────────────────────

  @skill_entry_allowed_keys MapSet.new(~w(name description path tags enabled))

  @doc """
  Builds a validated SkillEntry map.

  ## Required fields

  - `"name"` — string, skill name
  - `"description"` — string, skill description
  - `"path"` — string, path to skill directory

  ## Optional fields with defaults

  - `"tags"` — list of strings (default: `[]`)
  - `"enabled"` — boolean (default: `true`)

  ## Extra keys

  Rejected with `{:error, {:extra_fields_not_allowed, keys}}`.
  """
  @spec skill_entry(map()) :: {:ok, map()} | {:error, term()}
  def skill_entry(fields) when is_map(fields) do
    with :ok <- Validation.reject_extra_keys(fields, @skill_entry_allowed_keys),
         {:ok, name} <- Validation.require_string(fields, "name"),
         {:ok, description} <- Validation.require_string(fields, "description"),
         {:ok, path} <- Validation.require_string(fields, "path"),
         {:ok, tags} <- validate_tags(fields),
         {:ok, enabled} <- Validation.optional_boolean(fields, "enabled", true) do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "path" => path,
         "tags" => tags,
         "enabled" => enabled
       }}
    end
  end

  def skill_entry(other), do: {:error, {:not_a_map, other}}

  # ── QuestionOptionEntry ───────────────────────────────────────────────

  @question_option_allowed_keys MapSet.new(~w(label description))

  @doc """
  Builds a validated QuestionOptionEntry map.

  Mirrors Python `QuestionOption` model from
  `code_puppy/tools/ask_user_question/models.py`.

  ## Required fields

  - `"label"` — string, short option name (1-5 words recommended)

  ## Optional fields with defaults

  - `"description"` — string, explanation of the option (default: `""`)

  ## Extra keys

  Rejected with `{:error, {:extra_fields_not_allowed, keys}}`.
  """
  @spec question_option_entry(map()) :: {:ok, map()} | {:error, term()}
  def question_option_entry(fields) when is_map(fields) do
    with :ok <- Validation.reject_extra_keys(fields, @question_option_allowed_keys),
         {:ok, label} <- Validation.require_string(fields, "label"),
         {:ok, description} <- validate_description(fields) do
      {:ok, %{"label" => label, "description" => description}}
    end
  end

  def question_option_entry(other), do: {:error, {:not_a_map, other}}

  defp validate_description(fields) do
    case Map.fetch(fields, "description") do
      :error -> {:ok, ""}
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, "description", other}}
    end
  end

  # ── QuestionEntry ─────────────────────────────────────────────────────

  @question_entry_allowed_keys MapSet.new(~w(question header multi_select options))

  @doc """
  Builds a validated QuestionEntry map.

  Mirrors Python `Question` model from
  `code_puppy/tools/ask_user_question/models.py`.

  ## Required fields

  - `"question"` — string, the full question text
  - `"header"` — string, short label for compact display
  - `"options"` — list of QuestionOptionEntry maps (2-6 options)

  ## Optional fields with defaults

  - `"multi_select"` — boolean (default: `false`)

  ## Extra keys

  Rejected with `{:error, {:extra_fields_not_allowed, keys}}`.
  """
  @spec question_entry(map()) :: {:ok, map()} | {:error, term()}
  def question_entry(fields) when is_map(fields) do
    with :ok <- Validation.reject_extra_keys(fields, @question_entry_allowed_keys),
         {:ok, question} <- Validation.require_string(fields, "question"),
         {:ok, header} <- Validation.require_string(fields, "header"),
         {:ok, multi_select} <- Validation.optional_boolean(fields, "multi_select", false),
         {:ok, options} <- validate_question_options(fields) do
      {:ok,
       %{
         "question" => question,
         "header" => header,
         "multi_select" => multi_select,
         "options" => options
       }}
    end
  end

  def question_entry(other), do: {:error, {:not_a_map, other}}

  defp validate_question_options(fields) do
    case Map.fetch(fields, "options") do
      {:ok, list} when is_list(list) ->
        with {:ok, validated} <-
               Validation.validate_list(fields, "options", &question_option_entry/1) do
          count = length(validated)

          cond do
            count < 2 -> {:error, {:value_below_min, "options", count, 2}}
            count > 6 -> {:error, {:value_above_max, "options", count, 6}}
            true -> {:ok, validated}
          end
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, "options", other}}

      :error ->
        {:error, {:missing_required_field, "options"}}
    end
  end

  # ── QuestionAnswerEntry ──────────────────────────────────────────────

  @question_answer_allowed_keys MapSet.new(~w(question_header selected_options other_text))

  @doc """
  Builds a validated QuestionAnswerEntry map.

  Mirrors Python `QuestionAnswer` model from
  `code_puppy/tools/ask_user_question/models.py`.

  ## Required fields

  - `"question_header"` — string, the header of the answered question
  - `"selected_options"` — list of strings, labels of selected options

  ## Optional fields with defaults

  - `"other_text"` — string or nil, custom text if "Other" selected

  ## Extra keys

  Rejected with `{:error, {:extra_fields_not_allowed, keys}}`.
  """
  @spec question_answer_entry(map()) :: {:ok, map()} | {:error, term()}
  def question_answer_entry(fields) when is_map(fields) do
    with :ok <- Validation.reject_extra_keys(fields, @question_answer_allowed_keys),
         {:ok, question_header} <- Validation.require_string(fields, "question_header"),
         {:ok, selected_options} <- validate_selected_options(fields),
         {:ok, other_text} <- Validation.optional_string(fields, "other_text") do
      {:ok,
       %{
         "question_header" => question_header,
         "selected_options" => selected_options,
         "other_text" => other_text
       }}
    end
  end

  def question_answer_entry(other), do: {:error, {:not_a_map, other}}

  defp validate_selected_options(fields) do
    case Map.fetch(fields, "selected_options") do
      :error ->
        {:ok, []}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, {:invalid_field_type, "selected_options", :not_all_strings}}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, "selected_options", other}}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp validate_tags(fields) do
    case Map.fetch(fields, "tags") do
      :error ->
        {:ok, []}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, {:invalid_field_type, "tags", :not_all_strings}}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, "tags", other}}
    end
  end
end
