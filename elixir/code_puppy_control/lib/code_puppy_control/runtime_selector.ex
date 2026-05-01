defmodule CodePuppyControl.RuntimeSelector do
  @moduledoc """
  Tri-state runtime selector for Python-to-Elixir migration (ADR-004).

  Reads the `PUP_RUNTIME` environment variable on startup to determine
  the routing mode:

    - `:python` — force all capabilities to the Python runtime
    - `:elixir` — force all capabilities to the Elixir runtime
    - `:auto`   — delegate per-capability to `FeatureFlags.enabled?/1`

  In `:auto` mode, each `select_runtime/1` call checks the feature-flag
  file (`~/.code_puppy_ex/flags.json`) via `FeatureFlags`. If the feature
  flag is enabled the capability routes to Elixir; otherwise Python.

  ## Environment Variable

      export PUP_RUNTIME=elixir    # Force all to Elixir
      export PUP_RUNTIME=python    # Force all to Python
      export PUP_RUNTIME=auto      # Per-capability via feature flags (default)
      unset PUP_RUNTIME            # Same as `auto`

  Parsing is case-insensitive. Unknown values default to `:auto`.
  """

  use GenServer

  require Logger

  @valid_modes [:python, :elixir, :auto]

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Starts the RuntimeSelector GenServer.

  ## Options

    * `:name` — registered name (default: `__MODULE__`)

  The mode is read from `PUP_RUNTIME` env var on init.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Selects the runtime for a given capability.

  Returns `:python` or `:elixir` based on the current mode:

    - `:python` → always `:python`
    - `:elixir` → always `:elixir`
    - `:auto`   → `FeatureFlags.enabled?(capability) ? :elixir : :python`

  Emits telemetry on every call:
  `[:code_puppy, :runtime, :select]` with metadata
  `%{capability: cap, selected: runtime, mode: mode}`.

  Falls back to `:python` if the GenServer is unavailable (safe default).
  """
  @spec select_runtime(atom()) :: :python | :elixir
  def select_runtime(capability) when is_atom(capability) do
    GenServer.call(__MODULE__, {:select_runtime, capability})
  catch
    :exit, _ -> :python
  end

  @doc """
  Returns the current routing mode: `:python`, `:elixir`, or `:auto`.
  """
  @spec current_mode() :: :python | :elixir | :auto
  def current_mode do
    GenServer.call(__MODULE__, :current_mode)
  catch
    :exit, _ -> :auto
  end

  @doc """
  Dynamically sets the routing mode at runtime.

  Primarily intended for testing. Valid modes: `:python`, `:elixir`, `:auto`.

  Raises `ArgumentError` for invalid modes.
  """
  @spec set_mode(:python | :elixir | :auto) :: :ok
  def set_mode(mode) when mode in @valid_modes do
    GenServer.call(__MODULE__, {:set_mode, mode})
  catch
    :exit, _ -> {:error, "RuntimeSelector GenServer not running"}
  end

  def set_mode(invalid) do
    raise ArgumentError,
          "Invalid RuntimeSelector mode: #{inspect(invalid)}. " <>
            "Expected one of: #{inspect(@valid_modes)}"
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    mode = parse_env_mode()
    Logger.debug("RuntimeSelector initialized with mode: #{inspect(mode)}")
    emit_telemetry(:init, mode)
    {:ok, %{mode: mode}}
  end

  @impl true
  def handle_call({:select_runtime, capability}, _from, %{mode: mode} = state) do
    selected = resolve_runtime(mode, capability)
    metadata = %{capability: capability, selected: selected, mode: mode}

    :telemetry.execute(
      [:code_puppy, :runtime, :select],
      %{},
      metadata
    )

    {:reply, selected, state}
  end

  @impl true
  def handle_call(:current_mode, _from, %{mode: mode} = state) do
    {:reply, mode, state}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, state) when mode in @valid_modes do
    Logger.debug("RuntimeSelector mode changed: #{inspect(state.mode)} -> #{inspect(mode)}")
    emit_telemetry(:set_mode, mode, %{previous_mode: state.mode})
    {:reply, :ok, %{state | mode: mode}}
  end

  # ── Private ────────────────────────────────────────────────────────────

  # Parse PUP_RUNTIME env var into a mode atom.
  # Case-insensitive. Unknown or missing values default to :auto.
  defp parse_env_mode do
    case System.get_env("PUP_RUNTIME") do
      nil ->
        :auto

      raw when is_binary(raw) ->
        case String.downcase(raw) do
          "python" ->
            :python

          "elixir" ->
            :elixir

          "auto" ->
            :auto

          unknown ->
            Logger.warning(
              "RuntimeSelector: unknown PUP_RUNTIME value #{inspect(unknown)}. Defaulting to :auto."
            )

            :auto
        end
    end
  end

  # Resolve which runtime handles a capability given the current mode.
  # In :auto mode, delegates to FeatureFlags.enabled?/1.
  # Returns :python on any error (safe default — keeps Python path active).
  defp resolve_runtime(:python, _capability), do: :python
  defp resolve_runtime(:elixir, _capability), do: :elixir

  defp resolve_runtime(:auto, capability) do
    # FeatureFlags.enabled?/1 raises ArgumentError for unknown capabilities.
    # We catch that here and fall back to :python (safe default).
    CodePuppyControl.FeatureFlags.enabled?(capability)
  rescue
    e in ArgumentError ->
      Logger.warning(
        "RuntimeSelector: FeatureFlags raised on capability #{inspect(capability)}: " <>
          "#{Exception.message(e)}. Falling back to :python."
      )

      :python
  else
    true -> :elixir
    false -> :python
  end

  defp emit_telemetry(action, mode, extra_metadata \\ %{}) do
    :telemetry.execute(
      [:code_puppy, :runtime, action],
      %{},
      Map.merge(%{mode: mode}, extra_metadata)
    )
  end
end
