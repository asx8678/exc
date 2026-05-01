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

    test "wire-format unknown type falls back to legacy (string keys) and returns :skip" do
      # Event.from_wire returns {:error, :unknown_type}, then legacy_event_to_canonical
      # can't match string keys, so the catch-all returns :skip
      assert :skip =
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

    test "atom-keyed unknown event returns :skip" do
      assert :skip = EventMapper.event_to_canonical(%{type: "unknown_event_type"})
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
