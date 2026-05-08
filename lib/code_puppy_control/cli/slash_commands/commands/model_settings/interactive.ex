defmodule CodePuppyControl.CLI.SlashCommands.Commands.ModelSettings.Interactive do
  @moduledoc """
  Interactive text-based editor for per-model settings.

  Implements the `CodePuppyControl.TUI.Screen` behaviour for a simple
  numbered-menu interface.  The user sees current settings, types a
  number + value to change one, and the change is persisted immediately
  via `CodePuppyControl.Config.Models`.

  ## Usage

      Interactive.run("gpt-5")          # start for a specific model
      Interactive.run(nil)              # start for current global model

  ## Input format

      1 0.7        — set option #1 (temperature) to 0.7
      r 1          — reset option #1 to default
      q            — quit the editor

  ## Editable fields

  1. temperature
  2. seed
  3. top_p
  4. reasoning_effort
  5. summary
  6. verbosity
  """

  @behaviour CodePuppyControl.TUI.Screen

  alias CodePuppyControl.Config.Models

  # The six editable fields exposed in the interactive menu,
  # matching the Python interactive_model_settings() set.
  @editable_fields [
    %{
      key: "temperature",
      name: "Temperature",
      type: :numeric,
      min: 0.0,
      max: 2.0,
      step: 0.05,
      default: nil,
      format: "{:.2f}"
    },
    %{
      key: "seed",
      name: "Seed",
      type: :numeric,
      min: 0,
      max: 999_999,
      step: 1,
      default: nil,
      format: "{:.0f}"
    },
    %{
      key: "top_p",
      name: "Top-P (Nucleus Sampling)",
      type: :numeric,
      min: 0.0,
      max: 1.0,
      step: 0.05,
      default: nil,
      format: "{:.2f}"
    },
    %{
      key: "reasoning_effort",
      name: "Reasoning Effort",
      type: :choice,
      choices: ["minimal", "low", "medium", "high", "xhigh"],
      default: "medium"
    },
    %{
      key: "summary",
      name: "Reasoning Summary",
      type: :choice,
      choices: ["auto", "concise", "detailed"],
      default: "auto"
    },
    %{
      key: "verbosity",
      name: "Verbosity",
      type: :choice,
      choices: ["low", "medium", "high"],
      default: "medium"
    }
  ]

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Run the interactive editor for the given model name.

  If `nil`, uses the current global model.
  Returns `:ok` when the user quits.
  """
  @spec run(String.t() | nil) :: :ok
  def run(model_name \\ nil) do
    resolved = model_name || Models.global_model_name()
    CodePuppyControl.TUI.Screen.run(__MODULE__, %{model_name: resolved})
  end

  @doc """
  Returns the editable field definitions (for testing).
  """
  @spec editable_fields() :: [map()]
  def editable_fields, do: @editable_fields

  # ── TUI.Screen callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    model_name = Map.fetch!(opts, :model_name)
    settings = load_settings(model_name)

    {:ok,
     %{
       model_name: model_name,
       settings: settings,
       message: nil
     }}
  end

  @impl true
  def render(state) do
    header = [
      "",
      "  ⚙  Model Settings Editor — #{state.model_name}",
      "  #{String.duplicate("─", 50)}",
      ""
    ]

    setting_lines =
      Enum.with_index(@editable_fields, 1)
      |> Enum.map(fn {field, idx} ->
        current = Map.get(state.settings, field.key)
        val_str = format_value(current, field)
        "    #{idx}. #{String.pad_trailing(field.name, 30)} #{val_str}"
      end)

    footer = [
      "",
      "  #{String.duplicate("─", 50)}",
      "  Enter: <number> <value>  (e.g. \"1 0.7\")  |  r <number> to reset  |  q to quit",
      ""
    ]

    # Show transient message (confirmation / error) if present
    msg_lines =
      if state.message do
        [state.message, ""]
      else
        []
      end

    Enum.join(header ++ setting_lines ++ footer ++ msg_lines, "\n")
  end

  @impl true
  def handle_input(input, state) do
    cond do
      input =~ ~r/^q$/i ->
        :quit

      input =~ ~r/^r\s+(\d+)$/ ->
        # Reset a setting to default
        [_full, idx_str] = Regex.run(~r/^r\s+(\d+)$/, input)
        idx = String.to_integer(idx_str)
        handle_reset(idx, state)

      input =~ ~r/^(\d+)\s+(.+)$/ ->
        # Set a setting: "<number> <value>"
        [_full, idx_str, value_str] = Regex.run(~r/^(\d+)\s+(.+)$/, input)
        idx = String.to_integer(idx_str)
        handle_set(idx, String.trim(value_str), state)

      true ->
        {:ok, %{state | message: "  ⚠ Invalid input. Use: <number> <value>, r <number>, or q"}}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp load_settings(model_name) do
    # Merge per-model settings with global OpenAI controls,
    # same logic as ModelSettings.get_display_settings/1.
    settings = Models.get_all_model_settings(model_name)

    settings =
      if model_supports_setting?(model_name, "reasoning_effort") do
        Map.put(settings, "reasoning_effort", Models.openai_reasoning_effort())
      else
        settings
      end

    settings =
      if model_supports_setting?(model_name, "summary") do
        Map.put(settings, "summary", Models.openai_reasoning_summary())
      else
        settings
      end

    settings =
      if model_supports_setting?(model_name, "verbosity") do
        Map.put(settings, "verbosity", Models.openai_verbosity())
      else
        settings
      end

    settings
  end

  defp model_supports_setting?(model_name, setting) do
    case CodePuppyControl.ModelRegistry.get_config(model_name) do
      %{"supported_settings" => supported} when is_list(supported) ->
        setting in supported

      _no_metadata ->
        false
    end
  end

  defp handle_reset(idx, state) when idx >= 1 and idx <= length(@editable_fields) do
    field = Enum.at(@editable_fields, idx - 1)

    case reset_setting(state.model_name, field) do
      :ok ->
        _discarded = Map.put(state.settings, field.key, nil)
        # Reload to reflect persisted state
        reloaded = load_settings(state.model_name)
        {:ok, %{state | settings: reloaded, message: "  ✓ Reset #{field.name} to default"}}

      {:error, reason} ->
        {:ok, %{state | message: "  ✗ #{reason}"}}
    end
  end

  defp handle_reset(_idx, state) do
    {:ok, %{state | message: "  ⚠ Invalid option number. Use 1–#{length(@editable_fields)}"}}
  end

  defp handle_set(idx, value_str, state) when idx >= 1 and idx <= length(@editable_fields) do
    field = Enum.at(@editable_fields, idx - 1)

    case parse_and_validate(value_str, field) do
      {:ok, value} ->
        case save_setting(state.model_name, field.key, value) do
          :ok ->
            # Reload settings from config to reflect persisted state
            reloaded = load_settings(state.model_name)
            display = format_value(value, field)

            {:ok,
             %{
               state
               | settings: reloaded,
                 message: "  ✓ Set #{field.name} → #{display}"
             }}

          {:error, reason} ->
            {:ok, %{state | message: "  ✗ #{reason}"}}
        end

      {:error, reason} ->
        {:ok, %{state | message: "  ✗ #{reason}"}}
    end
  end

  defp handle_set(_idx, _value_str, state) do
    {:ok, %{state | message: "  ⚠ Invalid option number. Use 1–#{length(@editable_fields)}"}}
  end

  # ── Parsing & validation ───────────────────────────────────────────────

  defp parse_and_validate(value_str, %{type: :numeric} = field) do
    case Float.parse(value_str) do
      {val, ""} ->
        val = val * 1.0

        if val >= field.min and val <= field.max do
          {:ok, val}
        else
          {:error, "Value #{val} out of range for #{field.name} (#{field.min}–#{field.max})"}
        end

      {val, _rest} when is_float(val) ->
        # Allow trailing text for integer-valued floats like "42"
        val = val * 1.0

        if val >= field.min and val <= field.max do
          {:ok, val}
        else
          {:error, "Value #{val} out of range for #{field.name} (#{field.min}–#{field.max})"}
        end

      :error ->
        # Try integer parse as fallback
        case Integer.parse(value_str) do
          {val, ""} ->
            fval = val * 1.0

            if fval >= field.min and fval <= field.max do
              {:ok, fval}
            else
              {:error, "Value #{val} out of range for #{field.name} (#{field.min}–#{field.max})"}
            end

          _ ->
            {:error, "Invalid number: #{value_str}"}
        end
    end
  end

  defp parse_and_validate(value_str, %{type: :choice} = field) do
    normalized = String.downcase(String.trim(value_str))

    if normalized in field.choices do
      {:ok, normalized}
    else
      {:error,
       "Invalid choice '#{value_str}' for #{field.name}. Options: #{Enum.join(field.choices, ", ")}"}
    end
  end

  # ── Persistence ────────────────────────────────────────────────────────

  defp save_setting(_model_name, "reasoning_effort", value) do
    case Models.set_openai_reasoning_effort(value) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp save_setting(_model_name, "summary", value) do
    case Models.set_openai_reasoning_summary(value) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp save_setting(_model_name, "verbosity", value) do
    case Models.set_openai_verbosity(value) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp save_setting(model_name, setting_key, value) do
    Models.set_model_setting(model_name, setting_key, value)
  end

  defp reset_setting(_model_name, %{key: "reasoning_effort"}) do
    Models.set_openai_reasoning_effort("medium")
  end

  defp reset_setting(_model_name, %{key: "summary"}) do
    Models.set_openai_reasoning_summary("auto")
  end

  defp reset_setting(_model_name, %{key: "verbosity"}) do
    Models.set_openai_verbosity("medium")
  end

  defp reset_setting(model_name, field) do
    Models.set_model_setting(model_name, field.key, nil)
  end

  # ── Display ────────────────────────────────────────────────────────────

  defp format_value(nil, field) do
    case field.default do
      nil -> "— (not set)"
      d -> "— (default: #{d})"
    end
  end

  defp format_value("", field), do: format_value(nil, field)

  defp format_value(value, %{type: :numeric, format: "{:.2f}"}) when is_number(value) do
    "~.2f" |> :io_lib.format([value * 1.0]) |> to_string()
  end

  defp format_value(value, %{type: :numeric, format: "{:.0f}"}) when is_number(value) do
    trunc(value * 1.0) |> to_string()
  end

  defp format_value(value, %{type: :numeric}) when is_number(value) do
    to_string(value)
  end

  defp format_value(value, %{type: :choice}) do
    to_string(value)
  end

  defp format_value(value, _field) do
    to_string(value)
  end
end
