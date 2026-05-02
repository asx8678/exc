defmodule CodePuppyControl.FeatureFlags do
  @moduledoc """
  Per-capability feature flags for Phase H cutover. (code_puppy-djs.4)

  Reads `~/.code_puppy_ex/flags.json` on init and stores flags in a public
  ETS table for O(1) lock-free reads.  Writes go through the GenServer so
  they stay atomic (in-memory + disk).

  ## Capabilities

  Each flag enables a phase's Elixir capabilities:

  | Flag                  | Phase |
  |-----------------------|-------|
  | `elixir.llm_client`   | LLM client routing |
  | `elixir.base_agent`   | Base agent loop |
  | `elixir.tools`        | Tool dispatch |
  | `elixir.plugins`      | Plugin system |
  | `elixir.cli`          | CLI / REPL |

  Flags are independent; partial enablement is supported for canary testing.

  ## Storage

  - ETS table: `:feature_flags_ets` — `:set, :public, :named_table`
  - On-disk: `~/.code_puppy_ex/flags.json` (Jason-encoded)
  - Missing/corrupt file defaults all flags to `false` with a warning

  ## API

  - `enabled?/1` — O(1) ETS read, no GenServer call
  - `all_flags/0` — complete map of flag states
  - `set_flag/2` — update in-memory + persist to disk
  - `reset_all/0` — reset all flags to false
  - `reload/0` — re-read flags.json from disk
  """

  use GenServer

  require Logger

  @ets_table :feature_flags_ets

  @capabilities ~w(elixir.llm_client elixir.base_agent elixir.tools elixir.plugins elixir.cli)

  @type capability :: String.t()

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the FeatureFlags GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a capability flag is enabled.

  Reads directly from ETS — no GenServer call, O(1) lock-free.
  Returns `false` for unknown capabilities (not in `@capabilities`).
  Returns `false` for disabled or missing flags.
  """
  @spec enabled?(capability()) :: boolean()
  def enabled?(capability) when is_binary(capability) do
    if capability in @capabilities do
      case :ets.lookup(@ets_table, capability) do
        [{^capability, value}] -> value
        [] -> false
      end
    else
      false
    end
  end

  @doc """
  Return a map of all flag states.

  Reads directly from ETS — no GenServer call.
  """
  @spec all_flags() :: %{capability() => boolean()}
  def all_flags do
    @capabilities
    |> Enum.map(fn cap ->
      case :ets.lookup(@ets_table, cap) do
        [{^cap, value}] -> {cap, value}
        [] -> {cap, false}
      end
    end)
    |> Map.new()
  end

  @doc """
  Set a capability flag and persist to disk.

  Updates the ETS entry immediately (public table) and writes the
  updated flags.json via the GenServer for atomic disk persistence.
  Unknown capabilities are ignored.
  """
  @spec set_flag(capability(), boolean()) :: :ok | {:error, term()}
  def set_flag(capability, enabled) when is_binary(capability) and is_boolean(enabled) do
    if capability in @capabilities do
      GenServer.call(__MODULE__, {:set_flag, capability, enabled})
    else
      Logger.warning("FeatureFlags: ignoring unknown capability '#{capability}'")
      {:error, :unknown_capability}
    end
  end

  @doc """
  Reset all flags to `false` and persist to disk.
  """
  @spec reset_all() :: :ok | {:error, term()}
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  end

  @doc """
  Re-read flags.json from disk and refresh ETS.

  Useful for picking up external changes (e.g. manual edits).
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Return the list of valid capability names.
  """
  @spec capabilities() :: [capability()]
  def capabilities, do: @capabilities

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    table =
      :ets.new(@ets_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    load_flags_from_disk()

    Logger.info("FeatureFlags initialized (code_puppy-djs.4)")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:set_flag, capability, enabled}, _from, state) do
    :ets.insert(@ets_table, {capability, enabled})
    result = persist_to_disk()
    {:reply, result, state}
  end

  @impl true
  def handle_call(:reset_all, _from, state) do
    for cap <- @capabilities do
      :ets.insert(@ets_table, {cap, false})
    end

    result = persist_to_disk()
    {:reply, result, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    load_flags_from_disk()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("FeatureFlags received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private — File I/O
  # ============================================================================

  defp flags_file_path do
    CodePuppyControl.Config.Paths.home_dir() <> "/flags.json"
  end

  defp load_flags_from_disk do
    path = flags_file_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            # Apply only known capabilities; unknown keys are ignored
            for cap <- @capabilities do
              value = Map.get(data, cap, false)
              # Coerce to boolean defensively
              :ets.insert(@ets_table, {cap, truthy_to_boolean(value)})
            end

            :ok

          {:ok, _other} ->
            Logger.warning(
              "FeatureFlags: flags.json is not a JSON object — using defaults. " <>
                "Path: #{path}"
            )

            set_defaults()

          {:error, reason} ->
            Logger.warning(
              "FeatureFlags: corrupt flags.json (#{inspect(reason)}) — using defaults. " <>
                "Path: #{path}"
            )

            set_defaults()
        end

      {:error, :enoent} ->
        # File doesn't exist — default all to false (no warning, this is normal)
        set_defaults()

      {:error, reason} ->
        Logger.warning(
          "FeatureFlags: cannot read flags.json (#{inspect(reason)}) — using defaults. " <>
            "Path: #{path}"
        )

        set_defaults()
    end
  end

  defp set_defaults do
    for cap <- @capabilities do
      :ets.insert(@ets_table, {cap, false})
    end

    :ok
  end

  defp persist_to_disk do
    path = flags_file_path()
    flags = all_flags()

    case Jason.encode(flags, pretty: true) do
      {:ok, json} ->
        # Ensure parent directory exists
        dir = Path.dirname(path)

        case File.mkdir_p(dir) do
          :ok ->
            # Write atomically: write to temp, then rename
            tmp_path = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

            case File.write(tmp_path, json) do
              :ok ->
                case File.rename(tmp_path, path) do
                  :ok ->
                    :ok

                  {:error, reason} ->
                    # Clean up temp file on rename failure
                    File.rm(tmp_path)
                    Logger.warning("FeatureFlags: failed to rename flags.json (#{inspect(reason)})")
                    {:error, reason}
                end

              {:error, reason} ->
                Logger.warning("FeatureFlags: failed to write flags.json (#{inspect(reason)})")
                {:error, reason}
            end

          {:error, reason} ->
            Logger.warning(
              "FeatureFlags: failed to create directory for flags.json (#{inspect(reason)})"
            )

            {:error, reason}
        end

      {:error, reason} ->
        # Extremely unlikely with a map of booleans, but be defensive
        Logger.warning("FeatureFlags: failed to encode flags (#{inspect(reason)})")
        {:error, reason}
    end
  end

  # Coerce common truthy representations to boolean.
  # Accepts: true, "true", "1", 1 → true; everything else → false
  defp truthy_to_boolean(true), do: true
  defp truthy_to_boolean("true"), do: true
  defp truthy_to_boolean("1"), do: true
  defp truthy_to_boolean(1), do: true
  defp truthy_to_boolean(_), do: false
end
