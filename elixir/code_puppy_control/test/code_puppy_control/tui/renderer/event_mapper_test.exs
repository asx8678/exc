defmodule CodePuppyControl.TUI.Renderer.EventMapperTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Renderer.EventMapper
  alias CodePuppyControl.Stream.Event

  describe "event_to_canonical/1" do
    # ── Wire-format events (string keys → Event.from_wire) ────────────

    test "wire-format TextDelta via Event.from_wire" do
      assert {:ok, %Event.TextDelta{index: 0, text: "hello"}} =
               EventMapper.event_to_canonical(%{"type" => "text_delta", "index" => 0, "text" => "hello"})
    end

    test "wire-format ToolCallStart via Event.from_wire" do
      assert {:ok, %Event.ToolCallStart{index: 0, id: "tc-1", name: "read_file"}} =
               EventMapper.event_to_canonical(%{
                 "type" => "tool_call_start",
                 "index" => 0,
                 "id" => "tc-1",
                 "name" => "read_file"
               })
    end

    test "wire-format ToolCallEnd via Event.from_wire" do
      assert {:ok, %Event.ToolCallEnd{index: 0, id: "tc-1", name: "read_file", arguments: "{}"}} =
               EventMapper.event_to_canonical(%{
                 "type" => "tool_call_end",
                 "index" => 0,
                 "id" => "tc-1",
                 "name" => "read_file",
                 "arguments" => "{}"
               })
    end

    test "wire-format Done via Event.from_wire" do
      assert {:ok, %Event.Done{}} =
               EventMapper.event_to_canonical(%{"type" => "done"})
    end

    test "wire-format unknown type with string keys falls back to legacy" do
      # agent_llm_stream is a known legacy type — string-keyed version
      # is handled by the legacy converter, not rejected as unknown
      assert {:ok, %Event.TextDelta{}} =
               EventMapper.event_to_canonical(%{"type" => "agent_llm_stream", "chunk" => "data"})
    end

    test "wire-format unknown event type returns :skip" do
      assert :skip = EventMapper.event_to_canonical(%{"type" => "completely_unknown"})
    end

    # ── Atom-keyed legacy events ──────────────────────────────────────

    test "atom-keyed agent_llm_stream" do
      assert {:ok, %Event.TextDelta{index: 0, text: "chunk"}} =
               EventMapper.event_to_canonical(%{type: "agent_llm_stream", chunk: "chunk"})
    end

    test "atom-keyed agent_tool_call_start" do
      assert {:ok, %Event.ToolCallStart{index: 0, id: "tc-1", name: "tool"}} =
               EventMapper.event_to_canonical(%{
                 type: "agent_tool_call_start",
                 tool_name: "tool",
                 tool_call_id: "tc-1"
               })
    end

    test "atom-keyed agent_tool_call_end with id" do
      assert {:ok, %Event.ToolCallEnd{index: 0, id: "tc-1", name: "tool", arguments: ""}} =
               EventMapper.event_to_canonical(%{
                 type: "agent_tool_call_end",
                 tool_name: "tool",
                 tool_call_id: "tc-1"
               })
    end

    test "atom-keyed agent_tool_call_end with nil id defaults to empty string" do
      assert {:ok, %Event.ToolCallEnd{index: 0, id: "", name: "tool", arguments: ""}} =
               EventMapper.event_to_canonical(%{
                 type: "agent_tool_call_end",
                 tool_name: "tool",
                 tool_call_id: nil
               })
    end

    test "atom-keyed agent_run_completed" do
      assert {:ok, %Event.Done{}} =
               EventMapper.event_to_canonical(%{type: "agent_run_completed"})
    end

    test "atom-keyed agent_run_failed with error field" do
      assert {:ok, %Event.Done{}} =
               EventMapper.event_to_canonical(%{type: "agent_run_failed", error: "timeout"})
    end

    test "atom-keyed agent_run_failed bare" do
      assert {:ok, %Event.Done{}} =
               EventMapper.event_to_canonical(%{type: "agent_run_failed"})
    end

    test "atom-keyed agent_llm_stream with data chunk" do
      assert {:ok, %Event.TextDelta{index: 0, text: "data"}} =
               EventMapper.event_to_canonical(%{type: "agent_llm_stream", chunk: "data"})
    end

    test "atom-keyed agent_tool_call_start with bash" do
      assert {:ok, %Event.ToolCallStart{index: 0, id: "id-1", name: "bash"}} =
               EventMapper.event_to_canonical(%{type: "agent_tool_call_start", tool_name: "bash", tool_call_id: "id-1"})
    end

    test "atom-keyed agent_tool_call_end with grep" do
      assert {:ok, %Event.ToolCallEnd{index: 0, id: "id-2", name: "grep", arguments: ""}} =
               EventMapper.event_to_canonical(%{type: "agent_tool_call_end", tool_name: "grep", tool_call_id: "id-2"})
    end

    test "atom-keyed agent_tool_call_end with nil id for ls" do
      assert {:ok, %Event.ToolCallEnd{index: 0, id: "", name: "ls", arguments: ""}} =
               EventMapper.event_to_canonical(%{type: "agent_tool_call_end", tool_name: "ls", tool_call_id: nil})
    end

    test "atom-keyed agent_run_completed confirms Done" do
      assert {:ok, %Event.Done{}} =
               EventMapper.event_to_canonical(%{type: "agent_run_completed"})
    end

    test "atom-keyed unknown event returns :skip" do
      assert :skip = EventMapper.event_to_canonical(%{type: "unknown_event_type"})
    end

    # ── String-keyed legacy events ────────────────────────────────────────

    test "string-keyed agent_llm_stream" do
      # Falls back from Event.from_wire (unknown type) to legacy
      assert {:ok, %Event.TextDelta{index: 0, text: "chunk"}} =
               EventMapper.event_to_canonical(%{"type" => "agent_llm_stream", "chunk" => "chunk"})
    end

    test "string-keyed agent_tool_call_start" do
      assert {:ok, %Event.ToolCallStart{index: 0, id: "tc-x", name: "cat"}} =
               EventMapper.event_to_canonical(%{
                 "type" => "agent_tool_call_start",
                 "tool_name" => "cat",
                 "tool_call_id" => "tc-x"
               })
    end

    test "string-keyed agent_tool_call_end" do
      assert {:ok, %Event.ToolCallEnd{index: 0, id: "tc-y", name: "ls", arguments: ""}} =
               EventMapper.event_to_canonical(%{
                 "type" => "agent_tool_call_end",
                 "tool_name" => "ls",
                 "tool_call_id" => "tc-y"
               })
    end

    test "string-keyed agent_tool_call_end with nil id" do
      assert {:ok, %Event.ToolCallEnd{index: 0, id: "", name: "pwd", arguments: ""}} =
               EventMapper.event_to_canonical(%{
                 "type" => "agent_tool_call_end",
                 "tool_name" => "pwd",
                 "tool_call_id" => nil
               })
    end

    test "string-keyed agent_run_completed" do
      assert {:ok, %Event.Done{}} =
               EventMapper.event_to_canonical(%{"type" => "agent_run_completed"})
    end

    test "string-keyed agent_run_failed with error" do
      assert {:ok, %Event.Done{}} =
               EventMapper.event_to_canonical(%{"type" => "agent_run_failed", "error" => "oom"})
    end

    test "string-keyed agent_run_failed without error" do
      assert {:ok, %Event.Done{}} =
               EventMapper.event_to_canonical(%{"type" => "agent_run_failed"})
    end

    # ── Edge cases ────────────────────────────────────────────────────

    test "non-map input returns :skip" do
      assert :skip = EventMapper.event_to_canonical("string")
      assert :skip = EventMapper.event_to_canonical(123)
      assert :skip = EventMapper.event_to_canonical(nil)
    end

    test "empty map returns :skip" do
      assert :skip = EventMapper.event_to_canonical(%{})
    end
  end
end
