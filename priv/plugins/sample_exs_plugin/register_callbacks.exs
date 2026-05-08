defmodule CodePuppyControl.Plugins.SampleExsPlugin do
  @moduledoc """
  Sample builtin plugin in .exs format demonstrating script-based plugins.

  This plugin lives in `priv/plugins/` as a `.exs` file and is discovered
  at runtime by the `CodePuppyControl.Plugins.Loader`. It demonstrates the
  ADR-006 `.exs` fallback path for plugins that prefer script-style
  evaluation over BEAM compilation.

  ## Commands

  - `/paws` — Show a paw-some message
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "sample_exs_plugin"

  @impl true
  def description, do: "Sample .exs format plugin (/paws)"

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
    [{"paws", "Show a paw-some message"}]
  end

  @doc false
  @spec handle_command(String.t(), String.t()) :: String.t() | nil
  def handle_command(_command, name) do
    case name do
      "paws" ->
        "🐾 Paws activated! Ready to dig into code!"

      _ ->
        nil
    end
  end
end
