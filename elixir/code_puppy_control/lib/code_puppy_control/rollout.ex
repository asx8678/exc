defmodule CodePuppyControl.Rollout do
  @moduledoc """
  Gradual rollout controller — percentage-based capability enablement with
  observability and automatic rollback detection. (code_puppy-djs.6)

  Instead of a simple boolean flag (FeatureFlags already does that), this
  module adds per-capability percentage rollout (0% → 5% → 25% → 50% → 100%),
  success/error tracking per capability per runtime, and advisory rollback
  recommendations when error rates exceed a configurable threshold.

  ## Storage

  - `:rollout_ets` — config table (set, public, named_table): `%{capability =>
    %{percentage: 0..100, error_threshold: float}}`
  - `:rollout_counters_ets` — counters table (set, public, named_table):
    `%{capability => %{elixir_ok: int, elixir_err: int, python_ok: int,
    python_err: int}}`

  Counter updates use `:ets.update_counter/3` for lock-free atomic increments.

  ## Rollout Config Is Runtime-Only

  Unlike FeatureFlags (which persists to `flags.json`), rollout configuration
  is **ephemeral** — not written to disk. It's set via slash commands or the
  public API and lost on restart. This is intentional: it keeps rollout state
  safe and prevents stale config from surviving a restart.

  ## Integration with RuntimeSelector

  `should_use_elixir?/1` integrates with `RuntimeSelector`: when mode is
  `:auto` AND a rollout percentage is configured (> 0), it uses
  percentage-based routing instead of the pure boolean flag. When no rollout
  is configured, it falls back to `FeatureFlags.enabled?/1`.

  Percentage routing uses `rem(:erlang.phash2(:erlang.monotonic_time(), 100), 100)`
  which gives roughly uniform distribution over time without needing
  per-request state.

  ## Rollback Detection

  `check_rollback/1` is advisory — it returns a recommendation but does NOT
  auto-disable anything. The caller (or a periodic check) decides whether to
  act on it. Default error threshold is 10% (0.10).
  """

  use GenServer

  require Logger

  @config_ets :rollout_ets
  @counters_ets :rollout_counters_ets
  @default_error_threshold 0.10

  @type capability :: String.t()
  @type runtime :: :elixir | :python
  @type outcome :: :ok | :error

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the Rollout GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Determine whether Elixir should handle the given capability.

  In auto mode with a rollout percentage configured, uses percentage-based
  routing: `rem(:erlang.phash2(:erlang.monotonic_time(), 100), 100) < percentage`.
  When no rollout config exists (percentage 0 or not configured), falls back
  to `FeatureFlags.enabled?/1`.

  For non-auto modes (forced via `PUP_RUNTIME`), delegates to RuntimeSelector.
  """
  @spec should_use_elixir?(capability()) :: boolean()
  def should_use_elixir?(capability) when is_binary(capability) do
    mode = CodePuppyControl.RuntimeSelector.mode()

    case mode do
      :elixir -> true
      :python -> false
      :auto -> auto_should_use_elixir?(capability)
    end
  end

  @doc """
  Record a success or error outcome for a capability + runtime.

  Uses `:ets.update_counter/3` for lock-free atomic increments.
  """
  @spec record_outcome(capability(), runtime(), outcome()) :: :ok
  def record_outcome(capability, runtime, outcome)
      when is_binary(capability) and runtime in [:elixir, :python] and outcome in [:ok, :error] do
    counter_key = counter_key(runtime, outcome)

    # Ensure the counter row exists before atomic update
    ensure_counter_row(capability)

    :ets.update_counter(
      @counters_ets,
      {capability, counter_key},
      1,
      {{capability, counter_key}, 0}
    )

    :ok
  end

  @doc """
  Set the rollout percentage for a capability.

  Clamps to 0..100. Returns `:ok` on success, `{:error, _}` on invalid input.
  """
  @spec set_percentage(capability(), 0..100) :: :ok | {:error, term()}
  def set_percentage(capability, percentage)
      when is_binary(capability) and is_integer(percentage) do
    clamped = max(0, min(100, percentage))
    GenServer.call(__MODULE__, {:set_percentage, capability, clamped})
  end

  def set_percentage(_capability, _percentage) do
    {:error, :invalid_input}
  end

  @doc """
  Get the current rollout percentage for a capability.

  Returns 0 if no rollout config exists for the capability.
  """
  @spec get_percentage(capability()) :: non_neg_integer()
  def get_percentage(capability) when is_binary(capability) do
    case :ets.lookup(@config_ets, capability) do
      [{^capability, %{percentage: pct}}] -> pct
      [] -> 0
    end
  end

  @doc """
  Return comprehensive rollout status: percentages, counters, and error rates.

  Returns a map with:
  - `:capabilities` — map of capability => %{percentage, error_threshold, counters, error_rate}
  """
  @spec status() :: map()
  def status do
    # Collect all configured capabilities
    configs =
      :ets.tab2list(@config_ets)
      |> Enum.map(fn {cap, cfg} -> {cap, cfg} end)
      |> Map.new()

    # Collect all counter entries
    counters =
      :ets.tab2list(@counters_ets)
      |> Enum.group_by(
        fn {{cap, _key}, _val} -> cap end,
        fn {{_cap, key}, val} -> {key, val} end
      )
      |> Map.new(fn {cap, pairs} -> {cap, Map.new(pairs)} end)

    # Merge into per-capability status
    all_caps = MapSet.union(MapSet.new(Map.keys(configs)), MapSet.new(Map.keys(counters)))

    capabilities =
      all_caps
      |> Enum.map(fn cap ->
        cfg = Map.get(configs, cap, %{percentage: 0, error_threshold: @default_error_threshold})
        cnt = Map.get(counters, cap, %{})

        elixir_ok = Map.get(cnt, :elixir_ok, 0)
        elixir_err = Map.get(cnt, :elixir_err, 0)
        python_ok = Map.get(cnt, :python_ok, 0)
        python_err = Map.get(cnt, :python_err, 0)

        total_elixir = elixir_ok + elixir_err
        elixir_error_rate = if total_elixir > 0, do: elixir_err / total_elixir, else: 0.0

        {cap,
         %{
           percentage: cfg.percentage,
           error_threshold: cfg.error_threshold,
           counters: %{
             elixir_ok: elixir_ok,
             elixir_err: elixir_err,
             python_ok: python_ok,
             python_err: python_err
           },
           elixir_error_rate: elixir_error_rate
         }}
      end)
      |> Map.new()

    %{capabilities: capabilities}
  end

  @doc """
  Check whether a capability should be rolled back due to high error rates.

  Returns `:ok` when the error rate is within bounds, or
  `{:rollback, reason}` when it exceeds the configured threshold.

  Does NOT auto-rollback — returns a recommendation for the caller to act on.
  Avoids division by zero when total requests is 0.
  """
  @spec check_rollback(capability()) :: :ok | {:rollback, String.t()}
  def check_rollback(capability) when is_binary(capability) do
    elixir_err = get_counter(capability, :elixir_err)
    elixir_ok = get_counter(capability, :elixir_ok)
    total = elixir_ok + elixir_err

    if total == 0 do
      :ok
    else
      error_rate = elixir_err / total
      threshold = get_error_threshold(capability)

      if error_rate > threshold do
        {:rollback,
         "Elixir error rate for '#{capability}' is #{Float.round(error_rate * 100, 1)}%, " <>
           "exceeding threshold of #{Float.round(threshold * 100, 1)}% " <>
           "(#{elixir_err} errors / #{total} total Elixir requests)"}
      else
        :ok
      end
    end
  end

  @doc """
  Reset all counters to zero.

  Useful for starting a fresh observation window during a new rollout phase.
  """
  @spec reset_counters() :: :ok
  def reset_counters do
    GenServer.call(__MODULE__, :reset_counters)
  end

  @doc """
  Set the error rate threshold for rollback detection on a capability.

  Default is 0.10 (10%). Values are clamped to [0.0, 1.0].
  """
  @spec set_error_threshold(capability(), float()) :: :ok
  def set_error_threshold(capability, threshold)
      when is_binary(capability) and is_float(threshold) do
    clamped = max(0.0, min(1.0, threshold))
    GenServer.call(__MODULE__, {:set_error_threshold, capability, clamped})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Config ETS: capability => %{percentage: int, error_threshold: float}
    :ets.new(@config_ets, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Counters ETS: {capability, key} => int (for update_counter)
    :ets.new(@counters_ets, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    Logger.info("Rollout initialized (code_puppy-djs.6)")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set_percentage, capability, percentage}, _from, state) do
    existing =
      case :ets.lookup(@config_ets, capability) do
        [{^capability, cfg}] -> cfg
        [] -> %{percentage: 0, error_threshold: @default_error_threshold}
      end

    updated = Map.put(existing, :percentage, percentage)
    :ets.insert(@config_ets, {capability, updated})

    Logger.info("Rollout: '#{capability}' set to #{percentage}% (code_puppy-djs.6)")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_error_threshold, capability, threshold}, _from, state) do
    existing =
      case :ets.lookup(@config_ets, capability) do
        [{^capability, cfg}] -> cfg
        [] -> %{percentage: 0, error_threshold: @default_error_threshold}
      end

    updated = Map.put(existing, :error_threshold, threshold)
    :ets.insert(@config_ets, {capability, updated})

    Logger.info(
      "Rollout: '#{capability}' error threshold set to #{Float.round(threshold * 100, 1)}% (code_puppy-djs.6)"
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset_counters, _from, state) do
    :ets.delete_all_objects(@counters_ets)
    Logger.info("Rollout: counters reset (code_puppy-djs.6)")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Rollout received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Auto-mode routing: percentage-based if rollout is configured, otherwise
  # fall back to FeatureFlags.
  # An explicitly configured 0% rollout returns false (not a fallthrough to
  # FeatureFlags) — the operator set it to 0% intentionally.
  defp auto_should_use_elixir?(capability) do
    case :ets.lookup(@config_ets, capability) do
      [{^capability, %{percentage: pct}}] ->
        # Percentage-based routing: hash monotonic time into 0..99,
        # route to Elixir if hash < percentage. 0% → always false.
        rem(:erlang.phash2(:erlang.monotonic_time(), 100), 100) < pct

      [] ->
        # No rollout config at all — fall back to FeatureFlags boolean
        CodePuppyControl.FeatureFlags.enabled?(capability)
    end
  end

  # Map runtime + outcome to the counter key atom
  defp counter_key(:elixir, :ok), do: :elixir_ok
  defp counter_key(:elixir, :error), do: :elixir_err
  defp counter_key(:python, :ok), do: :python_ok
  defp counter_key(:python, :error), do: :python_err

  # Ensure the counter row exists so update_counter won't fail.
  # Uses insert_new to avoid overwriting existing values.
  defp ensure_counter_row(capability) do
    for key <- [:elixir_ok, :elixir_err, :python_ok, :python_err] do
      row = {{capability, key}, 0}
      :ets.insert_new(@counters_ets, row)
    end
  end

  # Read a single counter value
  defp get_counter(capability, key) do
    case :ets.lookup(@counters_ets, {capability, key}) do
      [{{^capability, ^key}, val}] -> val
      [] -> 0
    end
  end

  # Get the error threshold for a capability (default: 10%)
  defp get_error_threshold(capability) do
    case :ets.lookup(@config_ets, capability) do
      [{^capability, %{error_threshold: threshold}}] -> threshold
      [] -> @default_error_threshold
    end
  end
end
