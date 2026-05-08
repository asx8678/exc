defmodule CodePuppyControl.ModelAvailability do
  @moduledoc """
  Circuit breaker for model availability tracking.

  Tracks model health states for quota-aware failover:
  - healthy: model is working normally (implicit, no ETS entry)
  - sticky_retry: try once more this turn, then skip
  - terminal: quota/capacity exhausted, skip until reset

  This is the Elixir port of the Python `code_puppy/model_availability.py` module.

  ## Storage

  Uses ETS for fast concurrent reads and GenServer-coordinated writes.
  Two tables are used:
  - `:model_health` - stores `{model_id, status, reason, consumed}` tuples
  - `:model_last_resort` - stores `{model_id, true}` for last-resort fallback models

  ## API

  ### Health State Management
  - `mark_terminal/2` - Mark model as terminally unavailable (quota/capacity)
  - `mark_healthy/1` - Clear any failure state for a model
  - `mark_sticky_retry/1` - Allow one more retry, then skip
  - `consume_sticky_attempt/1` - Mark the sticky retry as used
  - `snapshot/1` - Get availability snapshot for a model
  - `select_first_available/1` - Pick first available model from a list
  - `reset_turn/0` - Reset consumed flags for a new turn
  - `reset_all/0` - Clear all health states

  ### Last Resort Tracking
  - `mark_as_last_resort/2` - Mark/unmark a model as last-resort fallback
  - `is_last_resort/1` - Check if a model is last-resort
  - `get_last_resort_models/0` - List all last-resort models

  ## Examples

      iex> ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok
      iex> ModelAvailability.snapshot("gpt-4")
      %{available: false, reason: :quota}

      iex> ModelAvailability.mark_healthy("gpt-4")
      :ok
      iex> ModelAvailability.snapshot("gpt-4")
      %{available: true, reason: nil}

      iex> ModelAvailability.mark_sticky_retry("claude-3")
      :ok
      iex> ModelAvailability.snapshot("claude-3")
      %{available: true, reason: nil}
      iex> ModelAvailability.consume_sticky_attempt("claude-3")
      :ok
      iex> ModelAvailability.snapshot("claude-3")
      %{available: false, reason: :retry_once_per_turn}
  """

  use GenServer

  require Logger

  @health_table :model_health
  @last_resort_table :model_last_resort

  @type health_status :: :terminal | :sticky_retry
  @type unavailability_reason :: :quota | :capacity | :retry_once_per_turn | :unknown

  @typedoc """
  Snapshot of a model's current availability.
  """
  @type snapshot :: %{
          available: boolean(),
          reason: unavailability_reason() | nil
        }

  @typedoc """
  Result of selecting the first available model from a list.
  """
  @type selection_result :: %{
          selected_model: String.t() | nil,
          skipped: [{String.t(), unavailability_reason()}]
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the ModelAvailability GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Mark a model as terminally unavailable (quota/capacity exhausted).

  Terminal models will be skipped by `select_first_available/1` until
  `reset_all/0` is called or the model is explicitly marked healthy.

  ## Examples

      iex> ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok
      iex> ModelAvailability.snapshot("gpt-4")
      %{available: false, reason: :quota}
  """
  @spec mark_terminal(String.t(), unavailability_reason()) :: :ok
  def mark_terminal(model_id, reason \\ :quota) when is_binary(model_id) do
    GenServer.call(__MODULE__, {:mark_terminal, model_id, reason})
  end

  @doc """
  Mark a model as healthy, clearing any failure state.

  Removes the model from the health table, making it implicitly healthy.

  ## Examples

      iex> ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok
      iex> ModelAvailability.mark_healthy("gpt-4")
      :ok
      iex> ModelAvailability.snapshot("gpt-4")
      %{available: true, reason: nil}
  """
  @spec mark_healthy(String.t()) :: :ok
  def mark_healthy(model_id) when is_binary(model_id) do
    GenServer.call(__MODULE__, {:mark_healthy, model_id})
  end

  @doc """
  Mark a model for one more retry this turn, then skip.

  Sticky retry models are available for exactly one attempt, after which
  they become unavailable. This allows a single retry of a failed model
  before moving on to alternatives.

  Does NOT downgrade a terminal model to sticky_retry.

  ## Examples

      iex> ModelAvailability.mark_sticky_retry("claude-3")
      :ok
      iex> ModelAvailability.snapshot("claude-3")
      %{available: true, reason: nil}
  """
  @spec mark_sticky_retry(String.t()) :: :ok
  def mark_sticky_retry(model_id) when is_binary(model_id) do
    GenServer.call(__MODULE__, {:mark_sticky_retry, model_id})
  end

  @doc """
  Mark the sticky retry attempt as consumed.

  After calling this, a sticky_retry model will show as unavailable.

  ## Examples

      iex> ModelAvailability.mark_sticky_retry("claude-3")
      :ok
      iex> ModelAvailability.consume_sticky_attempt("claude-3")
      :ok
      iex> ModelAvailability.snapshot("claude-3")
      %{available: false, reason: :retry_once_per_turn}
  """
  @spec consume_sticky_attempt(String.t()) :: :ok
  def consume_sticky_attempt(model_id) when is_binary(model_id) do
    GenServer.call(__MODULE__, {:consume_sticky, model_id})
  end

  @doc """
  Get the current availability snapshot for a model.

  Returns `%{available: true, reason: nil}` for healthy models (no entry in ETS).
  Returns `%{available: false, reason: reason}` for terminal or consumed sticky models.
  Returns `%{available: true, reason: nil}` for sticky models that haven't been consumed.

  This is a fast ETS lookup that doesn't require a GenServer call.

  ## Examples

      iex> ModelAvailability.snapshot("healthy-model")
      %{available: true, reason: nil}

      iex> ModelAvailability.mark_terminal("dead-model", :quota)
      :ok
      iex> ModelAvailability.snapshot("dead-model")
      %{available: false, reason: :quota}
  """
  @spec snapshot(String.t()) :: snapshot()
  def snapshot(model_id) when is_binary(model_id) do
    case :ets.lookup(@health_table, model_id) do
      [] ->
        %{available: true, reason: nil}

      [{^model_id, :terminal, reason, _consumed}] ->
        %{available: false, reason: reason}

      [{^model_id, :sticky_retry, reason, true}] ->
        %{available: false, reason: reason}

      [{^model_id, :sticky_retry, _reason, false}] ->
        %{available: true, reason: nil}
    end
  end

  @doc """
  Select the first available model from an ordered list.

  Returns a map with:
  - `selected_model`: the first available model name, or nil if none available
  - `skipped`: list of tuples `{model_id, reason}` for models that were skipped

  ## Examples

      iex> ModelAvailability.mark_terminal("bad-model", :quota)
      :ok
      iex> ModelAvailability.select_first_available(["bad-model", "good-model"])
      %{selected_model: "good-model", skipped: [{"bad-model", :quota}]}
  """
  @spec select_first_available([String.t()]) :: selection_result()
  def select_first_available(model_ids) when is_list(model_ids) do
    do_select_first(model_ids, [])
  end

  defp do_select_first([], skipped) do
    %{selected_model: nil, skipped: Enum.reverse(skipped)}
  end

  defp do_select_first([model_id | rest], skipped) do
    snap = snapshot(model_id)

    if snap.available do
      %{selected_model: model_id, skipped: Enum.reverse(skipped)}
    else
      do_select_first(rest, [{model_id, snap.reason || :unknown} | skipped])
    end
  end

  @doc """
  Reset sticky retry states for a new conversation turn.

  Clears the `consumed` flag on all sticky_retry entries, allowing
  them each one more attempt in the new turn.

  ## Examples

      iex> ModelAvailability.mark_sticky_retry("claude-3")
      :ok
      iex> ModelAvailability.consume_sticky_attempt("claude-3")
      :ok
      iex> ModelAvailability.reset_turn()
      :ok
      iex> ModelAvailability.snapshot("claude-3")
      %{available: true, reason: nil}
  """
  @spec reset_turn() :: :ok
  def reset_turn do
    GenServer.call(__MODULE__, :reset_turn)
  end

  @doc """
  Full reset - clear all health states.

  Removes all entries from the health table, making all models
  implicitly healthy again.

  ## Examples

      iex> ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok
      iex> ModelAvailability.reset_all()
      :ok
      iex> ModelAvailability.snapshot("gpt-4")
      %{available: true, reason: nil}
  """
  @spec reset_all() :: :ok
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  end

  @doc """
  Check if a model is marked as a last-resort fallback.

  Last-resort models are used when all preferred routing strategies fail.

  ## Examples

      iex> ModelAvailability.mark_as_last_resort("cheap-model", true)
      :ok
      iex> ModelAvailability.is_last_resort("cheap-model")
      true
  """
  @spec is_last_resort(String.t()) :: boolean()
  def is_last_resort(model_id) when is_binary(model_id) do
    case :ets.lookup(@last_resort_table, model_id) do
      [{^model_id, true}] -> true
      [] -> false
    end
  end

  @doc """
  Mark or unmark a model as a last-resort fallback.

  Last-resort models are tried when all preferred routing strategies
  return nil, preventing "no model available" errors.

  ## Examples

      iex> ModelAvailability.mark_as_last_resort("cheap-model", true)
      :ok
      iex> ModelAvailability.get_last_resort_models()
      ["cheap-model"]

      iex> ModelAvailability.mark_as_last_resort("cheap-model", false)
      :ok
      iex> ModelAvailability.get_last_resort_models()
      []
  """
  @spec mark_as_last_resort(String.t(), boolean()) :: :ok
  def mark_as_last_resort(model_id, value \\ true)
      when is_binary(model_id) and is_boolean(value) do
    GenServer.call(__MODULE__, {:mark_last_resort, model_id, value})
  end

  @doc """
  Get a list of all models marked as last-resort fallbacks.

  ## Examples

      iex> ModelAvailability.mark_as_last_resort("model-a", true)
      :ok
      iex> ModelAvailability.mark_as_last_resort("model-b", true)
      :ok
      iex> ModelAvailability.get_last_resort_models() |> Enum.sort()
      ["model-a", "model-b"]
  """
  @spec get_last_resort_models() :: [String.t()]
  def get_last_resort_models do
    @last_resort_table
    |> :ets.tab2list()
    |> Enum.map(fn {model_id, _true} -> model_id end)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create health table: {model_id, status, reason, consumed}
    health_table =
      :ets.new(@health_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Create last-resort table: {model_id, true}
    last_resort_table =
      :ets.new(@last_resort_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    Logger.info("ModelAvailability initialized")

    {:ok, %{health_table: health_table, last_resort_table: last_resort_table}}
  end

  @impl true
  def handle_call({:mark_terminal, model_id, reason}, _from, state) do
    :ets.insert(@health_table, {model_id, :terminal, reason, false})
    Logger.info("Model '#{model_id}' marked terminal: #{reason}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:mark_healthy, model_id}, _from, state) do
    :ets.delete(@health_table, model_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:mark_sticky_retry, model_id}, _from, state) do
    case :ets.lookup(@health_table, model_id) do
      [{^model_id, :terminal, _reason, _consumed}] ->
        # Don't downgrade terminal to sticky
        {:reply, :ok, state}

      [{^model_id, :sticky_retry, _reason, consumed}] ->
        # Preserve consumed flag if already sticky
        :ets.insert(@health_table, {model_id, :sticky_retry, :retry_once_per_turn, consumed})
        {:reply, :ok, state}

      [] ->
        # New sticky entry
        :ets.insert(@health_table, {model_id, :sticky_retry, :retry_once_per_turn, false})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:consume_sticky, model_id}, _from, state) do
    case :ets.lookup(@health_table, model_id) do
      [{^model_id, :sticky_retry, reason, _consumed}] ->
        :ets.insert(@health_table, {model_id, :sticky_retry, reason, true})
        {:reply, :ok, state}

      _ ->
        # Not sticky or doesn't exist, nothing to do
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:reset_turn, _from, state) do
    # Clear consumed flag on all sticky_retry entries
    :ets.select_replace(@health_table, [
      {{:"$1", :sticky_retry, :"$2", :"$3"}, [], [{{:"$1", :sticky_retry, :"$2", false}}]}
    ])

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset_all, _from, state) do
    :ets.delete_all_objects(@health_table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:mark_last_resort, model_id, true}, _from, state) do
    :ets.insert(@last_resort_table, {model_id, true})
    Logger.debug("Model '#{model_id}' marked as last-resort")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:mark_last_resort, model_id, false}, _from, state) do
    :ets.delete(@last_resort_table, model_id)
    Logger.debug("Model '#{model_id}' unmarked as last-resort")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("ModelAvailability received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
