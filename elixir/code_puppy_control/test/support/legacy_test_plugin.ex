defmodule CodePuppyControl.Test.LegacyTestPlugin do
  @moduledoc """
  Test plugin using the legacy register_callbacks/0 API.

  Used to verify backward compatibility with plugins that return
  `{hook, fun}` tuples instead of calling `Callbacks.register/2`.
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: :legacy_test_plugin

  @impl true
  def description, do: "Legacy test plugin using register_callbacks/0"

  # register/0 is required by the behaviour — even legacy-style plugins
  # must implement it. This one delegates to the legacy register_callbacks/0
  # pattern (the Loader will prefer register/0 when present).
  @impl true
  def register do
    # Simulate a plugin that still uses the tuple-list approach internally
    # but implements register/0 to satisfy the behaviour
    callbacks = register_callbacks()

    Enum.each(callbacks, fn {hook_name, fun} ->
      Callbacks.register(hook_name, fun)
    end)

    :ok
  end

  @impl true
  def register_callbacks do
    [
      {:load_prompt, &__MODULE__.on_load_prompt/0},
      {:custom_command_help, &__MODULE__.command_help/0}
    ]
  end

  def on_load_prompt do
    "## Legacy Plugin Instructions"
  end

  def command_help do
    [{"legacy", "A legacy test command"}]
  end
end
