defmodule CodePuppyControl.Plugins.Motd do
  @moduledoc """
  Sample builtin plugin that provides a Message of the Day (MOTD).

  Demonstrates the PluginBehaviour implementation pattern:
  - `name/0` returns a string identifier
  - `register/0` registers callbacks directly with `Callbacks.register/2`
  - `startup/0` and `shutdown/0` for lifecycle hooks

  This plugin registers for the `:get_motd` hook, returning a tuple
  of `{title, body}` that the core system can display at startup.
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @motd_key :code_puppy_control_motd_shown

  @impl true
  def name, do: "motd"

  @impl true
  def description, do: "Displays a Message of the Day at startup"

  @impl true
  def register do
    Callbacks.register(:get_motd, &__MODULE__.get_motd/0)
    Callbacks.register(:startup, &__MODULE__.on_startup/0)
    :ok
  end

  @impl true
  def startup do
    unless :persistent_term.get(@motd_key, false) do
      :persistent_term.put(@motd_key, true)
    end

    :ok
  end

  @impl true
  def shutdown do
    :persistent_term.erase(@motd_key)
    :ok
  end

  # ── Callback Implementations ─────────────────────────────────────

  @doc false
  @spec get_motd() :: [{String.t(), String.t()}]
  def get_motd do
    version = Application.spec(:code_puppy_control, :vsn) |> to_string()

    body = """
    🐶 Code Puppy v#{version} — Elixir Edition
    Loyal digital companion, ready to fetch your code!
    """

    [{"Code Puppy", body}]
  end

  @doc false
  @spec on_startup() :: :ok
  def on_startup do
    # The startup hook is informational; actual MOTD display
    # is handled by whoever calls Callbacks.trigger(:get_motd)
    :ok
  end

  # ── Test Helpers ─────────────────────────────────────────────────

  @doc false
  @spec motd_shown?() :: boolean()
  def motd_shown? do
    :persistent_term.get(@motd_key, false)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@motd_key)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
