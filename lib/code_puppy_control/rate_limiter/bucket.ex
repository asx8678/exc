defmodule CodePuppyControl.RateLimiter.Bucket do
  @moduledoc """
  Token bucket for rate limiting (RPM/TPM dimensions).
  ETS row: {key, tokens, capacity, last_refill_mono}.
  """

  @type dimension :: :rpm | :tpm
  @type key :: {model :: String.t(), dimension()}
  @type clock :: (-> integer())

  @table :rate_limiter_buckets

  @spec table() :: atom()
  def table, do: @table

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

  @spec clear() :: :ok
  def clear do
    if :ets.info(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @spec init_bucket(key(), pos_integer(), clock()) :: :ok
  def init_bucket(key, capacity, clock \\ fn -> System.monotonic_time() end)
      when is_tuple(key) and capacity > 0 do
    :ets.insert(@table, {key, capacity, capacity, clock.()})
    :ok
  end

  @spec take(key(), pos_integer(), clock()) :: :ok | {:wait, pos_integer()}
  def take(key, amount \\ 1, _clock \\ fn -> System.monotonic_time() end)
      when is_tuple(key) and amount > 0 do
    try do
      current = :ets.lookup_element(@table, key, 2)

      if current >= amount do
        :ets.update_counter(@table, key, {2, -amount})
        :ok
      else
        {:wait, 1_000}
      end
    rescue
      ArgumentError -> :ok
    end
  end

  @spec refill(key(), float(), clock()) :: non_neg_integer()
  def refill(key, rate_per_second, clock \\ fn -> System.monotonic_time() end)
      when is_tuple(key) and is_float(rate_per_second) do
    now = clock.()

    case :ets.lookup(@table, key) do
      [{^key, tokens, capacity, last_refill}] ->
        elapsed_s = max(0, now - last_refill) / 1_000
        new_tokens = min(capacity, trunc(tokens + elapsed_s * rate_per_second))
        :ets.insert(@table, {key, new_tokens, capacity, now})
        new_tokens

      [] ->
        0
    end
  end

  @spec set_capacity(key(), pos_integer()) :: :ok
  def set_capacity(key, new_capacity) when is_tuple(key) and new_capacity > 0 do
    case :ets.lookup(@table, key) do
      [{^key, tokens, _cap, last}] ->
        :ets.insert(@table, {key, min(tokens, new_capacity), new_capacity, last})

      [] ->
        :ok
    end

    :ok
  end

  @spec info(key()) :: {:ok, map()} | :not_found
  def info(key) when is_tuple(key) do
    case :ets.lookup(@table, key) do
      [{^key, tokens, capacity, last_refill}] ->
        {:ok, %{tokens: tokens, capacity: capacity, last_refill: last_refill}}

      [] ->
        :not_found
    end
  end

  @spec delete(key()) :: :ok
  def delete(key) when is_tuple(key) do
    :ets.delete(@table, key)
    :ok
  end
end
