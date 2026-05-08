defmodule CodePuppyControl.Agent.EventStreamHandlerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.EventStreamHandler
  alias CodePuppyControl.Stream.Event

  @run_id "run-test-123"
  @session_id "session-test-456"

  describe "start_link/1 and initialization" do
    test "starts with run_id and session_id" do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)

      {did_stream, line_count} = EventStreamHandler.get_stream_state(pid)
      assert did_stream == false
      assert line_count == 0

      EventStreamHandler.drain(pid)
    end
  end

  describe "text streaming" do
    setup do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)
      {:ok, pid: pid}
    end

    test "tracks text streaming and line counts", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.TextStart{index: 0, id: nil})
      EventStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "Hello world"})
      EventStreamHandler.push(pid, %Event.TextEnd{index: 0, id: nil})

      # Give the GenServer time to process casts
      Process.sleep(50)

      {did_stream, line_count} = EventStreamHandler.get_stream_state(pid)
      assert did_stream == true
      # Banner (2 lines) + content
      assert line_count >= 2

      EventStreamHandler.drain(pid)
    end

    test "handles multiple text parts at different indices", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.TextStart{index: 0, id: nil})
      EventStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "First"})
      EventStreamHandler.push(pid, %Event.TextEnd{index: 0, id: nil})
      EventStreamHandler.push(pid, %Event.TextStart{index: 1, id: nil})
      EventStreamHandler.push(pid, %Event.TextDelta{index: 1, text: "Second"})
      EventStreamHandler.push(pid, %Event.TextEnd{index: 1, id: nil})

      Process.sleep(50)

      {did_stream, _line_count} = EventStreamHandler.get_stream_state(pid)
      assert did_stream == true

      EventStreamHandler.drain(pid)
    end

    test "does not set did_stream_text for empty text parts", %{pid: pid} do
      # TextStart with no TextDelta → no content streamed
      EventStreamHandler.push(pid, %Event.TextStart{index: 0, id: nil})
      EventStreamHandler.push(pid, %Event.TextEnd{index: 0, id: nil})

      Process.sleep(50)

      {did_stream, _line_count} = EventStreamHandler.get_stream_state(pid)
      assert did_stream == false

      EventStreamHandler.drain(pid)
    end
  end

  describe "text buffering" do
    setup do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)
      {:ok, pid: pid}
    end

    test "accumulates small text chunks before flushing", %{pid: pid} do
      # Small chunks that don't trigger threshold
      EventStreamHandler.push(pid, %Event.TextStart{index: 0, id: nil})
      EventStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "ab"})
      EventStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "cd"})
      # Flush with newline
      EventStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "ef\n"})
      EventStreamHandler.push(pid, %Event.TextEnd{index: 0, id: nil})

      Process.sleep(50)

      {_did_stream, line_count} = EventStreamHandler.get_stream_state(pid)
      assert line_count >= 1

      EventStreamHandler.drain(pid)
    end

    test "flushes remaining buffer on TextEnd", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.TextStart{index: 0, id: nil})
      # Small chunk that stays buffered
      EventStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "short"})
      # TextEnd flushes remaining buffer
      EventStreamHandler.push(pid, %Event.TextEnd{index: 0, id: nil})

      Process.sleep(50)

      {did_stream, _line_count} = EventStreamHandler.get_stream_state(pid)
      assert did_stream == true

      EventStreamHandler.drain(pid)
    end
  end

  describe "thinking streaming" do
    setup do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)
      {:ok, pid: pid}
    end

    test "processes thinking events", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.ThinkingStart{index: 0, id: nil})
      EventStreamHandler.push(pid, %Event.ThinkingDelta{index: 0, text: "Let me think..."})
      EventStreamHandler.push(pid, %Event.ThinkingEnd{index: 0, id: nil})

      Process.sleep(50)

      # Thinking events should be tracked but not set did_stream_text
      {did_stream, _line_count} = EventStreamHandler.get_stream_state(pid)
      # did_stream_text is for text parts specifically
      # thinking sets did_stream_anything internally
      assert did_stream == false

      EventStreamHandler.drain(pid)
    end
  end

  describe "tool call streaming" do
    setup do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)
      {:ok, pid: pid}
    end

    test "processes tool call events with token estimation", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.ToolCallStart{index: 0, id: "tc-1", name: "read_file"})

      EventStreamHandler.push(pid, %Event.ToolCallArgsDelta{
        index: 0,
        arguments: "{\"path\": \"/tmp\"}"
      })

      EventStreamHandler.push(pid, %Event.ToolCallEnd{
        index: 0,
        id: "tc-1",
        name: "read_file",
        arguments: "{}"
      })

      Process.sleep(50)

      EventStreamHandler.drain(pid)
    end

    test "handles multiple tool calls", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.ToolCallStart{index: 0, id: "tc-1", name: "read_file"})

      EventStreamHandler.push(pid, %Event.ToolCallArgsDelta{
        index: 0,
        arguments: "{\"path\": \"/a\"}"
      })

      EventStreamHandler.push(pid, %Event.ToolCallEnd{
        index: 0,
        id: "tc-1",
        name: "read_file",
        arguments: "{}"
      })

      EventStreamHandler.push(pid, %Event.ToolCallStart{index: 1, id: "tc-2", name: "shell"})

      EventStreamHandler.push(pid, %Event.ToolCallArgsDelta{
        index: 1,
        arguments: "{\"cmd\": \"ls\"}"
      })

      EventStreamHandler.push(pid, %Event.ToolCallEnd{
        index: 1,
        id: "tc-2",
        name: "shell",
        arguments: "{}"
      })

      Process.sleep(50)
      EventStreamHandler.drain(pid)
    end
  end

  describe "mixed event types" do
    setup do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)
      {:ok, pid: pid}
    end

    test "handles interleaved text, thinking, and tool calls", %{pid: pid} do
      # Thinking
      EventStreamHandler.push(pid, %Event.ThinkingStart{index: 0, id: nil})
      EventStreamHandler.push(pid, %Event.ThinkingDelta{index: 0, text: "Planning..."})
      EventStreamHandler.push(pid, %Event.ThinkingEnd{index: 0, id: nil})

      # Text
      EventStreamHandler.push(pid, %Event.TextStart{index: 1, id: nil})
      EventStreamHandler.push(pid, %Event.TextDelta{index: 1, text: "Here's the answer"})
      EventStreamHandler.push(pid, %Event.TextEnd{index: 1, id: nil})

      # Tool call
      EventStreamHandler.push(pid, %Event.ToolCallStart{index: 2, id: "tc-1", name: "grep"})

      EventStreamHandler.push(pid, %Event.ToolCallArgsDelta{
        index: 2,
        arguments: "{\"q\": \"test\"}"
      })

      EventStreamHandler.push(pid, %Event.ToolCallEnd{
        index: 2,
        id: "tc-1",
        name: "grep",
        arguments: "{}"
      })

      Process.sleep(50)

      {did_stream, _line_count} = EventStreamHandler.get_stream_state(pid)
      assert did_stream == true

      EventStreamHandler.drain(pid)
    end
  end

  describe "UsageUpdate and Done" do
    setup do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)
      {:ok, pid: pid}
    end

    test "processes usage update events", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.UsageUpdate{
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150
      })

      Process.sleep(50)
      EventStreamHandler.drain(pid)
    end

    test "processes done events", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.Done{
        id: "msg-1",
        model: "gpt-4o",
        finish_reason: "stop",
        usage: nil
      })

      Process.sleep(50)
      EventStreamHandler.drain(pid)
    end
  end

  describe "get_stream_state/1 resets state after reading" do
    setup do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)
      {:ok, pid: pid}
    end

    test "second call returns false/0 after reset", %{pid: pid} do
      EventStreamHandler.push(pid, %Event.TextStart{index: 0, id: nil})
      EventStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "content"})
      EventStreamHandler.push(pid, %Event.TextEnd{index: 0, id: nil})

      Process.sleep(50)

      # First call returns state and resets
      {did_stream, _line_count} = EventStreamHandler.get_stream_state(pid)
      assert did_stream == true

      # Second call returns reset state
      {did_stream2, line_count2} = EventStreamHandler.get_stream_state(pid)
      assert did_stream2 == false
      assert line_count2 == 0

      EventStreamHandler.drain(pid)
    end
  end

  describe "unknown events" do
    setup do
      {:ok, pid} = EventStreamHandler.start_link(run_id: @run_id, session_id: @session_id)
      {:ok, pid: pid}
    end

    test "ignores unknown event types", %{pid: pid} do
      EventStreamHandler.push(pid, %{unknown: "event"})
      Process.sleep(50)
      EventStreamHandler.drain(pid)
    end
  end
end
