defmodule CodePuppyControl.Config.Presets do
  @moduledoc """
  Named configuration presets for Code Puppy.

  Mirrors the Python `config_presets.py` module. Each preset is a map of
  config keys to string values that can be applied atomically via
  `CodePuppyControl.Config.Writer.set_values/1`.

  ## Built-in presets

  - **basic** — minimal automation, conservative safety
  - **semi** — balanced automation with safety checks
  - **full** — maximum automation, YOLO mode enabled
  - **pack** — pack agents for complex multi-agent workflows
  """

  alias CodePuppyControl.Config.{Debug, Limits, Writer}

  @type preset :: %{
          name: String.t(),
          display_name: String.t(),
          description: String.t(),
          values: %{String.t() => String.t()}
        }

  # ── Preset definitions ────────────────────────────────────────────────

  @basic %{
    name: "basic",
    display_name: "Basic",
    description: "Minimal automation, conservative safety",
    values: %{
      "yolo_mode" => "false",
      "enable_pack_agents" => "false",
      "enable_universal_constructor" => "false",
      "safety_permission_level" => "medium",
      "compaction_strategy" => "summarization",
      "enable_streaming" => "true"
    }
  }

  @semi %{
    name: "semi",
    display_name: "Semi",
    description: "Balanced automation with safety checks",
    values: %{
      "yolo_mode" => "false",
      "enable_pack_agents" => "false",
      "enable_universal_constructor" => "true",
      "safety_permission_level" => "medium",
      "compaction_strategy" => "summarization",
      "enable_streaming" => "true"
    }
  }

  @full %{
    name: "full",
    display_name: "Full",
    description: "Maximum automation, YOLO mode",
    values: %{
      "yolo_mode" => "true",
      "enable_pack_agents" => "true",
      "enable_universal_constructor" => "true",
      "safety_permission_level" => "low",
      "compaction_strategy" => "summarization",
      "enable_streaming" => "true"
    }
  }

  @pack %{
    name: "pack",
    display_name: "Pack",
    description: "Pack agents for complex workflows",
    values: %{
      "yolo_mode" => "false",
      "enable_pack_agents" => "true",
      "enable_universal_constructor" => "true",
      "safety_permission_level" => "medium",
      "compaction_strategy" => "summarization",
      "enable_streaming" => "true"
    }
  }

  @builtin_presets %{
    "basic" => @basic,
    "semi" => @semi,
    "full" => @full,
    "pack" => @pack
  }

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Returns all built-in presets as a list.
  """
  @spec list_presets() :: [preset()]
  def list_presets do
    Map.values(@builtin_presets)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Returns a single preset by name, or `nil` if not found.
  """
  @spec get_preset(String.t()) :: preset() | nil
  def get_preset(name) when is_binary(name) do
    Map.get(@builtin_presets, String.downcase(name))
  end

  @doc """
  Applies a preset by name, writing all values atomically via `Writer.set_values/1`.

  Returns `:ok` on success, or `{:error, :not_found}` if the preset name is unknown.
  """
  @spec apply_preset(String.t()) :: :ok | {:error, :not_found}
  def apply_preset(name) when is_binary(name) do
    case get_preset(name) do
      nil ->
        {:error, :not_found}

      preset ->
        Writer.set_values(preset.values)
        :ok
    end
  end

  @doc """
  Attempts to guess which preset matches the current configuration.

  Returns the preset name (e.g. `"basic"`) if there's an exact match,
  or `nil` if the current config doesn't match any built-in preset.
  """
  @spec current_preset_guess() :: String.t() | nil
  def current_preset_guess do
    current = current_snapshot()

    Enum.find_value(@builtin_presets, fn {name, preset} ->
      if all_match?(current, preset.values), do: name
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec current_snapshot() :: %{String.t() => String.t()}
  defp current_snapshot do
    %{
      "yolo_mode" => bool_to_string(Debug.yolo_mode?()),
      "enable_pack_agents" => bool_to_string(Debug.pack_agents_enabled?()),
      "enable_universal_constructor" => bool_to_string(Debug.universal_constructor_enabled?()),
      "safety_permission_level" => Debug.safety_permission_level(),
      "compaction_strategy" => Limits.compaction_strategy(),
      "enable_streaming" => bool_to_string(Debug.streaming_enabled?())
    }
  end

  @spec all_match?(%{String.t() => String.t()}, %{String.t() => String.t()}) :: boolean()
  defp all_match?(current, preset_values) do
    Enum.all?(preset_values, fn {key, value} ->
      String.downcase(Map.get(current, key, "")) == String.downcase(value)
    end)
  end

  defp bool_to_string(true), do: "true"
  defp bool_to_string(false), do: "false"
end
