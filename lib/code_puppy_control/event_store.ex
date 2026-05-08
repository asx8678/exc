defmodule CodePuppyControl.EventStore do
  @moduledoc """
  Stores recent events for replay to late-joining subscribers.

  Uses ETS for fast, concurrent reads. Implements TTL-based cleanup
  and per-session event limits to prevent unbounded memory growth.

  ## Features

  - Bag-type ETS table for storing multiple events per session
  - Per-session event limits (default 1000)
  - TTL-based expiration (default 1 hour)
  - Automatic cleanup every minute
  - Cursor-based replay for pagination

  ## Usage

      # Store an event
      EventStore.store(%{type: "text", session_id: "session-123", ...})

      # Replay events for a session
      events = EventStore.replay("session-123", since: cursor, limit: 100)

      # Get the current cursor (latest timestamp)
      cursor = EventStore.get_cursor("session-123")
  """

  use GenServer

  require Logger

  @table :event_store
  @max_events_per_session 1000
  @ttl_seconds 3600
  @cleanup_interval_ms 60_000

  # ETS row format: {session_id, timestamp, event}
  # Bag table allows multiple entries with same session_id

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the EventStore GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores an event in the event store.

  Events are stored with a monotonic timestamp and associated with their session.
  Automatically trims old events when the per-session limit is exceeded.
  """
  @spec store(map()) :: :ok
  def store(event) do
    # Get session_id from atom or string key
    session_id = event[:session_id] || event["session_id"]

    if session_id do
      timestamp = System.monotonic_time(:millisecond)
      :ets.insert(@table, {session_id, timestamp, event})
      trim_old_events(session_id)
      :ok
    else
      Logger.warning("EventStore.store: event missing session_id: #{inspect(event)}")
      :ok
    end
  end

  @doc """
  Stores multiple events efficiently.
  """
  @spec store_many(list(map())) :: :ok
  def store_many(events) when is_list(events) do
    entries =
      for event <- events,
          session_id = event[:session_id] || event["session_id"],
          session_id != nil do
        timestamp = System.monotonic_time(:millisecond)
        {session_id, timestamp, event}
      end

    if entries != [] do
      :ets.insert(@table, entries)

      # Trim for each affected session
      entries
      |> Enum.map(fn {session_id, _, _} -> session_id end)
      |> Enum.uniq()
      |> Enum.each(&trim_old_events/1)
    end

    :ok
  end

  @doc """
  Replays events for a session.

  ## Options

    * `:since` - Only return events after this timestamp (cursor from get_cursor/1)
    * `:limit` - Maximum number of events to return (default 1000)
    * `:event_types` - Filter to specific event types (list of strings)

  Returns events in chronological order (oldest first).
  """
  @spec replay(String.t(), keyword()) :: list(map())
  def replay(session_id, opts \\ []) do
    since = Keyword.get(opts, :since, nil)
    limit = Keyword.get(opts, :limit, @max_events_per_session)
    event_types = Keyword.get(opts, :event_types)

    session_id
    |> lookup_events()
    |> maybe_filter_by_timestamp(since)
    |> maybe_filter_types(event_types)
    |> sort_by_timestamp()
    |> take_limit(limit)
    |> extract_events()
  end

  @doc """
  Gets the replay cursor for a session.

  Returns the highest timestamp for this session, or 0 if no events.
  Use this value as `:since` in the next replay call.
  """
  @spec get_cursor(String.t()) :: non_neg_integer()
  def get_cursor(session_id) do
    case lookup_events(session_id) do
      [] -> 0
      events -> events |> Enum.map(fn {_, ts, _} -> ts end) |> Enum.max()
    end
  end

  @doc """
  Gets all events for a session without pagination.

  ## Options

    * `:event_types` - Filter to specific event types
  """
  @spec get_events(String.t(), keyword()) :: list(map())
  def get_events(session_id, opts \\ []) do
    replay(session_id, Keyword.put(opts, :limit, @max_events_per_session))
  end

  @doc """
  Gets the count of stored events for a session.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(session_id) do
    :ets.select_count(@table, [{{session_id, :_, :_}, [], [true]}])
  end

  @doc """
  Clears all events for a specific session.
  """
  @spec clear(String.t()) :: :ok
  def clear(session_id) do
    :ets.select_delete(@table, [{{session_id, :_, :_}, [], [true]}])
    :ok
  end

  @doc """
  Clears all events from the store (use with caution).
  """
  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Returns statistics about the event store.
  """
  @spec stats() :: map()
  def stats do
    info = :ets.info(@table)

    %{
      table_name: @table,
      size: info[:size] || 0,
      memory_bytes: info[:memory] || 0,
      max_events_per_session: @max_events_per_session,
      ttl_seconds: @ttl_seconds
    }
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create public bag table for concurrent reads, with read_concurrency
    # Bag allows multiple entries with same key (session_id)
    table =
      :ets.new(@table, [
        :named_table,
        :bag,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("EventStore initialized with table #{inspect(@table)}")

    {:ok, %{table: table, cleanup_timer: nil}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Remove events older than TTL
    cutoff = System.monotonic_time(:millisecond) - @ttl_seconds * 1000
    deleted = :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])

    if deleted > 0 do
      Logger.debug("EventStore cleanup removed #{deleted} stale events")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("EventStore received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp lookup_events(session_id) do
    :ets.lookup(@table, session_id)
  end

  defp maybe_filter_by_timestamp(events, nil), do: events

  defp maybe_filter_by_timestamp(events, since) do
    Enum.filter(events, fn {_, ts, _} -> ts > since end)
  end

  defp maybe_filter_types(events, nil), do: events
  defp maybe_filter_types(events, []), do: events

  defp maybe_filter_types(events, types) when is_list(types) do
    type_set = MapSet.new(types)

    Enum.filter(events, fn {_, _, event} ->
      # Check both legacy :type/"type" and structured "event_type" fields
      event_type = event[:type] || event["type"] || event["event_type"]
      MapSet.member?(type_set, event_type)
    end)
  end

  defp sort_by_timestamp(events) do
    Enum.sort_by(events, fn {_, ts, _} -> ts end, :asc)
  end

  defp take_limit(events, limit) do
    Enum.take(events, limit)
  end

  defp extract_events(events) do
    Enum.map(events, fn {_, _, event} -> event end)
  end

  defp trim_old_events(session_id) do
    events = :ets.lookup(@table, session_id)
    count = length(events)

    if count > @max_events_per_session do
      # Sort by timestamp, oldest first
      sorted = Enum.sort_by(events, fn {_, ts, _} -> ts end, :asc)

      # Calculate how many to delete
      to_delete_count = count - @max_events_per_session

      # Delete oldest entries
      to_delete = Enum.take(sorted, to_delete_count)

      Enum.each(to_delete, fn entry ->
        :ets.delete_object(@table, entry)
      end)

      Logger.debug("EventStore trimmed #{to_delete_count} old events for session #{session_id}")
    end

    :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
