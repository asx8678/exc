defmodule CodePuppyControl.CLI.SlashCommands.Commands.ModelSettings do
  @moduledoc """
  Model settings slash command: /model_settings [--show] [model_name].

  Read-only summary (`--show`) and interactive editor for per-model settings
  (temperature, seed, top_p, etc.).

  Ports the Python `show_model_settings_summary()` and
  `interactive_model_settings()` from
  `code_puppy/command_line/model_settings_menu.py`.

  ## Usage

    /model_settings                  — interactive editor for the current global model
    /model_settings gpt-5            — interactive editor for a specific model
    /model_settings --show           — show settings for the current global model
    /model_settings --show gpt-5     — show settings for a specific model
    /ms                              — alias (interactive)
    /ms gpt-5                        — alias (interactive, specific model)
    /ms --show claude-opus-4         — alias with model name
  """

  alias CodePuppyControl.Config.Models

  @usage "Usage: /model_settings [--show] [model_name]  (alias: /ms)"

  # Mirrors Python's SETTING_DEFINITIONS for display purposes.
  # Only the fields needed for rendering are included.
  @setting_definitions %{
    "temperature" => %{
      name: "Temperature",
      type: :numeric,
      format: "{:.2f}"
    },
    "seed" => %{
      name: "Seed",
      type: :numeric,
      format: "{:.0f}"
    },
    "top_p" => %{
      name: "Top-P (Nucleus Sampling)",
      type: :numeric,
      format: "{:.2f}"
    },
    "reasoning_effort" => %{
      name: "Reasoning Effort",
      type: :choice
    },
    "summary" => %{
      name: "Reasoning Summary",
      type: :choice
    },
    "verbosity" => %{
      name: "Verbosity",
      type: :choice
    },
    "extended_thinking" => %{
      name: "Extended Thinking",
      type: :choice
    },
    "budget_tokens" => %{
      name: "Thinking Budget (tokens)",
      type: :numeric,
      format: "{:.0f}"
    },
    "interleaved_thinking" => %{
      name: "Interleaved Thinking",
      type: :boolean
    },
    "clear_thinking" => %{
      name: "Clear Thinking",
      type: :boolean
    },
    "thinking_enabled" => %{
      name: "Thinking Enabled",
      type: :boolean
    },
    "thinking_level" => %{
      name: "Thinking Level",
      type: :choice
    },
    "effort" => %{
      name: "Effort",
      type: :choice
    }
  }

  alias __MODULE__.Interactive

  @doc """
  Handles `/model_settings` and `/ms` commands.

  - `--show [model]` → read-only summary
  - `<model>` or no args → interactive editor
  """
  @spec handle_model_settings(String.t(), any()) :: {:continue, any()}
  def handle_model_settings(line, state) do
    case parse_args(line) do
      {:show, model_name} ->
        show_summary(model_name)

      {:interactive, model_name} ->
        Interactive.run(model_name)

      :invalid ->
        print_usage()
    end

    {:continue, state}
  end

  # ── Public helpers (for testability) ─────────────────────────────────────

  @doc """
  Returns the setting definitions map used for display formatting.
  """
  @spec setting_definitions() :: map()
  def setting_definitions, do: @setting_definitions

  @doc """
  Format a setting value for display, given its definition.

  - `nil` / blank values are displayed as "— (not set)".
  - Numeric values use the `:format` key (e.g. `"{:.2f}"`).
  - Choice values are displayed as-is.
  - Boolean values are shown as "Enabled" / "Disabled".
  """
  @spec format_setting_value(any(), map()) :: String.t()
  def format_setting_value(nil, _definition), do: "— (not set)"

  def format_setting_value("", _definition), do: "— (not set)"

  def format_setting_value(value, %{type: :boolean}) when is_boolean(value) do
    if value, do: "Enabled", else: "Disabled"
  end

  def format_setting_value(value, %{type: :choice}) do
    to_string(value)
  end

  def format_setting_value(value, %{type: :numeric, format: fmt}) do
    case fmt do
      "{:.0f}" ->
        trunc(value * 1.0) |> to_string()

      "{:.2f}" ->
        "~.2f" |> :io_lib.format([value * 1.0]) |> to_string()

      _other ->
        to_string(value)
    end
  end

  def format_setting_value(value, _definition) do
    to_string(value)
  end

  @doc """
  Build the merged display settings for a model.

  Combines per-model settings from config with global OpenAI controls,
  using model capability metadata (`supported_settings`) — mirroring
  Python's `_get_model_display_settings()` and `model_supports_setting()`.

  When the model's `supported_settings` list includes a global control
  (reasoning_effort, summary, verbosity), the global value is shown even
  if no per-model override exists.  This closes the Python parity gap.
  """
  @spec get_display_settings(String.t()) :: map()
  def get_display_settings(model_name) when is_binary(model_name) do
    settings = Models.get_all_model_settings(model_name)

    # Merge global OpenAI controls based on model capabilities,
    # not just presence of per-model overrides.
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

  @doc """
  Format the settings summary as a string (pure function, no IO).

  Useful for testing without depending on or mutating shared config.
  """
  @spec format_summary(String.t(), map()) :: String.t()
  def format_summary(model_name, settings) when is_binary(model_name) and is_map(settings) do
    if map_size(settings) == 0 do
      "    No custom settings configured for #{model_name} (using model defaults)"
    else
      lines =
        ["    Settings for #{model_name}:"]
        |> Kernel.++(
          settings
          |> Enum.sort_by(fn {k, _v} -> k end)
          |> Enum.map(fn {key, value} ->
            defn = Map.get(@setting_definitions, key, %{type: :unknown})
            display_name = Map.get(defn, :name, key)
            display_value = format_setting_value(value, defn)
            "    #{String.pad_trailing(display_name, 30)} #{display_value}"
          end)
        )

      Enum.join(lines, "\n")
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  # Check whether a model supports a given setting.
  # Mirrors Python's model_supports_setting().
  # Uses ModelRegistry `supported_settings` metadata when available,
  # falling back to presence in per-model config for backwards compat.
  defp model_supports_setting?(model_name, setting) do
    case CodePuppyControl.ModelRegistry.get_config(model_name) do
      %{"supported_settings" => supported} when is_list(supported) ->
        setting in supported

      _no_metadata ->
        # Read-only summary: do NOT invent OpenAI global controls
        # (reasoning_effort, summary, verbosity) for models that lack
        # explicit supported_settings metadata.  Only show these controls
        # when the model's metadata explicitly lists them.
        #
        # This differs from the Python runtime path (model_factory) where
        # defaulting to True is "safe" for API calls.  In the display path,
        # showing unsupported controls is misleading.
        false
    end
  end

  defp show_summary(nil) do
    model = Models.global_model_name()
    show_summary(model)
  end

  defp show_summary(model_name) when is_binary(model_name) do
    settings = get_display_settings(model_name)

    IO.puts("")
    IO.puts(format_summary(model_name, settings))
    IO.puts("")
  end

  defp print_usage do
    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        "    #{@usage}" <> IO.ANSI.reset()
    )

    IO.puts("")
  end

  # Parses "/model_settings [--show] [model_name]" or "/ms [--show] [model_name]"
  # Returns:
  #   {:show, "model_name"}    — show settings for a specific model
  #   {:show, nil}              — show settings for the current model
  #   {:interactive, "model"}   — interactive editor for a specific model
  #   {:interactive, nil}       — interactive editor for the current model
  #   :invalid                   — unrecognized arguments
  @spec parse_args(String.t()) ::
          {:show, String.t() | nil} | {:interactive, String.t() | nil} | :invalid
  defp parse_args("/" <> rest) do
    case String.split(rest, ~r/\s+/, trim: true) do
      [_cmd] ->
        # Just "/model_settings" or "/ms" — interactive mode for current model
        {:interactive, nil}

      [_cmd, "--show"] ->
        {:show, nil}

      [_cmd, "--show", model_name] ->
        {:show, model_name}

      [_cmd, model_name] ->
        # "/model_settings gpt-5" — interactive mode for a specific model
        {:interactive, model_name}

      [_cmd, model_name, "--show"] ->
        # Allow model name before --show too
        {:show, model_name}

      _ ->
        :invalid
    end
  end

  defp parse_args(_), do: :invalid
end
