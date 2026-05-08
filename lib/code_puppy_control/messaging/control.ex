defmodule CodePuppyControl.Messaging.Control do
  @moduledoc """
  System control message constructors for Agent→UI messaging.

  Provides validated constructors for spinner, divider, status panel,
  and version check message families. Mirrors the Python models in
  `code_puppy/messaging/messages.py`.

  | Python class          | Elixir function          | Default Category |
  |-----------------------|--------------------------|------------------|
  | `SpinnerControl`      | `spinner_control/1`      | `system`         |
  | `DividerMessage`      | `divider_message/1`      | `divider`        |
  | `StatusPanelMessage`  | `status_panel_message/1` | `system`         |
  | `VersionCheckMessage` | `version_check_message/1`| `system`        |

  All constructors return `{:ok, map}` or `{:error, reason}` — never raise.
  Category defaults match Python class; providing a mismatched category is rejected.
  """

  alias CodePuppyControl.Messaging.Validation

  # ── SpinnerControl ─────────────────────────────────────────────────────────

  @spinner_actions ~w(start stop update pause resume)
  @spinner_category "system"

  @doc """
  Builds a SpinnerControl internal map.

  ## Required fields

  - `"action"` — literal `"start"`, `"stop"`, `"update"`, `"pause"`, or `"resume"`
  - `"spinner_id"` — string, unique identifier for this spinner

  ## Optional fields

  - `"text"` — string or nil (default: nil)
  """
  @spec spinner_control(map()) :: {:ok, map()} | {:error, term()}
  def spinner_control(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @spinner_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, action} <- Validation.require_literal(fields, "action", @spinner_actions),
         {:ok, spinner_id} <- Validation.require_string(fields, "spinner_id"),
         {:ok, text} <- Validation.optional_string(fields, "text") do
      {:ok,
       Map.merge(base, %{
         "action" => action,
         "spinner_id" => spinner_id,
         "text" => text
       })}
    end
  end

  def spinner_control(other), do: {:error, {:not_a_map, other}}

  # ── DividerMessage ─────────────────────────────────────────────────────────

  @divider_styles ~w(light heavy double)
  @divider_category "divider"

  @doc """
  Builds a DividerMessage internal map.

  ## Optional fields with defaults

  - `"style"` — literal `"light"`, `"heavy"`, or `"double"` (default: `"light"`)

  The category defaults to `\"divider\"`.
  """
  @spec divider_message(map()) :: {:ok, map()} | {:error, term()}
  def divider_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @divider_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, style} <- validate_style(fields) do
      {:ok, Map.merge(base, %{"style" => style})}
    end
  end

  def divider_message(other), do: {:error, {:not_a_map, other}}

  defp validate_style(fields) do
    case Map.fetch(fields, "style") do
      :error -> {:ok, "light"}
      {:ok, v} when v in @divider_styles -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_literal, "style", other, @divider_styles}}
    end
  end

  # ── StatusPanelMessage ────────────────────────────────────────────────────

  @status_panel_category "system"

  @doc """
  Builds a StatusPanelMessage internal map.

  ## Required fields

  - `"title"` — string

  ## Optional fields with defaults

  - `"fields"` — map of string → string (default: `%{}`)
  """
  @spec status_panel_message(map()) :: {:ok, map()} | {:error, term()}
  def status_panel_message(fields) when is_map(fields) do
    with {:ok, category} <- Validation.validate_category_default(fields, @status_panel_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, title} <- Validation.require_string(fields, "title"),
         {:ok, panel_fields} <- Validation.optional_string_map(fields, "fields") do
      {:ok, Map.merge(base, %{"title" => title, "fields" => panel_fields})}
    end
  end

  def status_panel_message(other), do: {:error, {:not_a_map, other}}

  # ── VersionCheckMessage ───────────────────────────────────────────────────

  @version_check_category "system"

  @doc """
  Builds a VersionCheckMessage internal map.

  ## Required fields

  - `"current_version"` — string
  - `"latest_version"` — string
  - `"update_available"` — boolean
  """
  @spec version_check_message(map()) :: {:ok, map()} | {:error, term()}
  def version_check_message(fields) when is_map(fields) do
    with {:ok, category} <-
           Validation.validate_category_default(fields, @version_check_category),
         {:ok, base} <- Validation.assemble_base(fields, category),
         {:ok, current_version} <- Validation.require_string(fields, "current_version"),
         {:ok, latest_version} <- Validation.require_string(fields, "latest_version"),
         {:ok, update_available} <- Validation.require_boolean(fields, "update_available") do
      {:ok,
       Map.merge(base, %{
         "current_version" => current_version,
         "latest_version" => latest_version,
         "update_available" => update_available
       })}
    end
  end

  def version_check_message(other), do: {:error, {:not_a_map, other}}
end
