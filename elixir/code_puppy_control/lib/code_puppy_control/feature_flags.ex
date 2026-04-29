defmodule CodePuppyControl.FeatureFlags do
  @moduledoc """
  ADR-004 Phase H feature-flag system for gradual Elixir rollout.

  Reads `~/.code_puppy_ex/flags.json` on startup and exposes a runtime
  `enabled?/1` API for each capability. All capabilities default to
  `false` (disabled — Python path) when the file is missing or malformed.

  ## Capabilities

  See `CodePuppyControl.FeatureFlags.Flags` for the full list.

  ## File Format

      {
        "elixir.llm_client": false,
        "elixir.base_agent": false,
        "elixir.tools": false,
        "elixir.plugins": false,
        "elixir.cli": false
      }

  Unknown keys in the file are silently ignored. Missing keys default
  to `false`.

  ## Usage

      # Check if a capability is enabled
      CodePuppyControl.FeatureFlags.enabled?(:llm_client)

      # List all capabilities with their status
      CodePuppyControl.FeatureFlags.list()

      # Set a capability at runtime (writes to disk)
      CodePuppyControl.FeatureFlags.set(:llm_client, true)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.FeatureFlags.Flags
  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Config.Paths

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the given capability is enabled.

  Capabilities default to `false` if the flags file is missing, malformed,
  or the key is absent. If the GenServer is unavailable, returns `false`
  (safe default — keeps Python code path active).

  Raises `ArgumentError` for unknown capabilities.
  """
  @spec enabled?(atom()) :: boolean()
  def enabled?(capability) when is_atom(capability) do
    unless Flags.known?(capability) do
      raise ArgumentError, "Unknown feature-flag capability: #{inspect(capability)}"
    end

    GenServer.call(__MODULE__, {:enabled?, capability})
  catch
    :exit, _ -> false
  end

  @doc """
  Returns a list of all capabilities with their current status.

  Each entry is `{capability_atom, status_boolean, description_string}`.
  Falls back to all-disabled if the GenServer is unavailable.
  """
  @spec list() :: [{atom(), boolean(), String.t()}]
  def list do
    GenServer.call(__MODULE__, :list)
  catch
    :exit, _ -> default_list()
  end

  @doc """
  Enables or disables a capability at runtime.

  Persists the change to `flags.json`. Accepts both `:llm_client` atoms
  and `"elixir.llm_client"` strings.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec set(atom() | String.t(), boolean()) :: :ok | {:error, String.t()}
  def set(capability, value) when is_boolean(value) do
    with {:ok, resolved} <- Flags.resolve(capability) do
      GenServer.call(__MODULE__, {:set, resolved, value})
    end
  catch
    :exit, _ -> {:error, "FeatureFlags GenServer not running"}
  end

  @doc """
  Resets all capabilities to their defaults (all `false`).
  Persists the reset to `flags.json`.
  """
  @spec reset() :: :ok | {:error, String.t()}
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _ -> {:error, "FeatureFlags GenServer not running"}
  end

  @doc """
  Reloads flags from disk, returning the new state.
  """
  @spec reload() :: :ok | {:error, String.t()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  catch
    :exit, _ -> {:error, "FeatureFlags GenServer not running"}
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    flags = load_from_disk()
    emit_telemetry(:init, flags)
    {:ok, %{flags: flags}}
  end

  @impl true
  def handle_call({:enabled?, capability}, _from, %{flags: flags} = state) do
    result = Map.get(flags, capability, false)

    :telemetry.execute(
      [:code_puppy_control, :feature_flags, :check],
      %{duration: 0},
      %{capability: capability, enabled: result}
    )

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list, _from, %{flags: flags} = state) do
    result =
      Flags.all()
      |> Enum.map(fn {name, desc} -> {name, Map.get(flags, name, false), desc} end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:set, capability, value}, _from, %{flags: flags} = state) do
    new_flags = Map.put(flags, capability, value)

    case persist_to_disk(new_flags) do
      :ok ->
        emit_telemetry(:set, %{capability => value})
        {:reply, :ok, %{state | flags: new_flags}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    fresh = default_flags()

    case persist_to_disk(fresh) do
      :ok ->
        emit_telemetry(:reset, fresh)
        {:reply, :ok, %{flags: fresh}}

      {:error, reason} ->
        # Do NOT mutate in-memory state on persistence failure (matches set behavior)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, _state) do
    flags = load_from_disk()
    emit_telemetry(:reload, flags)
    {:reply, :ok, %{flags: flags}}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp flags_file, do: Paths.flags_file()

  defp default_flags do
    Flags.names()
    |> Enum.map(fn name -> {name, false} end)
    |> Enum.into(%{})
  end

  defp default_list do
    Flags.all()
    |> Enum.map(fn {name, desc} -> {name, false, desc} end)
  end

  defp load_from_disk do
    path = flags_file()

    with true <- File.exists?(path),
         {:ok, raw} <- File.read(path),
         {:ok, decoded} <- decode_json(raw) do
      parse_flags_map(decoded)
    else
      _ -> default_flags()
    end
  end

  defp decode_json(raw) when byte_size(raw) < 2, do: {:error, :empty}
  defp decode_json(raw), do: Jason.decode(raw)

  # Merge decoded JSON map into defaults. Unknown keys and non-boolean
  # values are silently ignored (with a warning for non-boolean values
  # on known keys). `Flags.resolve/1` handles prefix-stripping and
  # atom matching safely — no `String.to_atom/1` or
  # `String.to_existing_atom/1` is used here, preventing atom-table
  # pollution from untrusted JSON input.
  defp parse_flags_map(decoded) when is_map(decoded) do
    defaults = default_flags()

    Enum.reduce(decoded, defaults, fn {key, value}, acc ->
      case Flags.resolve(key) do
        {:ok, atom} when is_boolean(value) ->
          Map.put(acc, atom, value)

        {:ok, _atom} ->
          # Non-boolean value — skip with warning
          Logger.warning(
            "FeatureFlags: expected boolean for #{key}, got #{inspect(value)}. Ignoring."
          )

          acc

        {:error, :unknown} ->
          # Unknown key — silently ignore per ADR-004 spec
          acc
      end
    end)
  end

  defp parse_flags_map(_not_a_map) do
    Logger.warning("FeatureFlags: flags.json is not a JSON object. Using defaults.")

    default_flags()
  end

  defp persist_to_disk(flags) do
    path = flags_file()
    dir = Path.dirname(path)

    with {:ok, :ok} <- safe_check(dir, :mkdir),
         :ok <- File.mkdir_p(dir),
         {:ok, :ok} <- safe_check(path, :write),
         {:ok, encoded} <- Jason.encode(serialize_flags(flags), pretty: true),
         :ok <- File.write(path, encoded <> "\n") do
      :ok
    else
      {:error, %Isolation.IsolationViolation{} = violation} ->
        {:error, "Isolation violation: #{violation.message}"}

      {:error, reason} ->
        {:error, "Failed to persist flags: #{inspect(reason)}"}
    end
  end

  # Route persistence through the Isolation guard (ADR-003 §6.3).
  # Returns {:ok, :ok} when the path is allowed, or
  # {:error, %IsolationViolation{}} when blocked.
  defp safe_check(path, action) do
    case Isolation.check_allowed(path, action) do
      :ok -> {:ok, :ok}
      {:error, %Isolation.IsolationViolation{} = violation} -> {:error, violation}
    end
  end

  # Converts internal atom-keyed map to the JSON wire format
  # with "elixir." prefixed string keys.
  defp serialize_flags(flags) do
    flags
    |> Enum.map(fn {capability, value} -> {Flags.json_key(capability), value} end)
    |> Enum.into(%{})
  end

  defp emit_telemetry(action, flags) do
    :telemetry.execute(
      [:code_puppy_control, :feature_flags, action],
      %{},
      %{flags: flags}
    )
  end
end
