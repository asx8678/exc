defmodule CodePuppyControl.Agent.EventsTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.Events

  @run_id "run-123"
  @session_id "sess-456"

  describe "event builders" do
    test "turn_started/3 builds correct event" do
      event = Events.turn_started(@run_id, @session_id, 1)

      assert event.type == "agent_turn_started"
      assert event.run_id == @run_id
      assert event.session_id == @session_id
      assert event.turn_number == 1
      assert %DateTime{} = event.timestamp
    end

    test "turn_started/3 handles nil session_id" do
      event = Events.turn_started(@run_id, nil, 3)

      assert event.session_id == nil
      assert event.turn_number == 3
    end

    test "llm_stream/3 builds correct event" do
      event = Events.llm_stream(@run_id, @session_id, "Hello")

      assert event.type == "agent_llm_stream"
      assert event.chunk == "Hello"
      assert event.chunk_size == 5
    end

    test "llm_stream/3 handles UTF-8 correctly" do
      event = Events.llm_stream(@run_id, @session_id, "🚀")
      # 4 bytes in UTF-8
      assert event.chunk_size == 4
    end

    test "tool_call_start/5 builds correct event" do
      args = %{"path" => "/tmp/test"}
      event = Events.tool_call_start(@run_id, @session_id, :file_read, args, "tc-1")

      assert event.type == "agent_tool_call_start"
      assert event.tool_name == "file_read"
      assert event.arguments == args
      assert event.tool_call_id == "tc-1"
    end

    test "tool_call_end/5 builds correct event" do
      result = %{status: "ok", output: "file contents"}
      event = Events.tool_call_end(@run_id, @session_id, :file_read, result, "tc-1")

      assert event.type == "agent_tool_call_end"
      assert event.tool_name == "file_read"
      assert event.result == result
      assert event.tool_call_id == "tc-1"
    end

    test "turn_ended/4 builds correct event" do
      event = Events.turn_ended(@run_id, @session_id, 3, :done)

      assert event.type == "agent_turn_ended"
      assert event.turn_number == 3
      assert event.reason == "done"
    end

    test "turn_ended/4 converts reason atoms to strings" do
      assert Events.turn_ended(@run_id, @session_id, 1, :error).reason == "error"
      assert Events.turn_ended(@run_id, @session_id, 1, :halt).reason == "halt"
      assert Events.turn_ended(@run_id, @session_id, 1, :cancelled).reason == "cancelled"
    end

    test "run_completed/3 builds correct event" do
      summary = %{turns: 5, reason: :text_response}
      event = Events.run_completed(@run_id, @session_id, summary)

      assert event.type == "agent_run_completed"
      assert event.summary == summary
    end

    test "run_failed/3 builds correct event" do
      event = Events.run_failed(@run_id, @session_id, :timeout)

      assert event.type == "agent_run_failed"
      assert event.error == ":timeout"
    end

    test "run_failed/3 formats exception errors" do
      error = %RuntimeError{message: "something broke"}
      event = Events.run_failed(@run_id, @session_id, error)

      assert event.error == "something broke"
    end
  end

  describe "JSON serialization roundtrip" do
    test "turn_started encodes and decodes" do
      event = Events.turn_started(@run_id, @session_id, 1)
      assert {:ok, json} = Events.to_json(event)
      assert {:ok, decoded} = Events.from_json(json)

      assert decoded["type"] == "agent_turn_started"
      assert decoded["run_id"] == @run_id
      assert decoded["turn_number"] == 1
    end

    test "llm_stream encodes and decodes" do
      event = Events.llm_stream(@run_id, @session_id, "Hello 🚀")
      assert {:ok, json} = Events.to_json(event)
      assert {:ok, decoded} = Events.from_json(json)

      assert decoded["chunk"] == "Hello 🚀"
    end

    test "tool_call_start encodes and decodes" do
      args = %{"path" => "/tmp/test", "recursive" => true}
      event = Events.tool_call_start(@run_id, @session_id, :shell, args, "tc-1")
      assert {:ok, json} = Events.to_json(event)
      assert {:ok, decoded} = Events.from_json(json)

      assert decoded["tool_name"] == "shell"
      assert decoded["arguments"]["path"] == "/tmp/test"
    end

    test "tool_call_end with map result encodes" do
      result = %{status: "ok", output: "command output"}
      event = Events.tool_call_end(@run_id, @session_id, :shell, result, "tc-1")
      assert {:ok, json} = Events.to_json(event)
      assert {:ok, decoded} = Events.from_json(json)

      assert decoded["tool_call_id"] == "tc-1"
      assert decoded["result"]["status"] == "ok"
    end

    test "run_completed encodes and decodes" do
      summary = %{turns: 5, reason: "text_response"}
      event = Events.run_completed(@run_id, @session_id, summary)
      assert {:ok, json} = Events.to_json(event)
      assert {:ok, decoded} = Events.from_json(json)

      assert decoded["summary"]["turns"] == 5
    end

    test "from_json rejects non-map JSON" do
      assert {:error, :invalid_event_format} = Events.from_json("[1, 2, 3]")
      assert {:error, :invalid_event_format} = Events.from_json("\"hello\"")
    end

    test "from_json rejects invalid JSON" do
      assert {:error, _} = Events.from_json("not json at all")
    end
  end

  describe "messages_compacted/3" do
    test "builds correct event" do
      stats = %{original_count: 160, compacted_count: 33, dropped_by_filter: 0}
      event = Events.messages_compacted(@run_id, @session_id, stats)

      assert event.type == "agent_messages_compacted"
      assert event.run_id == @run_id
      assert event.session_id == @session_id
      assert event.stats == stats
      assert %DateTime{} = event.timestamp
    end

    test "handles nil session_id" do
      stats = %{original_count: 50, compacted_count: 20}
      event = Events.messages_compacted(@run_id, nil, stats)

      assert event.session_id == nil
      assert event.stats.original_count == 50
    end

    test "encodes and decodes to JSON" do
      stats = %{original_count: 100, compacted_count: 30, dropped_by_filter: 5}
      event = Events.messages_compacted(@run_id, @session_id, stats)

      assert {:ok, json} = Events.to_json(event)
      assert {:ok, decoded} = Events.from_json(json)

      assert decoded["type"] == "agent_messages_compacted"
      assert decoded["stats"]["original_count"] == 100
    end
  end

  describe "all events have required fields" do
    test "every event has type, run_id, session_id, timestamp" do
      events = [
        Events.turn_started(@run_id, @session_id, 1),
        Events.llm_stream(@run_id, @session_id, "chunk"),
        Events.tool_call_start(@run_id, @session_id, :t, %{}, "tc-1"),
        Events.tool_call_end(@run_id, @session_id, :t, %{}, "tc-1"),
        Events.turn_ended(@run_id, @session_id, 1, :done),
        Events.run_completed(@run_id, @session_id, %{}),
        Events.run_failed(@run_id, @session_id, :err)
      ]

      for event <- events do
        assert Map.has_key?(event, :type)
        assert Map.has_key?(event, :run_id)
        assert Map.has_key?(event, :session_id)
        assert Map.has_key?(event, :timestamp)
        assert %DateTime{} = event.timestamp
      end
    end
  end
end
