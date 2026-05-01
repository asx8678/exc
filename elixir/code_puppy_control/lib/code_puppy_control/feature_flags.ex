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
        "elixir.llm_client": 0,
        "elixir.base_agent": 100,
        "elixir.tools": 25,
        "elixir.plugins": false,
        "elixir.cli": false
      }

  Values can be boolean (`true`/`false`) or integer 0..100. `true` is
  equivalent to 100, `false` to 0. Unknown keys are silently ignored.
  Missing keys default to 0 (disabled).

  ## Usage

      # Check if a capability is enabled (probabilistic for percentages 1..99)
      CodePuppyControl.FeatureFlags.enabled?(:llm_client)

      # Get the percentage for a capability
      CodePuppyControl.FeatureFlags.percentage(:llm_client)

      # List all capabilities with their status and percentage
      CodePuppyControl.FeatureFlags.list()

      # Set a capability at runtime (boolean or 0..100)
      CodePuppyControl.FeatureFlags.set(:llm_client, true)
      CodePuppyControl.FeatureFlags.set(:llm_client, 25)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.FeatureFlags.Flags
  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Config.Paths

  @default_source :api
  @valid_sources [:api, :slash_command, :config_file, :test]

  @type set_error :: String.t() | :unknown | {:invalid_value, term()}

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the given capability is enabled.

  Uses probabilistic evaluation when the percentage is between 1 and 99:
  `:rand.uniform(100) <= percentage`. 100 always returns `true`, 0 always
  `false`.

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
  Returns the percentage (0..100) for a given capability.

  Capabilities default to 0 if the flags file is missing, malformed,
  or the key is absent. If the GenServer is unavailable, returns 0.

  Raises `ArgumentError` for unknown capabilities.
  """
  @spec percentage(atom()) :: 0..100
  def percentage(capability) when is_atom(capability) do
    unless Flags.known?(capability) do
      raise ArgumentError, "Unknown feature-flag capability: #{inspect(capability)}"
    end

    GenServer.call(__MODULE__, {:percentage, capability})
  catch
    :exit, _ -> 0
  end

  @doc """
  Returns a list of all capabilities with their current status and percentage.

  Each entry is `{capability_atom, enabled_boolean, percentage_integer, description_string}`.
  Falls back to all-disabled if the GenServer is unavailable.
  """
  @spec list() :: [{atom(), boolean(), 0..100, String.t()}]
  def list do
    GenServer.call(__MODULE__, :list)
  catch
    :exit, _ -> default_list()
  end

  @doc """
  Sets a capability value at runtime.

  Accepts boolean (`true`/`false`) or integer 0..100. Persists the change
  to `flags.json`. Accepts both `:llm_client` atoms and `"elixir.llm_client"`
  strings.

  This legacy arity falls back to source `:api`. Use `set/3` for operator
  or integration code so audit telemetry records the source explicitly.
  Explicitly invalid source opts emit `[:code_puppy, :feature_flags, :invalid]`
  telemetry before falling back; omitted source opts silently use `:api`.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec set(atom() | String.t(), boolean() | 0..100) :: :ok | {:error, set_error()}
  def set(capability, value) when is_boolean(value) do
    set(capability, bool_to_pct(value), [])
  end

  def set(capability, value) when is_integer(value) and value in 0..100 do
    set(capability, value, [])
  end

  @doc """
  Sets a capability value at runtime with source metadata.

  Valid sources include `:api`, `:slash_command`, `:config_file`, and `:test`.
  Invalid source values are observable via `:invalid` telemetry while the write
  still falls back to `:api`.
  """
  @spec set(atom() | String.t(), boolean() | 0..100, keyword()) :: :ok | {:error, set_error()}
  def set(capability, value, opts) when is_boolean(value) and is_list(opts) do
    set(capability, bool_to_pct(value), opts)
  end

  def set(capability, value, opts) when is_integer(value) and value in 0..100 and is_list(opts) do
    source = source_from_opts(opts, @default_source)

    with {:ok, resolved} <- Flags.resolve(capability) do
      GenServer.call(__MODULE__, {:set, resolved, value, source})
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
    pct = Map.get(flags, capability, 0)
    result = pct_enabled?(pct)

    :telemetry.execute(
      [:code_puppy_control, :feature_flags, :check],
      %{duration: 0},
      %{capability: capability, enabled: result, percentage: pct}
    )

    {:reply, result, state}
  end

  @impl true
  def handle_call({:percentage, capability}, _from, %{flags: flags} = state) do
    pct = Map.get(flags, capability, 0)
    {:reply, pct, state}
  end

  @impl true
  def handle_call(:list, _from, %{flags: flags} = state) do
    result =
      Flags.all()
      |> Enum.map(fn {name, desc} ->
        pct = Map.get(flags, name, 0)
        {name, pct_enabled?(pct), pct, desc}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:set, capability, value}, _from, %{flags: flags} = state) do
    set_flag(capability, value, flags, state, @default_source)
  end

  @impl true
  def handle_call({:set, capability, value, source}, _from, %{flags: flags} = state) do
    set_flag(capability, value, flags, state, source)
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

  # Normalize a raw value to integer 0..100.
  defp normalize_value(true), do: 100
  defp normalize_value(false), do: 0
  defp normalize_value(value) when is_integer(value) and value in 0..100, do: value

  # Convert boolean to percentage.
  defp bool_to_pct(true), do: 100
  defp bool_to_pct(false), do: 0

  # Probabilistic check: percentage == 0 → false, 100 → true, else random.
  defp pct_enabled?(0), do: false
  defp pct_enabled?(100), do: true

  defp pct_enabled?(pct) when is_integer(pct) and pct >= 1 and pct <= 99 do
    :rand.uniform(100) <= pct
  end

  defp set_flag(capability, value, flags, state, source) do
    normalized = normalize_value(value)
    new_flags = Map.put(flags, capability, normalized)

    case persist_to_disk(new_flags) do
      :ok ->
        emit_telemetry(:set, %{capability => normalized}, source)
        {:reply, :ok, %{state | flags: new_flags}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp flags_file, do: Paths.flags_file()

  defp default_flags do
    Flags.names()
    |> Enum.map(fn name -> {name, 0} end)
    |> Enum.into(%{})
  end

  defp default_list do
    Flags.all()
    |> Enum.map(fn {name, desc} -> {name, false, 0, desc} end)
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

  # Merge decoded JSON map into defaults. Accepts boolean (converted to
  # 0/100) and integer 0..100 values. Unknown keys and non-boolean/
  # non-valid-integer values are silently ignored (with a warning for
  # invalid values on known keys). `Flags.resolve/1` handles prefix-stripping
  # and atom matching safely — no `String.to_atom/1` or
  # `String.to_existing_atom/1` is used here, preventing atom-table
  # pollution from untrusted JSON input.
  defp parse_flags_map(decoded) when is_map(decoded) do
    defaults = default_flags()

    Enum.reduce(decoded, defaults, fn {key, value}, acc ->
      case Flags.resolve(key) do
        {:ok, atom} when is_boolean(value) ->
          Map.put(acc, atom, if(value, do: 100, else: 0))

        {:ok, atom} when is_integer(value) and value >= 0 and value <= 100 ->
          Map.put(acc, atom, value)

        {:ok, _atom} ->
          Logger.warning(
            "FeatureFlags: expected boolean or 0..100 integer for #{key}, " <>
              "got #{inspect(value)}. Ignoring."
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
  # with "elixir." prefixed string keys. Internal 0..100 integers are
  # normalized back to booleans at the boundaries (0→false, 100→true,
  # 1..99 stays integer) for human-readable JSON.
  defp serialize_flags(flags) do
    flags
    |> Enum.map(fn {capability, value} ->
      {Flags.json_key(capability), serialize_value(value)}
    end)
    |> Enum.into(%{})
  end

  # Serialize internal percentage to JSON wire value.
  # 0 → false, 100 → true, 1..99 → integer.
  defp serialize_value(0), do: false
  defp serialize_value(100), do: true
  defp serialize_value(v) when is_integer(v) and v in 1..99, do: v

  defp source_from_opts(opts, default) do
    case Keyword.fetch(opts, :source) do
      {:ok, source} when source in @valid_sources ->
        source

      {:ok, invalid} ->
        emit_invalid_source(invalid, default)
        default

      :error ->
        default
    end
  end

  defp emit_invalid_source(invalid, fallback) do
    :telemetry.execute(
      [:code_puppy, :feature_flags, :invalid],
      %{count: 1},
      %{reason: {:invalid_source, invalid}, fallback: fallback}
    )
  end

  defp emit_telemetry(action, flags, source \\ nil) do
    metadata =
      case source do
        nil -> %{flags: flags}
        source -> %{flags: flags, source: source}
      end

    :telemetry.execute(
      [:code_puppy_control, :feature_flags, action],
      %{},
      metadata
    )
  end
end
