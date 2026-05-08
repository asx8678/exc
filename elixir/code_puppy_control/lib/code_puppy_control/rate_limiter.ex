defmodule CodePuppyControl.RateLimiter do
  @moduledoc """
  Adaptive rate limiter with per-model token buckets and circuit breaker.

  Prevents rate-limit storms by proactively limiting request rates per
  model. On HTTP 429, capacity is halved and a circuit breaker opens.
  A background tick gradually recovers capacity toward nominal values.

  ## Architecture

  - **ETS tables** for lock-free reads (`:rate_limiter_buckets`,
    `:rate_limiter_circuits`).
  - **GenServer** for periodic refill ticks and serializing capacity
    mutations (shrink on 429, recover on cooldown).
  - **Bucket** module — pure token bucket math + ETS atomic ops.
  - **Adaptive** module — circuit breaker state transitions.

  ## Configuration

  Per-model nominal limits can be set via `Application` config:

      config :code_puppy_control, CodePuppyControl.RateLimiter,
        nominal_rpm: 60,
        nominal_tpm: 200_000,
        refill_interval_ms: 1_000,
        cooldown_ms: 10_000

  Or per-model via `set_limits/3`.

  ## Usage

      # Before making an LLM request
      case RateLimiter.acquire("gpt-4o", estimated_tokens: 500) do
        :ok ->
          # Proceed with request
          {:ok, response} = HttpClient.request(...)
          RateLimiter.record_response("gpt-4o", response.status, response.headers)
        {:wait, ms} ->
          Process.sleep(ms)
          # Retry acquire
      end

  ## Telemetry Events

  - `[:code_puppy, :rate_limiter, :acquire]` — on successful acquire
  - `[:code_puppy, :rate_limiter, :rate_limited]` — on 429 recorded
  - `[:code_puppy, :rate_limiter, :refill]` — on each refill tick
  """

  use GenServer

  require Logger

  alias CodePuppyControl.RateLimiter.{Bucket, Adaptive}

  # ── Types ──────────────────────────────────────────────────────────────────

  @type model_name :: String.t()

  # ── Default config ─────────────────────────────────────────────────────────

  @default_nominal_rpm 60
  @default_nominal_tpm 200_000
  @default_min_rpm 1
  @default_min_tpm 100
  @default_refill_interval_ms 1_000
  @default_cooldown_ms 10_000
  @default_half_open_max 1

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the rate limiter GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to acquire a rate-limit slot for the given model.

  Checks both RPM (requests per minute) and TPM (tokens per minute)
  buckets atomically. If the circuit breaker is open, returns
  `{:wait, ms}` immediately.

  ## Options

  - `:estimated_tokens` — estimated token count for TPM check (default: 1000)

  Returns `:ok` if the request should proceed, or `{:wait, ms}` indicating
  how long to wait before retrying.

  ## Examples

      iex> RateLimiter.acquire("gpt-4o")
      :ok

      iex> RateLimiter.acquire("gpt-4o", estimated_tokens: 500)
      :ok
  """
  @spec acquire(model_name(), keyword()) :: :ok | {:wait, pos_integer()}
  def acquire(model_name, opts \\ []) do
    estimated_tokens = Keyword.get(opts, :estimated_tokens, 1000)
    now = System.monotonic_time()

    with :ok <- check_circuit(model_name, now),
         :ok <- Bucket.take({model_name, :rpm}, 1, fn -> now end),
         :ok <- Bucket.take({model_name, :tpm}, estimated_tokens, fn -> now end) do
      emit_telemetry(:acquire, %{model_name: model_name})
      :ok
    else
      {:wait, ms} ->
        {:wait, ms}
    end
  end

  @doc """
  Records a successful or failed HTTP response.

  On success (2xx), signals the adaptive module to potentially close
  a half-open circuit or grow capacity.

  On rate limit (429), calls `record_rate_limit/2` internally.

  ## Parameters

  - `model_name` — the model that was used
  - `status` — HTTP status code
  - `headers` — response headers (for Retry-After parsing)
  """
  @spec record_response(model_name(), non_neg_integer(), [{String.t(), String.t()}]) :: :ok
  def record_response(model_name, status, headers \\ [])

  def record_response(model_name, 429, headers) do
    retry_after_ms = parse_retry_after(headers)
    record_rate_limit(model_name, retry_after_ms)
  end

  def record_response(model_name, status, _headers) when status in 200..299 do
    Adaptive.on_success(model_name)
    :ok
  end

  def record_response(_model_name, _status, _headers) do
    # Non-429 errors don't affect rate limiting
    :ok
  end

  @doc """
  Records a 429 rate limit response for the given model.

  Halves the effective capacity and opens the circuit breaker.
  The GenServer will schedule recovery after the cooldown period.

  ## Parameters

  - `model_name` — the model that was rate-limited
  - `retry_after_ms` — milliseconds to wait (from Retry-After header),
    or `nil` to use default cooldown
  """
  @spec record_rate_limit(model_name(), non_neg_integer() | nil) :: :ok
  def record_rate_limit(model_name, retry_after_ms \\ nil) do
    GenServer.cast(__MODULE__, {:record_rate_limit, model_name, retry_after_ms})
  end

  @doc """
  Returns current stats for a model.
  """
  @spec stats(model_name()) :: map()
  def stats(model_name) do
    rpm_info =
      case Bucket.info({model_name, :rpm}) do
        {:ok, info} -> info
        :not_found -> %{tokens: 0, capacity: 0, last_refill: 0}
      end

    tpm_info =
      case Bucket.info({model_name, :tpm}) do
        {:ok, info} -> info
        :not_found -> %{tokens: 0, capacity: 0, last_refill: 0}
      end

    adaptive_info =
      case Adaptive.info(model_name) do
        {:ok, info} -> info
        :not_found -> %{circuit_state: :closed, capacity_ratio: 1.0, total_429s: 0}
      end

    %{
      model_name: model_name,
      rpm: rpm_info,
      tpm: tpm_info,
      circuit_state: adaptive_info.circuit_state,
      capacity_ratio: adaptive_info.capacity_ratio,
      total_429s: adaptive_info.total_429s
    }
  end

  @doc """
  Clears all rate limiter state. Primarily for test isolation.
  """
  @spec clear() :: :ok
  def clear do
    Bucket.clear()
    Adaptive.clear()
    :ok
  end

  @doc """
  Sets per-model rate limits.

  ## Options

  - `:rpm` — requests per minute (nominal capacity)
  - `:tpm` — tokens per minute (nominal capacity)
  """
  @spec set_limits(model_name(), keyword()) :: :ok
  def set_limits(model_name, opts) do
    GenServer.call(__MODULE__, {:set_limits, model_name, opts})
  end

  @doc """
  Checks whether the circuit breaker is open for a model.

  This is a non-consuming read — useful for UI indicators.
  """
  @spec circuit_open?(model_name()) :: boolean()
  def circuit_open?(model_name) do
    Adaptive.circuit_state(model_name) == :open
  end

  @doc """
  Synchronous ping to flush pending casts. Useful in tests.
  """
  @spec ping() :: :pong
  def ping do
    GenServer.call(__MODULE__, :ping)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Create ETS tables
    Bucket.create_table()
    Adaptive.create_table()

    # Load config
    config = load_config(opts)
    store_config(config)

    # Schedule first refill tick
    interval = config.refill_interval_ms
    Process.send_after(self(), :refill_tick, interval)

    Logger.info(
      "RateLimiter started: RPM=#{config.nominal_rpm}, " <>
        "TPM=#{config.nominal_tpm}, tick=#{interval}ms"
    )

    {:ok, %{config: config, clock: fn -> System.monotonic_time() end}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_call({:set_limits, model_name, opts}, _from, state) do
    rpm = Keyword.get(opts, :rpm, state.config.nominal_rpm)
    tpm = Keyword.get(opts, :tpm, state.config.nominal_tpm)

    Bucket.init_bucket({model_name, :rpm}, rpm, state.clock)
    Bucket.init_bucket({model_name, :tpm}, tpm, state.clock)
    Adaptive.ensure(model_name, state.clock)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record_rate_limit, model_name, retry_after_ms}, state) do
    config = state.config
    cooldown = retry_after_ms || config.cooldown_ms

    # Ensure adaptive state exists
    Adaptive.ensure(model_name, state.clock)

    # Record the 429 (opens circuit, halves capacity ratio)
    {:open, _effective_cooldown} =
      Adaptive.on_rate_limit(model_name,
        cooldown_ms: cooldown,
        min_capacity: config.min_rpm,
        nominal_capacity: config.nominal_rpm
      )

    # Apply capacity ratio to buckets (use actual bucket capacity, not config nominal)
    ratio = Adaptive.capacity_ratio(model_name)

    actual_rpm =
      case Bucket.info({model_name, :rpm}) do
        {:ok, info} -> info.capacity
        _ -> config.nominal_rpm
      end

    actual_tpm =
      case Bucket.info({model_name, :tpm}) do
        {:ok, info} -> info.capacity
        _ -> config.nominal_tpm
      end

    new_rpm = max(config.min_rpm, trunc(actual_rpm * ratio))
    new_tpm = max(config.min_tpm, trunc(actual_tpm * ratio))

    Bucket.set_capacity({model_name, :rpm}, new_rpm)
    Bucket.set_capacity({model_name, :tpm}, new_tpm)

    emit_telemetry(:rate_limited, %{
      model_name: model_name,
      new_rpm: new_rpm,
      new_tpm: new_tpm,
      cooldown_ms: cooldown
    })

    Logger.warning(
      "RateLimiter: #{model_name} rate-limited. " <>
        "RPM→#{new_rpm}, TPM→#{new_tpm}, cooldown=#{cooldown}ms"
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:refill_tick, state) do
    config = state.config
    now = state.clock.()

    # Refill all known buckets
    refill_all_buckets(config, now)

    # Check circuit breakers for half-open transitions
    check_circuit_transitions(config, now)

    # Attempt capacity recovery for models in :closed state
    attempt_recovery(config, now)

    emit_telemetry(:refill, %{timestamp: now})

    # Schedule next tick
    Process.send_after(self(), :refill_tick, config.refill_interval_ms)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private: Circuit Check ─────────────────────────────────────────────────

  defp check_circuit(model_name, _now) do
    case Adaptive.circuit_state(model_name) do
      :closed -> :ok
      # allow test requests
      :half_open -> :ok
      # circuit open, suggest wait
      :open -> {:wait, 1_000}
    end
  end

  # ── Private: Refill Tick ──────────────────────────────────────────────────

  defp refill_all_buckets(config, _now) do
    rpm_rate = config.nominal_rpm / 60.0
    tpm_rate = config.nominal_tpm / 60.0

    # Get all bucket keys from ETS
    all_buckets = :ets.select(Bucket.table(), [{{:"$1", :_, :_, :_}, [], [:"$1"]}])

    for key <- all_buckets do
      {_model, dim} = key
      rate = if dim == :rpm, do: rpm_rate, else: tpm_rate
      Bucket.refill(key, rate)
    end
  end

  defp check_circuit_transitions(config, _now) do
    all_circuits =
      :ets.select(Adaptive.table(), [{{:"$1", :_, :_, :_, :_, :_, :_, :_}, [], [:"$1"]}])

    for model_name <- all_circuits do
      Adaptive.maybe_half_open(model_name, cooldown_ms: config.cooldown_ms)
    end
  end

  defp attempt_recovery(config, _now) do
    all_circuits = :ets.tab2list(Adaptive.table())

    for {model_name, state, _opened_at, _mult, _consec, ratio, _last_429, _total} <- all_circuits,
        state == :closed and ratio < 1.0 do
      # Grow capacity back toward nominal
      new_ratio = min(1.0, ratio + config.recovery_fraction * (1.0 - ratio))
      new_rpm = max(config.min_rpm, trunc(config.nominal_rpm * new_ratio))
      new_tpm = max(config.min_tpm, trunc(config.nominal_tpm * new_ratio))

      Bucket.set_capacity({model_name, :rpm}, new_rpm)
      Bucket.set_capacity({model_name, :tpm}, new_tpm)

      # Update ratio in adaptive state
      :ets.update_element(Adaptive.table(), model_name, {6, new_ratio})
    end
  end

  # ── Private: Config ───────────────────────────────────────────────────────

  defp load_config(opts) do
    app_config = Application.get_env(:code_puppy_control, __MODULE__, [])

    %{
      nominal_rpm:
        Keyword.get(
          opts,
          :nominal_rpm,
          Keyword.get(app_config, :nominal_rpm, @default_nominal_rpm)
        ),
      nominal_tpm:
        Keyword.get(
          opts,
          :nominal_tpm,
          Keyword.get(app_config, :nominal_tpm, @default_nominal_tpm)
        ),
      min_rpm: Keyword.get(opts, :min_rpm, Keyword.get(app_config, :min_rpm, @default_min_rpm)),
      min_tpm: Keyword.get(opts, :min_tpm, Keyword.get(app_config, :min_tpm, @default_min_tpm)),
      refill_interval_ms:
        Keyword.get(
          opts,
          :refill_interval_ms,
          Keyword.get(app_config, :refill_interval_ms, @default_refill_interval_ms)
        ),
      cooldown_ms:
        Keyword.get(
          opts,
          :cooldown_ms,
          Keyword.get(app_config, :cooldown_ms, @default_cooldown_ms)
        ),
      recovery_fraction:
        Keyword.get(opts, :recovery_fraction, Keyword.get(app_config, :recovery_fraction, 0.5)),
      half_open_max:
        Keyword.get(
          opts,
          :half_open_max,
          Keyword.get(app_config, :half_open_max, @default_half_open_max)
        )
    }
  end

  defp store_config(config) do
    # Store in persistent_term for potential lock-free reads
    # (not used currently, but available for future optimization)
    :persistent_term.put({__MODULE__, :config}, config)
  rescue
    # persistent_term not writable in tests sometimes
    ArgumentError -> :ok
  end

  # ── Private: Helpers ──────────────────────────────────────────────────────

  defp parse_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} ->
        case Integer.parse(value) do
          {seconds, ""} ->
            seconds * 1000

          _ ->
            parse_http_date(value)
        end

      nil ->
        nil
    end
  end

  defp parse_http_date(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} ->
        diff = DateTime.diff(datetime, DateTime.utc_now(), :millisecond)
        max(0, diff)

      _ ->
        nil
    end
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:code_puppy, :rate_limiter, event],
      %{count: 1, timestamp: System.monotonic_time()},
      metadata
    )
  end
end
