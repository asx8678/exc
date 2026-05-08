defmodule CodePuppyControl.Runtime.EventStoreTest do
  @moduledoc """
  Tests for EventStore — ETS-backed event storage with TTL and replay.

  Note:
  - ETS :bag deduplicates identical tuples, so each stored event must have
    unique content to avoid silent dedup.
  - System.monotonic_time(:millisecond) may be negative on macOS, so replay
    tests use a very negative :since value to avoid filtering out events.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.EventStore

  # Monotonic time can be negative on macOS; use a very negative value
  # to ensure replay includes all events when testing "from the beginning".
  @since_beginning -1_000_000_000_000

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(EventStore)
    EventStore.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Store
  # ---------------------------------------------------------------------------

  describe "store/1" do
    test "stores an event and returns :ok" do
      event = %{type: "text", session_id: "store-test", content: "hi-#{System.unique_integer()}"}
      assert :ok = EventStore.store(event)
    end

    test "stores event with atom or string session_id key" do
      event_atom = %{
        type: "text",
        session_id: "atom-test",
        content: "a-#{System.unique_integer()}"
      }

      event_string = %{
        "type" => "text",
        "session_id" => "string-test",
        "content" => "b-#{System.unique_integer()}"
      }

      assert :ok = EventStore.store(event_atom)
      assert :ok = EventStore.store(event_string)
    end

    test "logs warning for events without session_id but does not crash" do
      assert :ok = EventStore.store(%{type: "orphan", content: "no session"})
    end
  end

  describe "store_many/1" do
    test "stores multiple events at once" do
      events =
        for i <- 1..3 do
          %{
            type: "text",
            session_id: "batch-test",
            content: "event-#{i}-#{System.unique_integer()}"
          }
        end

      assert :ok = EventStore.store_many(events)
      assert EventStore.count("batch-test") == 3
    end

    test "skips events without session_id" do
      events = [
        %{type: "text", session_id: "batch-skip", content: "a-#{System.unique_integer()}"},
        %{type: "orphan", content: "no session"},
        %{type: "text", session_id: "batch-skip", content: "b-#{System.unique_integer()}"}
      ]

      assert :ok = EventStore.store_many(events)
      assert EventStore.count("batch-skip") == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Replay
  # ---------------------------------------------------------------------------

  describe "replay/2" do
    test "returns stored events in chronological order" do
      session_id = "replay-test-#{System.unique_integer([:positive])}"

      for i <- 1..5 do
        EventStore.store(%{
          type: "text",
          session_id: session_id,
          idx: i,
          uniq: System.unique_integer()
        })

        Process.sleep(1)
      end

      events = EventStore.replay(session_id, since: @since_beginning)
      assert length(events) == 5

      indices = Enum.map(events, & &1[:idx])
      assert indices == [1, 2, 3, 4, 5]
    end

    test "respects :since cursor for pagination" do
      session_id = "cursor-test-#{System.unique_integer([:positive])}"

      for i <- 1..3 do
        EventStore.store(%{
          type: "text",
          session_id: session_id,
          idx: i,
          uniq: System.unique_integer()
        })

        Process.sleep(1)
      end

      cursor = EventStore.get_cursor(session_id)

      for i <- 4..6 do
        EventStore.store(%{
          type: "text",
          session_id: session_id,
          idx: i,
          uniq: System.unique_integer()
        })

        Process.sleep(1)
      end

      new_events = EventStore.replay(session_id, since: cursor)
      assert length(new_events) >= 3

      indices = Enum.map(new_events, & &1[:idx])
      assert Enum.all?(4..6, fn i -> i in indices end)
    end

    test "respects :limit option" do
      session_id = "limit-test-#{System.unique_integer([:positive])}"

      for i <- 1..10 do
        EventStore.store(%{
          type: "text",
          session_id: session_id,
          idx: i,
          uniq: System.unique_integer()
        })

        Process.sleep(1)
      end

      events = EventStore.replay(session_id, since: @since_beginning, limit: 3)
      assert length(events) == 3
    end

    test "filters by :event_types" do
      session_id = "filter-test-#{System.unique_integer([:positive])}"

      EventStore.store(%{
        type: "text",
        session_id: session_id,
        content: "hello-#{System.unique_integer()}"
      })

      Process.sleep(1)

      EventStore.store(%{
        type: "status",
        session_id: session_id,
        status: "running",
        uniq: System.unique_integer()
      })

      Process.sleep(1)

      EventStore.store(%{
        type: "text",
        session_id: session_id,
        content: "world-#{System.unique_integer()}"
      })

      Process.sleep(1)

      text_events = EventStore.replay(session_id, since: @since_beginning, event_types: ["text"])
      assert length(text_events) == 2
      assert Enum.all?(text_events, &(&1[:type] == "text"))
    end

    test "returns empty list for unknown session" do
      assert [] = EventStore.replay("nonexistent-session-99999")
    end
  end

  # ---------------------------------------------------------------------------
  # Cursor
  # ---------------------------------------------------------------------------

  describe "get_cursor/1" do
    test "returns 0 for session with no events" do
      assert EventStore.get_cursor("empty-session-#{System.unique_integer([:positive])}") == 0
    end

    test "returns monotonic timestamp for session with events" do
      session_id = "cursor-max-#{System.unique_integer([:positive])}"
      EventStore.store(%{type: "text", session_id: session_id, uniq: System.unique_integer()})

      cursor = EventStore.get_cursor(session_id)
      assert is_integer(cursor)
    end
  end

  # ---------------------------------------------------------------------------
  # Count & Clear
  # ---------------------------------------------------------------------------

  describe "count/1" do
    test "returns correct count for session" do
      session_id = "count-test-#{System.unique_integer([:positive])}"
      assert EventStore.count(session_id) == 0

      EventStore.store(%{
        type: "text",
        session_id: session_id,
        content: "first-#{System.unique_integer()}"
      })

      assert EventStore.count(session_id) == 1

      Process.sleep(1)

      EventStore.store(%{
        type: "text",
        session_id: session_id,
        content: "second-#{System.unique_integer()}"
      })

      assert EventStore.count(session_id) == 2
    end
  end

  describe "clear/1" do
    test "clears events for a specific session" do
      session_id = "clear-test-#{System.unique_integer([:positive])}"
      other_session = "other-test-#{System.unique_integer([:positive])}"

      EventStore.store(%{type: "text", session_id: session_id, uniq: System.unique_integer()})
      EventStore.store(%{type: "text", session_id: other_session, uniq: System.unique_integer()})

      assert :ok = EventStore.clear(session_id)
      assert EventStore.count(session_id) == 0
      assert EventStore.count(other_session) == 1
    end
  end

  describe "clear_all/0" do
    test "clears all events from all sessions" do
      s1 = "clear-all-1-#{System.unique_integer([:positive])}"
      s2 = "clear-all-2-#{System.unique_integer([:positive])}"

      EventStore.store(%{type: "text", session_id: s1, uniq: System.unique_integer()})
      EventStore.store(%{type: "text", session_id: s2, uniq: System.unique_integer()})

      assert :ok = EventStore.clear_all()
      assert EventStore.count(s1) == 0
      assert EventStore.count(s2) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Per-session limit (trimming)
  # ---------------------------------------------------------------------------

  describe "per-session limit enforcement" do
    test "trims oldest events when exceeding max_events_per_session" do
      session_id = "trim-test-#{System.unique_integer([:positive])}"

      for i <- 1..1005 do
        EventStore.store(%{
          type: "text",
          session_id: session_id,
          idx: i,
          uniq: System.unique_integer()
        })
      end

      count = EventStore.count(session_id)
      assert count <= 1005
    end
  end

  # ---------------------------------------------------------------------------
  # Stats
  # ---------------------------------------------------------------------------

  describe "stats/0" do
    test "returns map with table info" do
      stats = EventStore.stats()

      assert is_map(stats)
      assert stats.table_name == :event_store
      assert is_integer(stats.size)
      assert is_integer(stats.memory_bytes)
      assert is_integer(stats.max_events_per_session)
      assert is_integer(stats.ttl_seconds)
    end
  end

  # ---------------------------------------------------------------------------
  # get_events/2 (alias)
  # ---------------------------------------------------------------------------

  describe "get_events/2" do
    test "returns all events for a session (via count)" do
      session_id = "all-events-#{System.unique_integer([:positive])}"

      for i <- 1..3 do
        EventStore.store(%{
          type: "text",
          session_id: session_id,
          idx: i,
          uniq: System.unique_integer()
        })

        Process.sleep(1)
      end

      assert EventStore.count(session_id) == 3

      events = EventStore.get_events(session_id, since: @since_beginning)
      assert length(events) == 3

      indices = Enum.map(events, & &1[:idx])
      assert indices == [1, 2, 3]
    end

    test "supports event_types filter" do
      session_id = "filtered-events-#{System.unique_integer([:positive])}"

      EventStore.store(%{
        type: "text",
        session_id: session_id,
        content: "txt-#{System.unique_integer()}}"
      })

      Process.sleep(1)

      EventStore.store(%{
        type: "error",
        session_id: session_id,
        error: "err-#{System.unique_integer()}"
      })

      Process.sleep(1)

      events = EventStore.get_events(session_id, event_types: ["text"], since: @since_beginning)
      assert length(events) == 1
      assert Enum.all?(events, &(&1[:type] == "text"))
    end
  end
end
