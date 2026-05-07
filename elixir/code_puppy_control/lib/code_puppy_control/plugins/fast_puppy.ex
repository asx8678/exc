defmodule CodePuppyControl.Plugins.FastPuppy do
  @moduledoc """
  Fast Puppy Plugin — Native acceleration management (REMOVED).

  Native acceleration layer removed. This plugin is now a minimal
  stub that only reports that the acceleration layer has been removed.
  All operations now run on the Elixir-native BEAM/OTP runtime.
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "fast_puppy"

  @impl true
  def description, do: "Native acceleration status (removed)"

  @impl true
  def register do
    Callbacks.register(:custom_command, &__MODULE__.handle_custom_command/2)
    Callbacks.register(:custom_command_help, &__MODULE__.custom_command_help/0)
    :ok
  end

  # ── Callback Implementations ─────────────────────────────────────

  @doc false
  @spec handle_custom_command(String.t(), String.t()) :: String.t() | nil
  def handle_custom_command(_command, name) do
    if name == "fast_puppy" do
      "🐶 Fast Puppy: Native acceleration layer removed. All operations use the Elixir-native runtime."
    else
      nil
    end
  end

  @doc false
  @spec custom_command_help() :: [{String.t(), String.t()}]
  def custom_command_help do
    [{"fast_puppy", "Show status (native acceleration removed)"}]
  end
end
