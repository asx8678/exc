defmodule CodePuppyControl.Test.TestPlugin do
  @moduledoc """
  Test plugin for verifying plugin loading and callback registration.

  This module implements `PluginBehaviour` and is used in tests to verify:
  - Plugin discovery and loading
  - Callback registration via `register/0` (preferred) and `register_callbacks/0` (legacy)
  - Startup/shutdown lifecycle hooks
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: :test_plugin

  @impl true
  def description, do: "A test plugin for verifying plugin loading"

  @impl true
  def register do
    Callbacks.register(:startup, &__MODULE__.on_startup/0)
    Callbacks.register(:shutdown, &__MODULE__.on_shutdown/0)
    Callbacks.register(:load_prompt, &__MODULE__.on_load_prompt/0)
    :ok
  end

  @impl true
  def startup do
    # Update agent directly so lifecycle tests work
    # even without triggering the :startup hook via Callbacks
    try do
      Agent.update(__MODULE__, fn state -> Map.put(state, :startup_called, true) end)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @impl true
  def shutdown do
    try do
      Agent.update(__MODULE__, fn state -> Map.put(state, :shutdown_called, true) end)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # Callback hook implementations (registered via register/0)

  def on_startup do
    Agent.update(__MODULE__, fn state -> Map.put(state, :startup_called, true) end)
    :ok
  end

  def on_shutdown do
    Agent.update(__MODULE__, fn state -> Map.put(state, :shutdown_called, true) end)
    :ok
  end

  def on_load_prompt do
    "## Test Plugin Instructions"
  end

  # ── Test Helpers ────────────────────────────────────────────────

  @doc false
  def start_agent do
    case Agent.start_link(fn -> %{} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc false
  def get_state do
    try do
      Agent.get(__MODULE__, & &1)
    catch
      :exit, _ -> %{}
    end
  end

  @doc false
  def reset_state do
    try do
      Agent.update(__MODULE__, fn _ -> %{} end)
    catch
      :exit, _ -> :ok
    end
  end

  @doc false
  def stop_agent do
    try do
      Agent.stop(__MODULE__)
    catch
      :exit, _ -> :ok
    end
  end
end
