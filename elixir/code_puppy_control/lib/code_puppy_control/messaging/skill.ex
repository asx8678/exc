defmodule CodePuppyControl.Messaging.Skill do
  @moduledoc """
  Skill message constructors for Agent→UI messaging.

  Provides validated constructors for skill listing and activation
  message families. Mirrors the Python models in
  `code_puppy/messaging/messages.py`.

  | Python class           | Elixir function          |
  |------------------------|--------------------------|
  | `SkillListMessage`     | `skill_list_message/1`   |
  | `SkillActivateMessage` | `skill_activate_message/1`|

  All constructors return `{:ok, map}` or `{:error, reason}` — never raise.
  Category defaults to `\"tool_output\"`; providing a mismatched category is rejected.
  """

  alias CodePuppyControl.Messaging.{Entries, Validation}

  @default_category "tool_output"

  # ── SkillListMessage ───────────────────────────────────────────────────────

  @doc """
  Builds a SkillListMessage internal map.

  ## Required fields

  - `"total_count"` — integer ≥ 0

  ## Optional fields

  - `"skills"` — list of SkillEntry maps (default: `[]`)
  - `"query"` — string or nil (default: nil)
  """
  @spec skill_list_message(map()) :: {:ok, map()} | {:error, term()}
  def skill_list_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, skills} <- Validation.validate_list(fields, "skills", &Entries.skill_entry/1),
         {:ok, query} <- Validation.optional_string(fields, "query"),
         {:ok, total_count} <- Validation.require_integer(fields, "total_count", min: 0) do
      {:ok,
       Map.merge(base, %{
         "skills" => skills,
         "query" => query,
         "total_count" => total_count
       })}
    end
  end

  def skill_list_message(other), do: {:error, {:not_a_map, other}}

  # ── SkillActivateMessage ──────────────────────────────────────────────────

  @doc """
  Builds a SkillActivateMessage internal map.

  ## Required fields

  - `"skill_name"` — string
  - `"skill_path"` — string
  - `"content_preview"` — string
  - `"resource_count"` — integer ≥ 0

  ## Optional fields with defaults

  - `"success"` — boolean (default: `true`)
  """
  @spec skill_activate_message(map()) :: {:ok, map()} | {:error, term()}
  def skill_activate_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @default_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, skill_name} <- Validation.require_string(fields, "skill_name"),
         {:ok, skill_path} <- Validation.require_string(fields, "skill_path"),
         {:ok, content_preview} <- Validation.require_string(fields, "content_preview"),
         {:ok, resource_count} <- Validation.require_integer(fields, "resource_count", min: 0),
         {:ok, success} <- Validation.optional_boolean(fields, "success", true) do
      {:ok,
       Map.merge(base, %{
         "skill_name" => skill_name,
         "skill_path" => skill_path,
         "content_preview" => content_preview,
         "resource_count" => resource_count,
         "success" => success
       })}
    end
  end

  def skill_activate_message(other), do: {:error, {:not_a_map, other}}
end
