defmodule CodePuppyControl.TokenLedger do
  @moduledoc """
  Central token ledger for per-attempt and per-session token accounting.

  Records every LLM request attempt with token usage and cost data.
  Provides rollup summaries at run, session, and model levels.

  ## Architecture

  - **GenServer** handles all writes (record_attempt) for serializability.
  - **ETS tables** provide lock-free reads for rollup queries.
  - **Attempts table** stores individual records keyed by `{run_id, timestamp}`.
  - **Rollup tables** accumulate counters per run, session, and model.

  ## Usage

      # Record an attempt after LLM turn completes
      TokenLedger.record_attempt("run-123", "claude-sonnet-4-20250514",
        prompt_tokens: 1000, completion_tokens: 500, cached_tokens: 200,
        session_id: "sess-1", cost_cents: 30)

      # Query summaries
      TokenLedger.run_summary("run-123")
      TokenLedger.session_summary("sess-1")
      TokenLedger.model_rollup("claude-sonnet-4-20250514")

  ## Design Notes

  - Attempts are stored in an ordered_set keyed by `{run_id, timestamp, unique_id}`.
    This enables efficient range queries per run.
  - Rollup counters use flat tuples for `:ets.update_counter` compatibility.
  - Maximum 10,000 attempts per run (oldest dropped on overflow).
  """

  use GenServer

  require Logger

  alias CodePuppyControl.TokenLedger.{Attempt, Cost}

  # ETS table names
  @attempts_table :token_ledger_attempts
  @run_rollup_table :token_ledger_run_rollups
  @session_rollup_table :token_ledger_session_rollups
  @model_rollup_table :token_ledger_model_rollups

  # Maximum attempts per run before oldest are dropped
  @max_attempts_per_run 10_000

  # Rollup tuple positions (1-indexed)
  # pos 1 = key, pos 2 = total_attempts, pos 3 = successful, pos 4 = failed,
  # pos 5 = prompt_tokens, pos 6 = completion_tokens, pos 7 = cached_tokens,
  # pos 8 = total_tokens, pos 9 = cost_cents
  @pos_total_attempts 2
  @pos_successful 3
  @pos_failed 4
  @pos_prompt_tokens 5
  @pos_completion_tokens 6
  @pos_cached_tokens 7
  @pos_total_tokens 8
  @pos_cost_cents 9

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the TokenLedger GenServer.

  Creates all ETS tables during initialization.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a token usage attempt.

  Computes cost automatically from the model cost table unless `:cost_cents`
  is explicitly provided. Returns `:ok`.

  ## Parameters

    * `run_id` — The agent run identifier.
    * `model` — Model name used for this attempt.
    * `opts` — Keyword list:
      * `:session_id` — Session identifier (optional).
      * `:prompt_tokens` — Input token count (default: 0).
      * `:completion_tokens` — Output token count (default: 0).
      * `:cached_tokens` — Cached token count (default: 0).
      * `:cost_cents` — Explicit cost override (default: computed from model).
      * `:status` — `:ok` or `:error` (default: `:ok`).
  """
  @spec record_attempt(String.t(), String.t(), keyword()) :: :ok
  def record_attempt(run_id, model, opts \\ []) do
    GenServer.call(__MODULE__, {:record_attempt, run_id, model, opts})
  end

  @doc """
  Returns a summary map for a specific run.
  """
  @spec run_summary(String.t()) :: map()
  def run_summary(run_id) do
    counters = read_rollup(@run_rollup_table, run_id, :run_id)
    models = models_used_for_run(run_id)
    Map.put(counters, :models_used, models)
  end

  @doc """
  Returns a summary map for a specific session.

  Aggregates across all runs within the session.
  """
  @spec session_summary(String.t()) :: map()
  def session_summary(session_id) do
    counters = read_rollup(@session_rollup_table, session_id, :session_id)
    models = models_used_for_session(session_id)
    Map.put(counters, :models_used, models)
  end

  @doc """
  Returns a rollup summary for a specific model.

  Aggregates across all runs and sessions using this model.
  """
  @spec model_rollup(String.t()) :: map()
  def model_rollup(model) do
    read_rollup(@model_rollup_table, model, :model)
  end

  @doc """
  Returns all attempts for a given run, ordered by timestamp.
  """
  @spec run_attempts(String.t()) :: [Attempt.t()]
  def run_attempts(run_id) do
    match_spec = [
      {{{:"$1", :_, :_}, :"$2"}, [{:==, :"$1", run_id}], [:"$2"]}
    ]

    :ets.select(@attempts_table, match_spec)
  end

  @doc """
  Clears all ledger data. Useful for testing.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@attempts_table, [
      :ordered_set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    for table <- [@run_rollup_table, @session_rollup_table, @model_rollup_table] do
      :ets.new(table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    Logger.info("TokenLedger started with ETS tables")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:record_attempt, run_id, model, opts}, _from, state) do
    prompt_tokens = Keyword.get(opts, :prompt_tokens, 0)
    completion_tokens = Keyword.get(opts, :completion_tokens, 0)
    cached_tokens = Keyword.get(opts, :cached_tokens, 0)

    cost_cents =
      Keyword.get_lazy(opts, :cost_cents, fn ->
        Cost.compute_cost(model, prompt_tokens, completion_tokens, cached_tokens)
      end)

    session_id = Keyword.get(opts, :session_id)
    status = Keyword.get(opts, :status, :ok)
    timestamp = System.system_time(:millisecond)

    attempt = %Attempt{
      run_id: run_id,
      session_id: session_id,
      model: model,
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      cached_tokens: cached_tokens,
      total_tokens: prompt_tokens + completion_tokens,
      cost_cents: cost_cents,
      timestamp: timestamp,
      status: status
    }

    unique_id = System.unique_integer([:positive, :monotonic])
    :ets.insert(@attempts_table, {{run_id, timestamp, unique_id}, attempt})
    enforce_max_attempts(run_id)

    inc_s = if status == :ok, do: 1, else: 0
    inc_f = if status == :error, do: 1, else: 0

    do_update_rollup(
      @run_rollup_table,
      run_id,
      prompt_tokens,
      completion_tokens,
      cached_tokens,
      attempt.total_tokens,
      cost_cents,
      inc_s,
      inc_f
    )

    if session_id do
      do_update_rollup(
        @session_rollup_table,
        session_id,
        prompt_tokens,
        completion_tokens,
        cached_tokens,
        attempt.total_tokens,
        cost_cents,
        inc_s,
        inc_f
      )
    end

    do_update_rollup(
      @model_rollup_table,
      model,
      prompt_tokens,
      completion_tokens,
      cached_tokens,
      attempt.total_tokens,
      cost_cents,
      inc_s,
      inc_f
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    for table <- [@attempts_table, @run_rollup_table, @session_rollup_table, @model_rollup_table] do
      :ets.delete_all_objects(table)
    end

    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Rollup Update — flat tuple for update_counter
  # ---------------------------------------------------------------------------

  # Default: {key, total_attempts, successful, failed, prompt, completion, cached, total, cost}
  defp do_update_rollup(table, key, prompt, completion, cached, total, cost, succ, fail) do
    default = {key, 0, 0, 0, 0, 0, 0, 0, 0}

    :ets.update_counter(
      table,
      key,
      [
        {@pos_total_attempts, 1},
        {@pos_successful, succ},
        {@pos_failed, fail},
        {@pos_prompt_tokens, prompt},
        {@pos_completion_tokens, completion},
        {@pos_cached_tokens, cached},
        {@pos_total_tokens, total},
        {@pos_cost_cents, cost}
      ],
      default
    )
  end

  # ---------------------------------------------------------------------------
  # Rollup Readers
  # ---------------------------------------------------------------------------

  defp read_rollup(table, key, key_name) do
    case :ets.lookup(table, key) do
      [{^key, _total_attempts, successful, failed, prompt, completion, cached, total, cost}] ->
        %{
          key_name => key,
          total_attempts: successful + failed,
          successful: successful,
          failed: failed,
          prompt_tokens: prompt,
          completion_tokens: completion,
          cached_tokens: cached,
          total_tokens: total,
          cost_cents: cost
        }

      [] ->
        %{
          key_name => key,
          total_attempts: 0,
          successful: 0,
          failed: 0,
          prompt_tokens: 0,
          completion_tokens: 0,
          cached_tokens: 0,
          total_tokens: 0,
          cost_cents: 0,
          models_used: MapSet.new()
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Models Used — computed from attempts table
  # ---------------------------------------------------------------------------

  defp models_used_for_run(run_id) do
    match_spec = [
      {{{:"$1", :_, :_}, %{model: :"$2"}}, [{:==, :"$1", run_id}], [:"$2"]}
    ]

    @attempts_table
    |> :ets.select(match_spec)
    |> MapSet.new()
  end

  defp models_used_for_session(session_id) do
    match_spec = [
      {{:_, %{session_id: :"$1", model: :"$2"}}, [{:==, :"$1", session_id}], [:"$2"]}
    ]

    @attempts_table
    |> :ets.select(match_spec)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # Max Attempts Enforcement
  # ---------------------------------------------------------------------------

  defp enforce_max_attempts(run_id) do
    match_spec = [
      {{{:"$1", :_, :_}, :_}, [{:==, :"$1", run_id}], [true]}
    ]

    count = :ets.select_count(@attempts_table, match_spec)

    if count > @max_attempts_per_run do
      select_spec = [
        {{{:"$1", :"$2", :"$3"}, :_}, [{:==, :"$1", run_id}], [{{:"$2", :"$3"}}]}
      ]

      to_delete = count - @max_attempts_per_run

      keys_to_delete =
        @attempts_table
        |> :ets.select(select_spec)
        |> Enum.sort()
        |> Enum.take(to_delete)
        |> Enum.map(fn {ts, uid} -> {run_id, ts, uid} end)

      for k <- keys_to_delete, do: :ets.delete(@attempts_table, k)
    end
  end
end
