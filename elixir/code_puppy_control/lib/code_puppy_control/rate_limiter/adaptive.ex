defmodule CodePuppyControl.RateLimiter.Adaptive do
  @moduledoc """
  Adaptive backoff and circuit breaker state for per-model rate limiting.

  Models transition through three circuit states:

  - **`:closed`** — normal operation, requests flow through.
  - **`:open`** — circuit tripped by 429, all acquire calls return `{:wait, ms}`.
  - **`:half_open`** — cooldown elapsed, one test request allowed.

  ## Capacity Adaptation

  On 429, effective capacity is halved (never below `min_capacity`).
  After a cooldown period with no 429s, capacity recovers toward the
  nominal value by `recovery_fraction` per cooldown tick.

  ## ETS Layout

  Row: `{model_name, circuit_state, opened_at, cooldown_mult,
         consecutive_ok, capacity_ratio, last_429_at, total_429s}`

  All fields except `model_name` are mutable.
  """

  @type circuit_state :: :closed | :open | :half_open

  @table :rate_limiter_circuits

  # Default config
  @default_min_capacity 1
  @default_cooldown_ms 10_000
  @default_recovery_fraction 0.5
  @shrink_factor 0.5
  @max_cooldown_mult 64.0

  @doc """
  Returns the ETS table name used by adaptive state.
  """
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Creates the ETS table for circuit breaker state.
  """
  @spec create_table() :: :ok
  def create_table do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ok
  end

  @doc """
  Deletes all circuit breaker state entries. Useful for test cleanup.
  """
  @spec clear() :: :ok
  def clear do
    if :ets.info(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc """
  Ensures an adaptive state entry exists for the given model.

  If it already exists, this is a no-op. Initial state is `:closed`
  with `capacity_ratio` of 1.0.
  """
  @spec ensure(String.t(), clock_fn :: (-> integer())) :: :ok
  def ensure(model_name, _clock_fn \\ fn -> System.monotonic_time() end) do
    key = normalize(model_name)

    # Insert only if not present (race-safe with :ets.insert_new)
    _ =
      :ets.insert_new(@table, {
        key,
        # circuit_state
        :closed,
        # opened_at
        0,
        # cooldown_mult
        1.0,
        # consecutive_ok
        0,
        # capacity_ratio
        1.0,
        # last_429_at
        0,
        # total_429s
        0
      })

    :ok
  end

  @doc """
  Called when a 429 is received for this model.

  Effects:
  1. Opens the circuit (or extends cooldown if already open).
  2. Halves `capacity_ratio` (floored at `min/max_capacity` ratio).

  Returns `{:open, effective_cooldown_ms}`.
  """
  @spec on_rate_limit(String.t(), keyword()) :: {:open, pos_integer()}
  def on_rate_limit(model_name, opts \\ []) do
    key = normalize(model_name)
    now = now_mono(opts)
    cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)
    min_capacity = Keyword.get(opts, :min_capacity, @default_min_capacity)
    nominal_capacity = Keyword.get(opts, :nominal_capacity, 10)

    min_ratio = min_capacity / max(nominal_capacity, 1)

    case :ets.lookup(@table, key) do
      [{^key, :closed, _, _mult, _, ratio, _, total}] ->
        new_ratio = max(min_ratio, ratio * @shrink_factor)
        :ets.insert(@table, {key, :open, now, 1.0, 0, new_ratio, now, total + 1})
        {:open, cooldown_ms}

      [{^key, :open, opened_at, mult, _, ratio, _, total}] ->
        # Already open — double cooldown multiplier
        new_mult = min(mult * 2.0, @max_cooldown_mult)
        new_ratio = max(min_ratio, ratio * @shrink_factor)
        effective = trunc(cooldown_ms * new_mult)
        :ets.insert(@table, {key, :open, opened_at, new_mult, 0, new_ratio, now, total + 1})
        {:open, effective}

      [{^key, :half_open, _, mult, _, ratio, _, total}] ->
        # 429 during half-open → reopen with doubled cooldown
        new_mult = min(mult * 2.0, @max_cooldown_mult)
        new_ratio = max(min_ratio, ratio * @shrink_factor)
        effective = trunc(cooldown_ms * new_mult)
        :ets.insert(@table, {key, :open, now, new_mult, 0, new_ratio, now, total + 1})
        {:open, effective}

      [] ->
        # No state — create and open
        :ets.insert(@table, {key, :open, now, 1.0, 0, @shrink_factor, now, 1})
        {:open, cooldown_ms}
    end
  end

  @doc """
  Called on a successful (non-429) response.

  If the circuit is `:half_open` and this is the test request,
  transitions to `:closed`.

  If the circuit is `:closed`, increments `consecutive_ok` and
  grows `capacity_ratio` toward 1.0 when enough successes accumulate.

  Returns the new circuit state.
  """
  @spec on_success(String.t(), keyword()) :: circuit_state()
  def on_success(model_name, opts \\ []) do
    key = normalize(model_name)
    recovery_fraction = Keyword.get(opts, :recovery_fraction, @default_recovery_fraction)

    case :ets.lookup(@table, key) do
      [{^key, :half_open, _, _mult, _, ratio, last_429, total}] ->
        # Test request succeeded → close circuit
        :ets.insert(@table, {key, :closed, 0, 1.0, 0, ratio, last_429, total})
        :closed

      [{^key, :closed, _, mult, consec_ok, ratio, last_429, total}] ->
        # Grow capacity toward 1.0
        new_consec = consec_ok + 1
        # Grow by recovery_fraction after every batch of successes
        # (batch size = 10 to avoid growing too fast on a single success)
        new_ratio =
          if rem(new_consec, 10) == 0 do
            min(1.0, ratio + recovery_fraction * (1.0 - ratio))
          else
            ratio
          end

        :ets.insert(@table, {key, :closed, 0, mult, new_consec, new_ratio, last_429, total})
        :closed

      [{^key, :open, _, _, _, _, _, _}] ->
        # Circuit is open — success irrelevant, tick handles half-open
        :open

      [] ->
        :closed
    end
  end

  @doc """
  Checks whether the circuit is open and if a cooldown transition
  to `:half_open` should be triggered.

  Called periodically by the GenServer tick.

  Returns `:open` if still open, `:half_open` if transitioned, or `:closed`.
  """
  @spec maybe_half_open(String.t(), keyword()) :: circuit_state()
  def maybe_half_open(model_name, opts \\ []) do
    key = normalize(model_name)
    now = now_mono(opts)
    cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)

    case :ets.lookup(@table, key) do
      [{^key, :open, opened_at, mult, _, _, _, _}] ->
        effective_cooldown = trunc(cooldown_ms * mult)

        if now - opened_at >= effective_cooldown do
          :ets.update_element(@table, key, {2, :half_open})
          :half_open
        else
          :open
        end

      [{^key, state, _, _, _, _, _, _}] ->
        state

      [] ->
        :closed
    end
  end

  @doc """
  Returns the current circuit state and capacity ratio for a model.
  """
  @spec info(String.t()) :: {:ok, map()} | :not_found
  def info(model_name) do
    key = normalize(model_name)

    case :ets.lookup(@table, key) do
      [{^key, state, opened_at, mult, consec_ok, ratio, last_429, total}] ->
        {:ok,
         %{
           circuit_state: state,
           opened_at: opened_at,
           cooldown_multiplier: mult,
           consecutive_ok: consec_ok,
           capacity_ratio: ratio,
           last_429_at: last_429,
           total_429s: total
         }}

      [] ->
        :not_found
    end
  end

  @doc """
  Resets the adaptive state for a model to default (closed, full capacity).
  """
  @spec reset(String.t()) :: :ok
  def reset(model_name) do
    key = normalize(model_name)
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Returns the effective capacity multiplier for a model.

  Returns 1.0 if no state exists.
  """
  @spec capacity_ratio(String.t()) :: float()
  def capacity_ratio(model_name) do
    key = normalize(model_name)

    case :ets.lookup_element(@table, key, 6) do
      ratio when is_float(ratio) -> ratio
      _ -> 1.0
    end
  rescue
    ArgumentError -> 1.0
  end

  @doc """
  Returns the current circuit state atom for a model.

  Returns `:closed` if no state exists.
  """
  @spec circuit_state(String.t()) :: circuit_state()
  def circuit_state(model_name) do
    key = normalize(model_name)

    case :ets.lookup_element(@table, key, 2) do
      state when state in [:closed, :open, :half_open] -> state
      _ -> :closed
    end
  rescue
    ArgumentError -> :closed
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp normalize(model_name) do
    model_name |> to_string() |> String.downcase() |> String.trim()
  end

  defp now_mono(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time() end)
    clock.()
  end
end
