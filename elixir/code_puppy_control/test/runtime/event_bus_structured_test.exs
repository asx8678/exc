defmodule CodePuppyControl.Runtime.EventBusStructuredTest do
  @moduledoc """
  Tests for EventBus structured messaging wire events and commands.

  Validates broadcast_message/4, broadcast_wire_event/2, and broadcast_command/4
  helpers for structured Agent→UI and UI→Agent messaging.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.{EventBus, EventStore}
  alias CodePuppyControl.Messaging.{Messages, Commands}

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(EventStore)
    EventStore.clear_all()
    :ok
  end

  # ===========================================================================
  # broadcast_message/4
  # ===========================================================================

  describe "broadcast_message/4" do
    test "happy path with text_message delivered as valid WireEvent envelope" do
      run_id = "msg-run-#{System.unique_integer([:positive])}"
      session_id = "msg-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_run(run_id)
      EventBus.subscribe_session(session_id)

      {:ok, internal_msg} =
        Messages.text_message(%{
          "level" => "info",
          "text" => "Hello from structured messaging"
        })

      :ok = EventBus.broadcast_message(run_id, session_id, internal_msg, store: false)

      # Should receive the wire envelope (not the internal message)
      assert_receive {:event, wire_event}, 1_000

      # Verify it's a valid wire envelope
      assert wire_event["event_type"] == "system"
      assert wire_event["run_id"] == run_id
      assert wire_event["session_id"] == session_id
      assert is_integer(wire_event["timestamp"])
      assert is_map(wire_event["payload"])
      assert wire_event["payload"]["text"] == "Hello from structured messaging"
    end

    test "EventStore replay returns wire envelope when session_id is present" do
      session_id = "replay-session-#{System.unique_integer([:positive])}"
      run_id = "replay-run-#{System.unique_integer([:positive])}"

      {:ok, internal_msg} =
        Messages.text_message(%{
          "level" => "info",
          "text" => "Stored message"
        })

      # Store the message (default behavior)
      :ok = EventBus.broadcast_message(run_id, session_id, internal_msg)

      # Replay from EventStore
      events = EventStore.replay(session_id)

      assert length(events) == 1
      wire_event = List.first(events)

      # Should be a wire envelope, not internal message
      assert wire_event["event_type"] == "system"
      assert wire_event["run_id"] == run_id
      assert wire_event["session_id"] == session_id
      assert wire_event["payload"]["text"] == "Stored message"
    end

    test "store: false does not store" do
      session_id = "no-store-session-#{System.unique_integer([:positive])}"
      run_id = "no-store-run-#{System.unique_integer([:positive])}"

      {:ok, internal_msg} =
        Messages.text_message(%{
          "level" => "info",
          "text" => "Not stored"
        })

      :ok = EventBus.broadcast_message(run_id, session_id, internal_msg, store: false)

      # Should not be in EventStore
      events = EventStore.replay(session_id)
      assert events == []
    end

    test "invalid internal message returns error and no broadcast" do
      session_id = "error-session-#{System.unique_integer([:positive])}"
      run_id = "error-run-#{System.unique_integer([:positive])}"

      EventBus.subscribe_run(run_id)

      # Missing required fields
      # missing "text" and "category"
      invalid_msg = %{"level" => "info"}

      assert {:error, :missing_category} =
               EventBus.broadcast_message(run_id, session_id, invalid_msg)

      # Should not receive any event
      refute_receive {:event, _}, 200

      # Should not be stored
      events = EventStore.replay(session_id)
      assert events == []
    end

    test "non-map input returns error and no broadcast" do
      run_id = "nonmap-run"
      session_id = "nonmap-session"

      EventBus.subscribe_run(run_id)

      assert {:error, {:not_a_map, "not a map"}} =
               EventBus.broadcast_message(run_id, session_id, "not a map")

      assert {:error, {:not_a_map, nil}} =
               EventBus.broadcast_message(run_id, session_id, nil)

      assert {:error, {:not_a_map, [1, 2]}} =
               EventBus.broadcast_message(run_id, session_id, [1, 2])

      # Should not receive any event
      refute_receive {:event, _}, 200
    end

    test "agent_response_message delivered as valid WireEvent envelope" do
      run_id = "agent-run-#{System.unique_integer([:positive])}"
      session_id = "agent-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      {:ok, internal_msg} =
        Messages.agent_response_message(%{
          "content" => "Agent response content",
          "is_markdown" => false,
          "was_streamed" => false,
          "streamed_line_count" => 0
        })

      :ok = EventBus.broadcast_message(run_id, session_id, internal_msg, store: false)

      assert_receive {:event, wire_event}, 1_000
      assert wire_event["event_type"] == "agent"
      assert wire_event["payload"]["content"] == "Agent response content"
      assert wire_event["payload"]["is_markdown"] == false
      assert wire_event["payload"]["was_streamed"] == false
      assert wire_event["payload"]["streamed_line_count"] == 0
    end
  end

  # ===========================================================================
  # broadcast_wire_event/2
  # ===========================================================================

  describe "broadcast_wire_event/2" do
    test "valid wire event delivered and replayable" do
      session_id = "wire-session-#{System.unique_integer([:positive])}"
      run_id = "wire-run-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      wire_event = %{
        "event_type" => "system",
        "run_id" => run_id,
        "session_id" => session_id,
        "timestamp" => 1_717_000_000_000,
        "payload" => %{
          "id" => "msg-1",
          "category" => "system",
          "level" => "info",
          "text" => "Wire event test",
          "is_markdown" => false
        }
      }

      :ok = EventBus.broadcast_wire_event(wire_event, store: false)

      assert_receive {:event, ^wire_event}, 1_000

      # Store and replay
      :ok = EventBus.broadcast_wire_event(wire_event)
      events = EventStore.replay(session_id)
      assert length(events) == 1
      assert List.first(events) == wire_event
    end

    test "invalid wire envelope returns error and no broadcast" do
      session_id = "invalid-wire-session-#{System.unique_integer([:positive])}"
      run_id = "invalid-wire-run-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      # Missing required field
      invalid_wire = %{
        "event_type" => "system",
        "run_id" => run_id,
        "session_id" => session_id,
        "timestamp" => 1_717_000_000_000
        # Missing "payload"
      }

      assert {:error, {:missing_field, "payload"}} = EventBus.broadcast_wire_event(invalid_wire)

      # Should not receive any event
      refute_receive {:event, _}, 200

      # Should not be stored
      events = EventStore.replay(session_id)
      assert events == []
    end

    test "invalid event_type returns error" do
      wire_event = %{
        "event_type" => "bogus_category",
        "run_id" => "run-1",
        "session_id" => "session-1",
        "timestamp" => 1_717_000_000_000,
        "payload" => %{"id" => "msg-1"}
      }

      assert {:error, {:invalid_category, "bogus_category"}} =
               EventBus.broadcast_wire_event(wire_event)
    end
  end

  # ===========================================================================
  # broadcast_command/4
  # ===========================================================================

  describe "broadcast_command/4" do
    test "CancelAgentCommand struct broadcast as type 'command'" do
      run_id = "cancel-run-#{System.unique_integer([:positive])}"
      session_id = "cancel-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      cmd = Commands.cancel_agent(reason: "user requested")

      :ok = EventBus.broadcast_command(run_id, session_id, cmd, store: false)

      assert_receive {:event, event}, 1_000

      # Should be a legacy-compatible event map
      assert event[:type] == "command"
      assert event[:run_id] == run_id
      assert event[:session_id] == session_id
      assert is_map(event[:command])
      assert event[:command]["command_type"] == "cancel_agent"
      assert event[:command]["reason"] == "user requested"
      # Legacy timestamp is DateTime, not integer
      assert %DateTime{} = event[:timestamp]
    end

    test "command wire map broadcast as type 'command'" do
      run_id = "cmd-wire-run-#{System.unique_integer([:positive])}"
      session_id = "cmd-wire-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      wire_map = %{
        "command_type" => "cancel_agent",
        "reason" => "test reason"
      }

      :ok = EventBus.broadcast_command(run_id, session_id, wire_map, store: false)

      assert_receive {:event, event}, 1_000

      assert event[:type] == "command"
      assert event[:command]["command_type"] == "cancel_agent"
      assert event[:command]["reason"] == "test reason"
    end

    test "invalid command wire map returns error and no broadcast" do
      run_id = "invalid-cmd-run-#{System.unique_integer([:positive])}"
      session_id = "invalid-cmd-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      # Unknown command_type
      invalid_wire = %{
        "command_type" => "unknown_command",
        "reason" => "test"
      }

      assert {:error, :unknown_command_type} =
               EventBus.broadcast_command(run_id, session_id, invalid_wire)

      # Should not receive any event
      refute_receive {:event, _}, 200

      # Should not be stored in EventStore
      events = EventStore.replay(session_id)
      assert events == []
    end

    test "valid command_type with extra fields returns error and no broadcast" do
      run_id = "extra-cmd-run-#{System.unique_integer([:positive])}"
      session_id = "extra-cmd-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      invalid_wire = %{
        "command_type" => "cancel_agent",
        "reason" => "fine",
        "unexpected" => "not allowed"
      }

      assert {:error, :extra_fields_not_allowed} =
               EventBus.broadcast_command(run_id, session_id, invalid_wire)

      refute_receive {:event, _}, 200

      events = EventStore.replay(session_id)
      assert events == []
    end

    test "arbitrary map with :command_type atom key is rejected" do
      run_id = "arb-cmd-run-#{System.unique_integer([:positive])}"
      session_id = "arb-cmd-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      # A plain map with atom :command_type — NOT a valid Commands struct
      fake_cmd = %{command_type: :cancel_agent, id: "fake", timestamp: 0, reason: "nope"}

      assert {:error, _reason} = EventBus.broadcast_command(run_id, session_id, fake_cmd)

      refute_receive {:event, _}, 200

      events = EventStore.replay(session_id)
      assert events == []
    end

    test "non-map, non-struct input returns error" do
      run_id = "bad-input-run"
      session_id = "bad-input-session"

      assert {:error, {:invalid_command_input, "not a command"}} =
               EventBus.broadcast_command(run_id, session_id, "not a command")

      assert {:error, {:invalid_command_input, nil}} =
               EventBus.broadcast_command(run_id, session_id, nil)
    end

    test "EventStore replay includes command events" do
      session_id = "cmd-replay-session-#{System.unique_integer([:positive])}"
      run_id = "cmd-replay-run-#{System.unique_integer([:positive])}"

      cmd = Commands.cancel_agent(reason: "replay test")
      :ok = EventBus.broadcast_command(run_id, session_id, cmd)

      events = EventStore.replay(session_id)
      assert length(events) == 1

      event = List.first(events)
      assert event[:type] == "command"
      assert event[:command]["command_type"] == "cancel_agent"
    end

    test "store: false does not store command" do
      session_id = "cmd-no-store-session-#{System.unique_integer([:positive])}"
      run_id = "cmd-no-store-run-#{System.unique_integer([:positive])}"

      cmd = Commands.cancel_agent(reason: "no store test")
      :ok = EventBus.broadcast_command(run_id, session_id, cmd, store: false)

      events = EventStore.replay(session_id)
      assert events == []
    end

    test "at least one response command wire map broadcasts correctly" do
      run_id = "response-cmd-run-#{System.unique_integer([:positive])}"
      session_id = "response-cmd-session-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      # UserInputResponse wire map
      wire_map = %{
        "command_type" => "user_input_response",
        "prompt_id" => "prompt-123",
        "value" => "user input"
      }

      :ok = EventBus.broadcast_command(run_id, session_id, wire_map, store: false)

      assert_receive {:event, event}, 1_000

      assert event[:type] == "command"
      assert event[:command]["command_type"] == "user_input_response"
      assert event[:command]["prompt_id"] == "prompt-123"
      assert event[:command]["value"] == "user input"
    end
  end

  # ===========================================================================
  # EventStore event_types filtering
  # ===========================================================================

  describe "EventStore event_types filtering" do
    test "includes both legacy 'type' and structured 'event_type'" do
      session_id = "filter-types-#{System.unique_integer([:positive])}"
      run_id = "filter-types-run-#{System.unique_integer([:positive])}"

      # Store a legacy event with :type
      legacy_event = %{
        type: "text",
        run_id: run_id,
        session_id: session_id,
        content: "legacy event"
      }

      :ok = EventStore.store(legacy_event)

      # Store a structured wire event with "event_type"
      wire_event = %{
        "event_type" => "agent",
        "run_id" => run_id,
        "session_id" => session_id,
        "timestamp" => 1_717_000_000_000,
        "payload" => %{
          "id" => "msg-1",
          "category" => "agent",
          "content" => "structured event"
        }
      }

      :ok = EventStore.store(wire_event)

      # Filter by "text" should include legacy event
      text_events = EventStore.replay(session_id, event_types: ["text"])
      assert length(text_events) == 1
      assert List.first(text_events)[:type] == "text"

      # Filter by "agent" should include structured event
      agent_events = EventStore.replay(session_id, event_types: ["agent"])
      assert length(agent_events) == 1
      assert List.first(agent_events)["event_type"] == "agent"

      # Filter by both
      both_events = EventStore.replay(session_id, event_types: ["text", "agent"])
      assert length(both_events) == 2
    end
  end

  # ===========================================================================
  # EventsChannel compatibility
  # ===========================================================================

  describe "EventsChannel compatibility" do
    test "string-keyed wire maps push unchanged through channel" do
      # This test verifies that string-keyed wire maps (as produced by
      # broadcast_message/4 and broadcast_wire_event/2) are compatible
      # with the existing EventsChannel that expects map events.

      session_id = "channel-wire-#{System.unique_integer([:positive])}"
      run_id = "channel-wire-run-#{System.unique_integer([:positive])}"

      EventBus.subscribe_session(session_id)

      wire_event = %{
        "event_type" => "system",
        "run_id" => run_id,
        "session_id" => session_id,
        "timestamp" => 1_717_000_000_000,
        "payload" => %{
          "id" => "msg-1",
          "category" => "system",
          "level" => "info",
          "text" => "Channel test",
          "is_markdown" => false
        }
      }

      :ok = EventBus.broadcast_wire_event(wire_event, store: false)

      # Should receive the exact wire_event map
      assert_receive {:event, ^wire_event}, 1_000

      # The EventsChannel's handle_info({:event, event}, socket) pushes
      # the event directly to the client, so string-keyed maps work fine
    end
  end
end
