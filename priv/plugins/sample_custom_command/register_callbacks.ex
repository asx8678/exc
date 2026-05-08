defmodule CodePuppyControl.Plugins.SampleCustomCommand do
  @moduledoc """
  Sample builtin plugin demonstrating custom slash commands.

  This plugin lives in `priv/plugins/` and is discovered at runtime
  by the `CodePuppyControl.Plugins.Loader`. It registers handlers
  for the `:custom_command` and `:custom_command_help` hooks.

  ## Commands

  - `/woof` — Emit a playful woof message
  - `/echo <text>` — Echo back text (display only)
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "sample_custom_command"

  @impl true
  def description, do: "Sample custom slash commands (/woof, /echo)"

  @impl true
  def register do
    Callbacks.register(:custom_command_help, &__MODULE__.command_help/0)
    Callbacks.register(:custom_command, &__MODULE__.handle_command/2)
    :ok
  end

  # ── Callback Implementations ─────────────────────────────────────

  @doc false
  @spec command_help() :: [{String.t(), String.t()}]
  def command_help do
    [
      {"woof", "Emit a playful woof message"},
      {"echo", "Echo back your text (display only)"}
    ]
  end

  @doc false
  @spec handle_command(String.t(), String.t()) :: String.t() | nil
  def handle_command(_command, name) do
    case name do
      "woof" ->
        "🐶 Woof! Ready to fetch code!"

      "echo" ->
        # Return empty — in a real plugin this would parse the command text
        "echo!"

      _ ->
        nil
    end
  end
end
