defmodule CodePuppyControl.SessionStoragePubSubTest do
  @moduledoc """
  Tests for SessionStorage PubSub integration.

  These tests verify per-session and global PubSub subscriptions,
  broadcast event shapes, and Store integration.

  Ported from abandoned branch `feature/d-ctj-1-session-storage` and
  rewritten for the fresh port architecture (no ETSCache, Store is
  the single source of truth for PubSub events).

  (code_puppy-ctj.1 fresh port)
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Repo
  alias CodePuppyControl.SessionStorage

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # These tests interact with the Store GenServer, which uses Ecto/Repo for
    # durable persistence.  Check out a sandbox connection in {:shared, self()}
    # mode so the Store's process (a separate GenServer) can also use the Repo.
    # Without this, the Store's Ecto calls fail with DBConnection.OwnershipError
    # because the pool is configured as Ecto.Adapters.SQL.Sandbox in :manual
    # mode.  (code_puppy-i1n)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    tmp =
      Path.join(System.tmp_dir!(), "session_pubsub_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      # Unsubscribe from any PubSub topics to avoid cross-test pollution
      try do
        SessionStorage.unsubscribe_all()
      catch
        _ -> :ok
      end
    end)

    {:ok, base_dir: tmp}
  end

  # ---------------------------------------------------------------------------
  # Per-session Subscribe / Unsubscribe
  # ---------------------------------------------------------------------------

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribes to a session-specific topic and receives events" do
      session_name = "test-subscribe"

      assert :ok = SessionStorage.subscribe(session_name)

      # Save session — should broadcast per-session event
      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "hi"}])

      assert_receive {:session_event, %{type: :saved, name: ^session_name}}, 500

      :ok = SessionStorage.unsubscribe(session_name)
    end

    test "unsubscribe removes subscription" do
      session_name = "test-unsubscribe"

      :ok = SessionStorage.subscribe(session_name)
      :ok = SessionStorage.unsubscribe(session_name)

      # After unsubscribe, should not receive events
      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "hi"}])

      refute_receive {:session_event, _}, 100
    end
  end

  # ---------------------------------------------------------------------------
  # Global Subscribe / Unsubscribe
  # ---------------------------------------------------------------------------

  describe "subscribe_all/0 and unsubscribe_all/0" do
    test "subscribes to global session events and receives legacy-shape events" do
      session_name = "global-test"

      assert :ok = SessionStorage.subscribe_all()

      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "hi"}])

      # Global topic uses legacy tuple shape
      assert_receive {:session_saved, ^session_name, _meta}, 500

      :ok = SessionStorage.unsubscribe_all()
    end

    test "unsubscribe_all stops receiving global events" do
      session_name = "global-unsub-test"

      :ok = SessionStorage.subscribe_all()
      :ok = SessionStorage.unsubscribe_all()

      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "hi"}])

      refute_receive {:session_saved, _, _}, 100
    end
  end

  # ---------------------------------------------------------------------------
  # Broadcast Event Shapes
  # ---------------------------------------------------------------------------

  describe "event shapes from Store operations" do
    test "save_session broadcasts per-session :saved event with payload" do
      session_name = "shape-save-test"

      :ok = SessionStorage.subscribe(session_name)

      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "test"}],
          total_tokens: 42
        )

      assert_receive {:session_event, event}, 500

      assert event.type == :saved
      assert event.name == session_name
      assert event.timestamp != nil
      assert event.payload.total_tokens == 42
    end

    test "delete_session broadcasts per-session :deleted event" do
      session_name = "shape-delete-test"

      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "test"}])

      :ok = SessionStorage.subscribe(session_name)
      :ok = SessionStorage.delete_session(session_name)

      assert_receive {:session_event, %{type: :deleted, name: ^session_name}}, 500
    end

    test "update_session broadcasts per-session :updated event" do
      session_name = "shape-update-test"

      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "test"}])

      :ok = SessionStorage.subscribe(session_name)

      {:ok, _} =
        SessionStorage.update_session(session_name, total_tokens: 999)

      assert_receive {:session_event, %{type: :updated, name: ^session_name}}, 500
    end

    test "cleanup_sessions broadcasts per-session :deleted events" do
      # Create 3 sessions
      for i <- 1..3 do
        {:ok, _} =
          SessionStorage.save_session("cleanup-test-#{i}", [
            %{"role" => "user", "content" => "#{i}"}
          ])
      end

      # Subscribe to one of the sessions that will be cleaned up
      :ok = SessionStorage.subscribe("cleanup-test-1")

      # Keep only 1 session (deletes the oldest 2)
      {:ok, _deleted} = SessionStorage.cleanup_sessions(1)

      # The per-session event should fire for each deleted session
      assert_receive {:session_event, %{type: :deleted, name: "cleanup-test-1"}}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Global Event Shapes (legacy)
  # ---------------------------------------------------------------------------

  describe "global event shapes (legacy tuples)" do
    test "save_session broadcasts {:session_saved, name, meta} on global topic" do
      session_name = "global-save-test"

      :ok = SessionStorage.subscribe_all()

      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "test"}])

      assert_receive {:session_saved, ^session_name, _meta}, 500
    end

    test "delete_session broadcasts {:session_deleted, name} on global topic" do
      session_name = "global-delete-test"

      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "test"}])

      :ok = SessionStorage.subscribe_all()
      :ok = SessionStorage.delete_session(session_name)

      assert_receive {:session_deleted, ^session_name}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Event Type Enumeration
  # ---------------------------------------------------------------------------

  describe "all expected event types fire" do
    test ":saved, :updated, :deleted on per-session topic" do
      session_name = "event-types-test"

      :ok = SessionStorage.subscribe(session_name)

      # :saved
      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "test"}])

      assert_receive {:session_event, %{type: :saved}}, 500

      # :updated
      {:ok, _} =
        SessionStorage.update_session(session_name, total_tokens: 42)

      assert_receive {:session_event, %{type: :updated}}, 500

      # :deleted
      :ok = SessionStorage.delete_session(session_name)
      assert_receive {:session_event, %{type: :deleted}}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Async Operations + PubSub
  # ---------------------------------------------------------------------------

  describe "save_session_async/3 with PubSub" do
    test "async save triggers per-session broadcast" do
      session_name = "async-pubsub-test"

      :ok = SessionStorage.subscribe(session_name)

      :ok =
        SessionStorage.save_session_async(session_name, [
          %{"role" => "user", "content" => "async"}
        ])

      # Wait for the background Task to complete and event to fire
      assert_receive {:session_event, %{type: :saved, name: ^session_name}}, 1000
    end

    test "async save triggers global broadcast" do
      session_name = "async-global-test"

      :ok = SessionStorage.subscribe_all()

      :ok =
        SessionStorage.save_session_async(session_name, [
          %{"role" => "user", "content" => "async"}
        ])

      assert_receive {:session_saved, ^session_name, _meta}, 1000
    end
  end

  # ---------------------------------------------------------------------------
  # Dual-subscription (per-session + global simultaneously)
  # ---------------------------------------------------------------------------

  describe "dual subscription" do
    test "process receives both per-session and global events" do
      session_name = "dual-sub-test"

      :ok = SessionStorage.subscribe(session_name)
      :ok = SessionStorage.subscribe_all()

      {:ok, _} =
        SessionStorage.save_session(session_name, [%{"role" => "user", "content" => "dual"}])

      # Should receive both event shapes
      assert_receive {:session_event, %{type: :saved, name: ^session_name}}, 500
      assert_receive {:session_saved, ^session_name, _meta}, 500
    end
  end
end
