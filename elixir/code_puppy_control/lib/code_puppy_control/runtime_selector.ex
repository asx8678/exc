defmodule CodePuppyControl.RuntimeSelector do
  @moduledoc """
  Runtime selector + dual-run router. (code_puppy-bwt)

  Determines whether a given capability should be handled by the Elixir
  runtime or delegated to the Python bridge.

  ## Modes

  Controlled by the `PUP_RUNTIME` environment variable:

  | Value        | Mode     | Behaviour                                  |
  |-------------|----------|---------------------------------------------|
  | `python`    | `:python` | Always delegate to Python                   |
  | `elixir`    | `:elixir` | Always handle in Elixir                     |
  | `auto`      | `:auto`   | Route per-capability via `FeatureFlags`     |
  | *(unset)*   | `:auto`   | Same as `auto` — Elixir-native default (Phase J.1) |

  ## Auto-mode routing

  In `:auto` mode, `FeatureFlags.enabled?(capability)` decides:

    - `true`  → `:elixir`
    - `false` → `:python`

  Unknown capabilities in auto mode default to `:elixir`
  (Phase J.1 — Elixir-native path is now the default).

  ## Answering the question

  Since this module *runs inside* Elixir, the primary question it answers
  is: *"Should I handle this capability myself, or delegate to the Python
  bridge?"*

  ## ADR-004 reference

  This implements the Runtime Selector + Dual-Run Router from ADR-004
  Phase H (`code_puppy-bwt`).
  """

  alias CodePuppyControl.FeatureFlags

  @type runtime :: :python | :elixir
  @type mode :: :python | :elixir | :auto
  @type reason :: :env_override | :feature_flag | :default

  @env_var "PUP_RUNTIME"

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Returns the current runtime mode from the `PUP_RUNTIME` env var.

  Values are parsed case-insensitively.  Unset or unrecognised values
  default to `:auto`.
  """
  @spec mode() :: mode()
  def mode do
    case System.get_env(@env_var) do
      nil -> :auto
      value -> parse_mode(value)
    end
  end

  @doc """
  Returns `:elixir` or `:python` for the given capability.

  - `:elixir` mode  → always `:elixir`
  - `:python` mode  → always `:python`
  - `:auto` mode    → checks `FeatureFlags.enabled?(capability)`;
                       `true` → `:elixir`, `false` → `:python`
  """
  @spec select(capability :: String.t()) :: runtime()
  def select(capability) do
    {runtime, _reason} = select_with_reason(capability)
    runtime
  end

  @doc """
  Returns `{runtime, reason}` for the given capability.

  Reason atoms:
    - `:env_override`  — mode was forced by `PUP_RUNTIME` env
    - `:feature_flag`   — auto mode resolved via FeatureFlags
    - `:default`        — auto mode, capability unknown, conservative fallback
  """
  @spec select_with_reason(capability :: String.t()) :: {runtime(), reason()}
  def select_with_reason(capability) do
    case mode() do
      :elixir ->
        {:elixir, :env_override}

      :python ->
        {:python, :env_override}

      :auto ->
        auto_select(capability)
    end
  end

  @doc """
  Convenience: returns `true` if Elixir should handle the given capability.

  Equivalent to `select(capability) == :elixir`.
  """
  @spec elixir_handles?(capability :: String.t()) :: boolean()
  def elixir_handles?(capability) do
    select(capability) == :elixir
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  @spec parse_mode(String.t()) :: mode()
  defp parse_mode(value) do
    case String.downcase(value) do
      "python" -> :python
      "elixir" -> :elixir
      "auto" -> :auto
      _ -> :auto
    end
  end

  @spec auto_select(String.t()) :: {runtime(), reason()}
  defp auto_select(capability) do
    if capability in FeatureFlags.capabilities() do
      if FeatureFlags.enabled?(capability) do
        {:elixir, :feature_flag}
      else
        {:python, :feature_flag}
      end
    else
      # Unknown capability defaults to :elixir in auto mode (Phase J.1)
      {:elixir, :default}
    end
  end
end
