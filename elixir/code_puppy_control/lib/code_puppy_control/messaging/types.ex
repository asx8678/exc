defmodule CodePuppyControl.Messaging.Types do
  @moduledoc """
  Structured message type definitions for Agent→UI messaging.

  Defines allowed MessageLevel and MessageCategory values with validation.
  These mirror the Python enums in `code_puppy/messaging/messages.py`.

  ## MessageLevel

  Severity for text messages:

  | Level    | Use                                    |
  |----------|----------------------------------------|
  | debug    | Verbose diagnostic output              |
  | info     | General informational messages         |
  | warning  | Non-fatal issues requiring attention   |
  | error    | Failure conditions                     |
  | success  | Positive outcome confirmations         |

  ## MessageCategory

  Category for routing and rendering decisions:

  | Category          | Use                                      |
  |-------------------|------------------------------------------|
  | system            | Framework/infrastructure messages        |
  | tool_output       | Results from tool invocations            |
  | agent             | Agent reasoning, responses, status      |
  | user_interaction  | Prompts/requests directed at the user    |
  | divider           | Visual section separators               |
  """

  # ── MessageLevel ──────────────────────────────────────────────────────────

  @allowed_levels ~w(debug info warning error success)

  @doc """
  Returns the list of allowed MessageLevel string values.
  """
  @spec allowed_levels() :: [String.t()]
  def allowed_levels, do: @allowed_levels

  @doc """
  Validates a MessageLevel string.

  Returns `{:ok, level}` if valid, `{:error, {:invalid_level, value}}` otherwise.

  ## Examples

      iex> CodePuppyControl.Messaging.Types.validate_level("info")
      {:ok, "info"}

      iex> CodePuppyControl.Messaging.Types.validate_level("critical")
      {:error, {:invalid_level, "critical"}}
  """
  @spec validate_level(String.t()) :: {:ok, String.t()} | {:error, {:invalid_level, term()}}
  def validate_level(level) when level in @allowed_levels, do: {:ok, level}

  def validate_level(level), do: {:error, {:invalid_level, level}}

  # ── MessageCategory ────────────────────────────────────────────────────────

  @allowed_categories ~w(system tool_output agent user_interaction divider)

  @doc """
  Returns the list of allowed MessageCategory string values.
  """
  @spec allowed_categories() :: [String.t()]
  def allowed_categories, do: @allowed_categories

  @doc """
  Validates a MessageCategory string.

  Returns `{:ok, category}` if valid, `{:error, {:invalid_category, value}}` otherwise.

  ## Examples

      iex> CodePuppyControl.Messaging.Types.validate_category("system")
      {:ok, "system"}

      iex> CodePuppyControl.Messaging.Types.validate_category("network")
      {:error, {:invalid_category, "network"}}
  """
  @spec validate_category(String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_category, term()}}
  def validate_category(category) when category in @allowed_categories, do: {:ok, category}

  def validate_category(category), do: {:error, {:invalid_category, category}}
end
