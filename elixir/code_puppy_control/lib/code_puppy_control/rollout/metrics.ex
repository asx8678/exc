defmodule CodePuppyControl.Rollout.Metrics do
  @moduledoc """
  ETS-based metrics for rollout observability.

  Tracks per-capability success/error counts per runtime by subscribing to
  telemetry events from `RuntimeSelector` and `Fallback`.

  ## Telemetry Events Consumed

    * `[:code_puppy, :runtime, :select]` — counts every runtime selection as
      a success for the selected runtime (captures routing decisions).
    * `[:code_puppy, :runtime, :fallback]` — records successes and errors
      from the fallback lifecycle:
      - `:success` → success for the primary runtime
      - `:fallback` → error for the primary runtime (it failed)
      - `:fallback_success` → success for the secondary runtime
      - `:fallback_failed` → error for the secondary runtime

  ## ETS Schema

  The ETS table uses 2-tuples `{key_tuple, count}` where `key_tuple` is
  `{capability :: atom(), runtime :: atom(), :success | :error}`. This
  makes the 3-tuple key a single element at position 1 (ETS `:set` table
  convention — position 1 is the key). Counters are at position 2 and are
  atomically incremented via `:ets.update_counter/3`.
  """

  use GenServer

  require Logger

  @table :rollout_metrics
  @handler_id "rollout-metrics-handler"

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Starts the Rollout Metrics GenServer.

  ## Options

    * `:name` — registered name (default: `__MODULE__`)

  On init, creates the ETS table and attaches telemetry handlers.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Increments the success counter for a capability+runtime pair.

  Returns the new counter value.
  """
  @spec record_success(atom(), atom()) :: non_neg_integer()
  def record_success(capability, runtime) when is_atom(capability) and is_atom(runtime) do
    key = {capability, runtime, :success}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  @doc """
  Increments the error counter for a capability+runtime pair.

  Returns the new counter value.
  """
  @spec record_error(atom(), atom()) :: non_neg_integer()
  def record_error(capability, runtime) when is_atom(capability) and is_atom(runtime) do
    key = {capability, runtime, :error}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  @doc """
  Returns the success count for a capability+runtime pair.
  """
  @spec success_count(atom(), atom()) :: non_neg_integer()
  def success_count(capability, runtime) do
    case :ets.lookup(@table, {capability, runtime, :success}) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Returns the error count for a capability+runtime pair.
  """
  @spec error_count(atom(), atom()) :: non_neg_integer()
  def error_count(capability, runtime) do
    case :ets.lookup(@table, {capability, runtime, :error}) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Returns the success rate for a capability+runtime pair as a float 0.0..1.0.

  Returns `0.0` when there is no data (no successes or errors recorded).
  """
  @spec success_rate(atom(), atom()) :: float()
  def success_rate(capability, runtime) do
    successes = success_count(capability, runtime)
    errors = error_count(capability, runtime)
    total = successes + errors

    if total == 0, do: 0.0, else: successes / total
  end

  @doc """
  Returns a map of all capabilities with per-runtime metrics.

  The returned map has the shape:

      %{
        capability_atom => %{
          runtime_atom => %{successes: count, errors: count, rate: float}
        }
      }

  Only capabilities with recorded data are included.
  """
  @spec summary() :: %{
          atom() => %{
            atom() => %{successes: non_neg_integer(), errors: non_neg_integer(), rate: float()}
          }
        }
  def summary do
    all_rows = :ets.tab2list(@table)

    pairs =
      all_rows
      |> Enum.map(fn {{capability, runtime, _type}, _count} ->
        {capability, runtime}
      end)
      |> Enum.uniq()

    Enum.reduce(pairs, %{}, fn {capability, runtime}, acc ->
      successes = success_count(capability, runtime)
      errors = error_count(capability, runtime)
      total = successes + errors
      rate = if total == 0, do: 0.0, else: successes / total

      entry = %{successes: successes, errors: errors, rate: rate}

      Map.update(acc, capability, %{runtime => entry}, fn existing ->
        Map.put(existing, runtime, entry)
      end)
    end)
  end

  @doc """
  Resets all metrics counters by deleting all objects from the ETS table.

  Primarily intended for testing.
  """
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.delete_all_objects(@table)
    end

    :ok
  end

  # ── Telemetry Handler ─────────────────────────────────────────────────

  @doc false
  def handle_telemetry([:code_puppy, :runtime, :fallback], _measurements, metadata, _config) do
    capability = metadata[:capability]
    runtime = metadata[:runtime]

    case metadata[:event] do
      :success -> record_success(capability, runtime)
      :fallback -> record_error(capability, runtime)
      :fallback_success -> record_success(capability, runtime)
      :fallback_failed -> record_error(capability, runtime)
      _ -> :ok
    end

    :ok
  end

  def handle_telemetry([:code_puppy, :runtime, :select], _measurements, metadata, _config) do
    record_success(metadata[:capability], metadata[:selected])
    :ok
  end

  def handle_telemetry(_event_name, _measurements, _metadata, _config) do
    :ok
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            :protected,
            write_concurrency: true
          ])

        _tid ->
          @table
      end

    # Detach first to handle GenServer restarts without duplicate handlers
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      [
        [:code_puppy, :runtime, :fallback],
        [:code_puppy, :runtime, :select]
      ],
      &handle_telemetry/4,
      nil
    )

    Logger.debug("Rollout.Metrics initialized with ETS table: #{inspect(table)}")

    {:ok, %{table: table}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end
end
