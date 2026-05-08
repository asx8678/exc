defmodule CodePuppyControl.Plugins.AgentMemory.Config do
  @moduledoc """
  Configuration module for the agent memory plugin.

  Reads memory-related configuration from Application env with defaults:
    - memory_enabled (default: false — OPT-IN)
    - memory_debounce_seconds (default: 30)
    - memory_max_facts (default: 50)
    - memory_token_budget (default: 500)
    - memory_min_confidence (default: 0.5)
    - memory_extraction_enabled (default: true)
  """

  @default_config [
    enabled: false,
    debounce_seconds: 30,
    debounce_ms: 30_000,
    max_facts: 50,
    token_budget: 500,
    min_confidence: 0.5,
    extraction_model: nil,
    extraction_enabled: true,
    max_preference_signals_per_fact: 10,
    preference_signal_decay_hours: 168.0,
    preference_rate_limit_seconds: 60
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          debounce_seconds: pos_integer(),
          debounce_ms: pos_integer(),
          max_facts: pos_integer(),
          token_budget: pos_integer(),
          min_confidence: float(),
          extraction_model: String.t() | nil,
          extraction_enabled: boolean(),
          max_preference_signals_per_fact: pos_integer(),
          preference_signal_decay_hours: float(),
          preference_rate_limit_seconds: pos_integer()
        }

  defstruct @default_config

  @doc "Load the current memory configuration."
  @spec load() :: t()
  def load do
    %__MODULE__{
      enabled: get_bool(:memory_enabled, false),
      debounce_seconds: get_int(:memory_debounce_seconds, 30),
      debounce_ms: get_int(:memory_debounce_seconds, 30) * 1000,
      max_facts: get_int(:memory_max_facts, 50),
      token_budget: get_int(:memory_token_budget, 500),
      min_confidence: get_float(:memory_min_confidence, 0.5),
      extraction_model: get_string(:memory_extraction_model),
      extraction_enabled: get_bool(:memory_extraction_enabled, true),
      max_preference_signals_per_fact: get_int(:memory_max_preference_signals_per_fact, 10),
      preference_signal_decay_hours: get_float(:memory_preference_signal_decay_hours, 168.0),
      preference_rate_limit_seconds: get_int(:memory_preference_rate_limit_seconds, 60)
    }
  end

  @doc "Quick check if agent memory is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: load().enabled

  defp get_bool(key, default) do
    case Application.get_env(:code_puppy_control, key) do
      nil ->
        default

      val when is_boolean(val) ->
        val

      val when is_binary(val) ->
        val = String.downcase(String.trim(val))
        val in ~w(1 true yes on enabled)

      _ ->
        default
    end
  end

  defp get_int(key, default) do
    case Application.get_env(:code_puppy_control, key) do
      nil ->
        default

      val when is_integer(val) and val > 0 ->
        val

      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, _} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp get_float(key, default) do
    case Application.get_env(:code_puppy_control, key) do
      nil ->
        default

      val when is_number(val) and val >= 0 ->
        val / 1

      val when is_binary(val) ->
        case Float.parse(val) do
          {f, _} when f >= 0 -> f
          _ -> default
        end

      _ ->
        default
    end
  end

  defp get_string(key) do
    case Application.get_env(:code_puppy_control, key) do
      nil -> nil
      "" -> nil
      val -> to_string(val)
    end
  end
end
