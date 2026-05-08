defmodule CodePuppyControl.Plugins.LoopDetection.State do
  @moduledoc """
  ETS-backed GenServer for per-session loop detection state.

  Tracks a sliding window of tool call hashes per session and a set
  of hashes that have already triggered warnings (to avoid spam).

  ## Design

  - **ETS table** stores `{session_id, {history_queue, warned_set}}`
  - **History** is a fixed-size queue (default 50 entries)
  - **Warned set** tracks hashes that already triggered warnings
  - **Reads** go through GenServer for consistency (state changes)
  """

  use GenServer

  @table __MODULE__
  @default_history_size 50
  @default_warn_threshold 3
  @default_hard_threshold 5

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Starts the state GenServer. Called during plugin startup.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Initialize the ETS table if not running. Safe to call multiple times.
  """
  @spec init() :: :ok
  def init do
    case GenServer.start_link(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Check a hash against the session history and record it.

  Returns:
  - `{:block, count}` if the hard threshold is reached (call should be blocked)
  - `{:ok, count}` if the call is allowed (hash is recorded)
  """
  @spec check_and_record(String.t(), String.t()) :: {:block, pos_integer()} | {:ok, pos_integer()}
  def check_and_record(session_id, call_hash) do
    GenServer.call(__MODULE__, {:check_and_record, session_id, call_hash})
  end

  @doc """
  Check if a warning should be emitted for this hash.

  Returns `{:warn, count}` if the warn threshold is reached and
  we haven't already warned for this hash. Returns `:ok` otherwise.
  Marks the hash as warned to prevent repeat warnings.
  """
  @spec check_warn(String.t(), String.t()) :: {:warn, pos_integer()} | :ok
  def check_warn(session_id, call_hash) do
    GenServer.call(__MODULE__, {:check_warn, session_id, call_hash})
  end

  @doc """
  Reset loop detection state for a specific session or all sessions.
  """
  @spec reset(String.t() | nil) :: :ok
  def reset(nil), do: GenServer.call(__MODULE__, :reset_all)
  def reset(session_id), do: GenServer.call(__MODULE__, {:reset_session, session_id})

  @doc """
  Get loop detection statistics for debugging.
  """
  @spec get_stats(String.t() | nil) :: map()
  def get_stats(nil), do: GenServer.call(__MODULE__, :get_all_stats)
  def get_stats(session_id), do: GenServer.call(__MODULE__, {:get_session_stats, session_id})

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:check_and_record, session_id, call_hash}, _from, state) do
    hard_threshold = get_hard_threshold()
    {history, warned} = get_or_create_session(session_id)

    # Count occurrences of this hash in history
    count = Enum.count(history, &(&1 == call_hash))

    if count >= hard_threshold - 1 do
      # Block the call — don't add to history since we're blocking
      {:reply, {:block, count + 1}, state}
    else
      # Add to history (sliding window)
      new_history = add_to_history(history, call_hash)
      :ets.insert(@table, {session_id, {new_history, warned}})
      {:reply, {:ok, count + 1}, state}
    end
  end

  @impl true
  def handle_call({:check_warn, session_id, call_hash}, _from, state) do
    warn_threshold = get_warn_threshold()
    {history, warned} = get_or_create_session(session_id)

    if MapSet.member?(warned, call_hash) do
      # Already warned for this pattern
      {:reply, :ok, state}
    else
      count = Enum.count(history, &(&1 == call_hash))

      if count >= warn_threshold do
        # Mark as warned and return warning
        new_warned = MapSet.put(warned, call_hash)
        :ets.insert(@table, {session_id, {history, new_warned}})
        {:reply, {:warn, count}, state}
      else
        {:reply, :ok, state}
      end
    end
  end

  @impl true
  def handle_call({:reset_session, session_id}, _from, state) do
    :ets.delete(@table, session_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_session_stats, session_id}, _from, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, {history, warned}}] ->
        {:reply,
         %{
           session_id: session_id,
           history_size: length(history),
           warned_count: MapSet.size(warned),
           unique_hashes: history |> Enum.uniq() |> length()
         }, state}

      [] ->
        {:reply,
         %{
           session_id: session_id,
           history_size: 0,
           warned_count: 0,
           unique_hashes: 0
         }, state}
    end
  end

  @impl true
  def handle_call(:get_all_stats, _from, state) do
    all_entries = :ets.tab2list(@table)

    total_history =
      Enum.reduce(all_entries, 0, fn {_id, {history, _}}, acc ->
        acc + length(history)
      end)

    total_warned =
      Enum.reduce(all_entries, 0, fn {_id, {_, warned}}, acc ->
        acc + MapSet.size(warned)
      end)

    {:reply,
     %{
       total_sessions: length(all_entries),
       total_history_entries: total_history,
       total_warned_hashes: total_warned
     }, state}
  end

  # ── Private ─────────────────────────────────────────────────────

  defp get_or_create_session(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, {history, warned}}] ->
        {history, warned}

      [] ->
        {[], MapSet.new()}
    end
  end

  defp add_to_history(history, call_hash) do
    max_size = get_history_size()
    new_history = history ++ [call_hash]

    if length(new_history) > max_size do
      Enum.drop(new_history, length(new_history) - max_size)
    else
      new_history
    end
  end

  defp get_hard_threshold do
    case Application.get_env(:code_puppy_control, :loop_detection_stop) do
      nil -> @default_hard_threshold
      val when is_integer(val) and val > 0 -> val
      _ -> @default_hard_threshold
    end
  end

  defp get_warn_threshold do
    case Application.get_env(:code_puppy_control, :loop_detection_warn) do
      nil -> @default_warn_threshold
      val when is_integer(val) and val > 0 -> val
      _ -> @default_warn_threshold
    end
  end

  defp get_history_size do
    case Application.get_env(:code_puppy_control, :loop_detection_history_size) do
      nil -> @default_history_size
      val when is_integer(val) and val > 0 -> val
      _ -> @default_history_size
    end
  end
end
