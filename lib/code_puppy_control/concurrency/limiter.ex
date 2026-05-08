defmodule CodePuppyControl.Concurrency.Limiter do
  @moduledoc """
  ETS-backed concurrency limiter with GenServer-coordinated blocking.

  Provides configurable concurrency limits for different operation types
  (`:file_ops`, `:api_calls`, `:tool_calls`). Uses ETS atomic counters
  for lock-free `try_acquire/1` reads and GenServer serialization for
  blocking `acquire/2` with FIFO waiter fairness.

  ## Architecture

  - **ETS table** (`:concurrency_limits`): Public read access for `status/0`
    and `try_acquire/1`. Each row: `{type, current_count, limit}`.
  - **GenServer**: Serializes blocking acquires, maintains a FIFO queue
    of waiters per limiter type, and wakes waiters on `release/1`.

  ## Configuration

      config :code_puppy_control, :concurrency_limits,
        file_ops: 4,
        api_calls: 2,
        tool_calls: 8

  ## Telemetry Events

  - `[:code_puppy, :concurrency, :acquire]` — emitted on successful acquire
  - `[:code_puppy, :concurrency, :release]` — emitted on release
  """

  use GenServer

  require Logger

  @table :concurrency_limits

  @type limiter_type :: :file_ops | :api_calls | :tool_calls

  @default_limits %{
    file_ops: 3,
    api_calls: 2,
    tool_calls: 4
  }

  @default_timeout 30_000

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Starts the concurrency limiter GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires a concurrency slot for the given limiter type.

  Blocks until a slot becomes available or the timeout expires. Uses FIFO
  ordering to ensure fairness among waiting callers.

  Returns `:ok` on success or `{:error, :timeout}` if no slot was available
  within the timeout period.

  ## Examples

      :ok = Limiter.acquire(:file_ops)
      :ok = Limiter.acquire(:api_calls, timeout: 5_000)
      {:error, :timeout} = Limiter.acquire(:tool_calls, timeout: 100)
  """
  @spec acquire(limiter_type(), keyword()) :: :ok | {:error, :timeout}
  def acquire(type, opts \\ []) when type in [:file_ops, :api_calls, :tool_calls] do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    GenServer.call(__MODULE__, {:acquire, type, timeout}, call_timeout(timeout))
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Resets all counters and pending waiters while preserving configured limits.

  This is primarily used by test reset helpers to guarantee isolation across
  tests that exercise blocking acquire timeouts.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Executes `fun` after acquiring a concurrency slot, and always releases it.

  Returns `{:ok, result}` on success, or `{:error, :timeout}` if no slot
  became available within the timeout.

  ## Examples

      Limiter.with_slot(:file_ops, fn ->
        File.read!("large.txt")
      end)
  """
  @spec with_slot(limiter_type(), (-> result), keyword()) ::
          {:ok, result} | {:error, :timeout}
        when result: any()
  def with_slot(type, fun, opts \\ []) when is_function(fun, 0) do
    case acquire(type, opts) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          release(type)
        end

      {:error, :timeout} = err ->
        err
    end
  end

  @doc """
  Releases a previously acquired concurrency slot.

  Decrements the counter for the given limiter type and wakes up the next
  waiting caller (if any) in FIFO order.

  Emits `[:code_puppy, :concurrency, :release]` telemetry event.

  ## Examples

      Limiter.release(:file_ops)
  """
  @spec release(limiter_type()) :: :ok
  def release(type) when type in [:file_ops, :api_calls, :tool_calls] do
    GenServer.cast(__MODULE__, {:release, type})
  end

  @doc """
  Non-blocking attempt to acquire a concurrency slot.

  Reads the ETS counter directly (no GenServer call) and atomically
  increments it if capacity is available. Returns a reference on success.

  Emits `[:code_puppy, :concurrency, :acquire]` telemetry event on success.

  ## Examples

      {:ok, ref} = Limiter.try_acquire(:file_ops)
      {:error, :unavailable} = Limiter.try_acquire(:api_calls)
  """
  @spec try_acquire(limiter_type()) :: {:ok, reference()} | {:error, :unavailable}
  def try_acquire(type) when type in [:file_ops, :api_calls, :tool_calls] do
    # Use update_counter with a match-conditional approach:
    # We increment only if count < limit by using a guard in the update.
    # Since ETS update_counter is atomic, we try to increment and check after.
    case :ets.lookup(@table, type) do
      [{^type, current, limit}] when current < limit ->
        # Atomically increment
        new_count = :ets.update_counter(@table, type, {2, 1})

        if new_count <= limit do
          emit_acquire(type, new_count, limit)
          {:ok, make_ref()}
        else
          # Another process beat us — undo and report unavailable
          :ets.update_counter(@table, type, {2, -1})
          {:error, :unavailable}
        end

      [{^type, _current, _limit}] ->
        {:error, :unavailable}

      [] ->
        {:error, :not_initialized}
    end
  end

  @doc """
  Returns the current concurrency status for all limiter types.

  Returns a map with limit, available, and in_use counts for each type.

  ## Examples

      Limiter.status()
      #=> %{
      #     file_ops: %{limit: 4, available: 3, in_use: 1},
      #     api_calls: %{limit: 2, available: 2, in_use: 0},
      #     tool_calls: %{limit: 8, available: 5, in_use: 3}
      #   }
  """
  @spec status() :: %{
          limiter_type() => %{
            limit: non_neg_integer(),
            available: non_neg_integer(),
            in_use: non_neg_integer()
          }
        }
  def status do
    @table
    |> :ets.tab2list()
    |> Map.new(fn {type, current, limit} ->
      {type, %{limit: limit, available: max(limit - current, 0), in_use: current}}
    end)
  end

  @doc """
  Synchronous ping to flush pending messages. Useful in tests to ensure
  all casts have been processed before checking state.
  """
  @spec ping() :: :pong
  def ping do
    GenServer.call(__MODULE__, :ping)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    limits = load_limits()

    for {type, limit} <- limits do
      :ets.insert(table, {type, 0, limit})
    end

    Logger.info("ConcurrencyLimiter initialized with limits: #{inspect(limits)}")

    {:ok, %{waiters: %{}}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    reply_to_all_waiters(state, {:error, :timeout})
    reset_counters()

    {:reply, :ok, %{state | waiters: %{}}}
  end

  @impl true
  def handle_call({:acquire, type, timeout}, from, state) do
    [{^type, current, limit}] = :ets.lookup(@table, type)

    if current < limit do
      # Slot available — increment and reply immediately
      :ets.update_counter(@table, type, {2, 1})
      emit_acquire(type, current + 1, limit)
      {:reply, :ok, state}
    else
      # No slot — queue the caller for later
      ref = make_ref()
      timer_ref = maybe_start_timeout_timer(type, ref, timeout)
      queue = Map.get(state.waiters, type, :queue.new())
      queue = :queue.in(%{from: from, ref: ref, timer_ref: timer_ref}, queue)
      {:noreply, put_in(state, [:waiters, type], queue)}
    end
  end

  @impl true
  def handle_cast({:release, type}, state) do
    # Decrement the counter (floor at 0)
    [{^type, current, limit}] = :ets.lookup(@table, type)

    if current > 0 do
      :ets.update_counter(@table, type, {2, -1})
    end

    emit_release(type, max(current - 1, 0), limit)

    # Wake the next waiter (if any)
    state = dequeue_and_reply(state, type)

    {:noreply, state}
  end

  @impl true
  def handle_info({:acquire_timeout, type, ref}, state) do
    {waiter, state} = pop_waiter(state, type, ref)

    if waiter do
      GenServer.reply(waiter.from, {:error, :timeout})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp load_limits do
    config_limits = Application.get_env(:code_puppy_control, :concurrency_limits, [])

    @default_limits
    |> Map.new(fn {type, default} ->
      {type, Keyword.get(config_limits, type, default)}
    end)
  end

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout), do: timeout + 5_000

  defp maybe_start_timeout_timer(_type, _ref, :infinity), do: nil

  defp maybe_start_timeout_timer(type, ref, timeout) do
    Process.send_after(self(), {:acquire_timeout, type, ref}, timeout)
  end

  defp dequeue_and_reply(state, type) do
    queue = Map.get(state.waiters, type, :queue.new())

    case :queue.out(queue) do
      {{:value, waiter}, rest_queue} ->
        cancel_timeout_timer(waiter.timer_ref)

        # Increment counter for the woken waiter
        [{^type, current, limit}] = :ets.lookup(@table, type)
        new_count = current + 1
        :ets.insert(@table, {type, new_count, limit})

        emit_acquire(type, new_count, limit)

        GenServer.reply(waiter.from, :ok)

        put_in(state, [:waiters, type], rest_queue)

      {:empty, _} ->
        # No waiters — remove the key from state
        Map.delete(state.waiters, type)
        |> then(&Map.put(state, :waiters, &1))
    end
  end

  defp pop_waiter(state, type, ref) do
    queue = Map.get(state.waiters, type, :queue.new())

    {matching_waiters, remaining_waiters} =
      queue
      |> :queue.to_list()
      |> Enum.split_with(&(&1.ref == ref))

    waiters =
      if remaining_waiters == [] do
        Map.delete(state.waiters, type)
      else
        Map.put(state.waiters, type, :queue.from_list(remaining_waiters))
      end

    {List.first(matching_waiters), %{state | waiters: waiters}}
  end

  defp reply_to_all_waiters(state, reply) do
    state.waiters
    |> Map.values()
    |> Enum.flat_map(&:queue.to_list/1)
    |> Enum.each(fn waiter ->
      cancel_timeout_timer(waiter.timer_ref)
      GenServer.reply(waiter.from, reply)
    end)
  end

  defp reset_counters do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {type, _current, limit} ->
      :ets.insert(@table, {type, 0, limit})
    end)
  end

  defp cancel_timeout_timer(nil), do: :ok

  defp cancel_timeout_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp emit_acquire(type, current, limit) do
    :telemetry.execute(
      [:code_puppy, :concurrency, :acquire],
      %{count: current, limit: limit, timestamp: System.monotonic_time()},
      %{type: type}
    )
  end

  defp emit_release(type, current, limit) do
    :telemetry.execute(
      [:code_puppy, :concurrency, :release],
      %{count: current, limit: limit, timestamp: System.monotonic_time()},
      %{type: type}
    )
  end
end
