defmodule CodePuppyControl.Runtime.EventBusTest do
  @moduledoc """
  Tests for EventBus — PubSub-based event distribution.

  Validates topic naming, subscribe/unsubscribe lifecycle, broadcast
  semantics (run, session, global), and event-type helpers.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.EventBus

  # (code_puppy-i1n) PubSub must be alive for subscribe/broadcast tests.
  setup_all do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(CodePuppyControl.PubSub)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Topic Helpers
  # ---------------------------------------------------------------------------

  describe "topic helpers" do
    test "session_topic/1 returns prefixed session topic" do
      assert EventBus.session_topic("s-123") == "session:s-123"
    end

    test "run_topic/1 returns prefixed run topic" do
      assert EventBus.run_topic("run-456") == "run:run-456"
    end

    test "global_topic/0 returns constant global topic" do
      assert EventBus.global_topic() == "global:events"
    end
  end

  # ---------------------------------------------------------------------------
  # Subscribe / Unsubscribe
  # ---------------------------------------------------------------------------

  describe "subscribe/unsubscribe" do
    test "subscribe_session returns :ok" do
      assert :ok = EventBus.subscribe_session("sub-test-1")
    end

    test "subscribe_run returns :ok" do
      assert :ok = EventBus.subscribe_run("sub-test-2")
    end

    test "subscribe_global returns :ok" do
      assert :ok = EventBus.subscribe_global()
    end

    test "unsubscribe_session returns :ok after subscribe" do
      :ok = EventBus.subscribe_session("sub-test-3")
      assert :ok = EventBus.unsubscribe_session("sub-test-3")
    end

    test "unsubscribe_run returns :ok after subscribe" do
      :ok = EventBus.subscribe_run("sub-test-4")
      assert :ok = EventBus.unsubscribe_run("sub-test-4")
    end

    test "unsubscribe_global returns :ok after subscribe" do
      :ok = EventBus.subscribe_global()
      assert :ok = EventBus.unsubscribe_global()
    end
  end

  # ---------------------------------------------------------------------------
  # Broadcast
  # ---------------------------------------------------------------------------

  describe "broadcast_event/2" do
    test "delivers event to run subscribers" do
      run_id = "broadcast-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      event = %{type: "text", run_id: run_id, content: "hello"}
      :ok = EventBus.broadcast_event(event, store: false)

      assert_receive {:event, ^event}, 1_000
    end

    test "delivers event to session subscribers" do
      session_id = "broadcast-session-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_session(session_id)

      event = %{type: "status", session_id: session_id, status: "running"}
      :ok = EventBus.broadcast_event(event, store: false)

      assert_receive {:event, ^event}, 1_000
    end

    test "delivers event to global subscribers" do
      :ok = EventBus.subscribe_global()

      event = %{type: "heartbeat", run_id: "any", metrics: %{}}
      :ok = EventBus.broadcast_event(event, store: false)

      assert_receive {:event, ^event}, 1_000
    end

    test "delivers event to all three topics when ids present" do
      run_id = "multi-run-#{System.unique_integer([:positive])}"
      session_id = "multi-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_run(run_id)
      EventBus.subscribe_session(session_id)
      EventBus.subscribe_global()

      event = %{type: "test", run_id: run_id, session_id: session_id}
      :ok = EventBus.broadcast_event(event, store: false)

      # Should receive 3 times (once per subscription)
      assert_receive {:event, ^event}, 1_000
      assert_receive {:event, ^event}, 1_000
      assert_receive {:event, ^event}, 1_000
    end

    @tag timeout: 5_000
    test "does not deliver to unsubscribed topics" do
      run_id = "unsub-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)
      :ok = EventBus.unsubscribe_run(run_id)

      event = %{type: "test", run_id: run_id}
      :ok = EventBus.broadcast_event(event, store: false)

      refute_receive {:event, _}, 200
    end
  end

  # ---------------------------------------------------------------------------
  # Event-type helpers
  # ---------------------------------------------------------------------------

  describe "broadcast_text/4" do
    test "emits text event with content" do
      run_id = "text-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      :ok = EventBus.broadcast_text(run_id, nil, "Hello world", store: false)

      assert_receive {:event, %{type: "text", content: "Hello world", run_id: ^run_id}}, 1_000
    end
  end

  describe "broadcast_status/4" do
    test "emits status event" do
      run_id = "status-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      :ok = EventBus.broadcast_status(run_id, nil, :running, store: false)

      assert_receive {:event, %{type: "status", status: "running", run_id: ^run_id}}, 1_000
    end
  end

  describe "broadcast_tool_result/5" do
    test "emits tool_result event" do
      run_id = "tool-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      :ok =
        EventBus.broadcast_tool_result(run_id, nil, "read_file", %{content: "data"}, store: false)

      assert_receive {:event, %{type: "tool_result", tool_name: "read_file", run_id: ^run_id}},
                     1_000
    end
  end

  describe "broadcast_tool_call/5" do
    test "emits tool_call event" do
      run_id = "call-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      :ok =
        EventBus.broadcast_tool_call(run_id, nil, "write_file", %{path: "/tmp/x"}, store: false)

      assert_receive {:event, %{type: "tool_call", tool_name: "write_file", run_id: ^run_id}},
                     1_000
    end
  end

  describe "broadcast_error/5" do
    test "emits error event" do
      run_id = "err-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      :ok = EventBus.broadcast_error(run_id, nil, "something broke", store: false)

      assert_receive {:event, %{type: "error", message: "something broke", run_id: ^run_id}},
                     1_000
    end
  end

  describe "broadcast_completed/4" do
    test "emits completed event" do
      run_id = "done-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      :ok = EventBus.broadcast_completed(run_id, nil, %{turns: 3}, store: false)

      assert_receive {:event, %{type: "completed", run_id: ^run_id}}, 1_000
    end
  end

  describe "broadcast_failed/5" do
    test "emits failed event" do
      run_id = "fail-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      :ok = EventBus.broadcast_failed(run_id, nil, "timeout", store: false)

      assert_receive {:event, %{type: "failed", error: "timeout", run_id: ^run_id}}, 1_000
    end
  end

  describe "broadcast_heartbeat/3" do
    test "emits heartbeat event (not stored)" do
      run_id = "hb-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      :ok = EventBus.broadcast_heartbeat(run_id, nil, %{uptime_s: 42})

      assert_receive {:event, %{type: "heartbeat", metrics: %{uptime_s: 42}}}, 1_000
    end
  end

  describe "broadcast_local_event/1" do
    test "broadcasts only to local node" do
      run_id = "local-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      event = %{type: "test", run_id: run_id}
      :ok = EventBus.broadcast_local_event(event)

      assert_receive {:event, ^event}, 1_000
    end
  end
end
