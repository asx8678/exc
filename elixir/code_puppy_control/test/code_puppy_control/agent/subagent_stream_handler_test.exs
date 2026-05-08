defmodule CodePuppyControl.Agent.SubagentStreamHandlerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.SubagentStreamHandler
  alias CodePuppyControl.Stream.Event

  @run_id "run-sub-123"
  @session_id "session-sub-456"
  @parent_session_id "session-parent-789"

  describe "start_link/1 and initialization" do
    test "starts with run_id and session_id" do
      {:ok, pid} =
        SubagentStreamHandler.start_link(
          run_id: @run_id,
          session_id: @session_id,
          parent_session_id: @parent_session_id
        )

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.token_count == 0
      assert metrics.tool_call_count == 0
      assert metrics.current_tool == nil

      SubagentStreamHandler.drain(pid)
    end
  end

  describe "token counting" do
    setup do
      {:ok, pid} =
        SubagentStreamHandler.start_link(
          run_id: @run_id,
          session_id: @session_id,
          parent_session_id: @parent_session_id
        )

      {:ok, pid: pid}
    end

    test "counts tokens from text deltas", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "Hello world"})
      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.token_count > 0

      SubagentStreamHandler.drain(pid)
    end

    test "counts tokens from thinking deltas", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.ThinkingDelta{
        index: 0,
        text: "Let me think about this..."
      })

      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.token_count > 0

      SubagentStreamHandler.drain(pid)
    end

    test "counts tokens from tool call args deltas", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.ToolCallStart{
        index: 0,
        id: "tc-1",
        name: "read_file"
      })

      SubagentStreamHandler.push(pid, %Event.ToolCallArgsDelta{
        index: 0,
        arguments: "{\"path\": \"/tmp/test\"}"
      })

      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.token_count > 0

      SubagentStreamHandler.drain(pid)
    end

    test "accumulates tokens across multiple deltas", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.TextDelta{index: 0, text: "Hello"})
      SubagentStreamHandler.push(pid, %Event.TextDelta{index: 0, text: " world"})
      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.token_count > 0

      SubagentStreamHandler.drain(pid)
    end

    test "handles empty text gracefully", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.TextDelta{index: 0, text: ""})
      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.token_count == 0

      SubagentStreamHandler.drain(pid)
    end
  end

  describe "tool call tracking" do
    setup do
      {:ok, pid} =
        SubagentStreamHandler.start_link(
          run_id: @run_id,
          session_id: @session_id,
          parent_session_id: @parent_session_id
        )

      {:ok, pid: pid}
    end

    test "increments tool_call_count on ToolCallStart", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.ToolCallStart{
        index: 0,
        id: "tc-1",
        name: "read_file"
      })

      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.tool_call_count == 1
      assert metrics.current_tool == "read_file"

      SubagentStreamHandler.drain(pid)
    end

    test "tracks current tool name", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.ToolCallStart{index: 0, id: "tc-1", name: "shell"})
      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.current_tool == "shell"

      SubagentStreamHandler.drain(pid)
    end

    test "resets current_tool when all tool parts end", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.ToolCallStart{
        index: 0,
        id: "tc-1",
        name: "read_file"
      })

      SubagentStreamHandler.push(pid, %Event.ToolCallEnd{
        index: 0,
        id: "tc-1",
        name: "read_file",
        arguments: "{}"
      })

      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.current_tool == nil

      SubagentStreamHandler.drain(pid)
    end

    test "tracks multiple concurrent tool calls", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.ToolCallStart{index: 0, id: "tc-1", name: "read"})
      SubagentStreamHandler.push(pid, %Event.ToolCallStart{index: 1, id: "tc-2", name: "shell"})
      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.tool_call_count == 2

      # End one — still have active tool
      SubagentStreamHandler.push(pid, %Event.ToolCallEnd{
        index: 0,
        id: "tc-1",
        name: "read",
        arguments: "{}"
      })

      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      # Still has an active tool part
      assert metrics.current_tool != nil

      # End the other
      SubagentStreamHandler.push(pid, %Event.ToolCallEnd{
        index: 1,
        id: "tc-2",
        name: "shell",
        arguments: "{}"
      })

      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.current_tool == nil

      SubagentStreamHandler.drain(pid)
    end
  end

  describe "complete streaming flow" do
    setup do
      {:ok, pid} =
        SubagentStreamHandler.start_link(
          run_id: @run_id,
          session_id: @session_id,
          parent_session_id: @parent_session_id
        )

      {:ok, pid: pid}
    end

    test "handles full agent run flow", %{pid: pid} do
      # Thinking
      SubagentStreamHandler.push(pid, %Event.ThinkingStart{index: 0, id: nil})

      SubagentStreamHandler.push(pid, %Event.ThinkingDelta{
        index: 0,
        text: "I need to read a file..."
      })

      SubagentStreamHandler.push(pid, %Event.ThinkingEnd{index: 0, id: nil})

      # Tool call
      SubagentStreamHandler.push(pid, %Event.ToolCallStart{
        index: 1,
        id: "tc-1",
        name: "read_file"
      })

      SubagentStreamHandler.push(pid, %Event.ToolCallArgsDelta{
        index: 1,
        arguments: "{\"path\": \"/etc/hosts\"}"
      })

      SubagentStreamHandler.push(pid, %Event.ToolCallEnd{
        index: 1,
        id: "tc-1",
        name: "read_file",
        arguments: "{}"
      })

      # Text response
      SubagentStreamHandler.push(pid, %Event.TextStart{index: 2, id: nil})

      SubagentStreamHandler.push(pid, %Event.TextDelta{
        index: 2,
        text: "The file contains host mappings."
      })

      SubagentStreamHandler.push(pid, %Event.TextEnd{index: 2, id: nil})

      # Done
      SubagentStreamHandler.push(pid, %Event.Done{
        id: "msg-1",
        model: "claude-sonnet-4-20250514",
        finish_reason: "stop",
        usage: nil
      })

      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.token_count > 0
      assert metrics.tool_call_count == 1
      assert metrics.current_tool == nil

      SubagentStreamHandler.drain(pid)
    end
  end

  describe "UsageUpdate events" do
    setup do
      {:ok, pid} =
        SubagentStreamHandler.start_link(
          run_id: @run_id,
          session_id: @session_id,
          parent_session_id: @parent_session_id
        )

      {:ok, pid: pid}
    end

    test "ignores usage update events without error", %{pid: pid} do
      SubagentStreamHandler.push(pid, %Event.UsageUpdate{
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150
      })

      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      # Not counted in our metrics
      assert metrics.token_count == 0

      SubagentStreamHandler.drain(pid)
    end
  end

  describe "unknown events" do
    setup do
      {:ok, pid} =
        SubagentStreamHandler.start_link(
          run_id: @run_id,
          session_id: @session_id,
          parent_session_id: @parent_session_id
        )

      {:ok, pid: pid}
    end

    test "ignores unknown event types", %{pid: pid} do
      SubagentStreamHandler.push(pid, %{unknown: "event"})
      Process.sleep(50)

      metrics = SubagentStreamHandler.get_metrics(pid)
      assert metrics.token_count == 0
      assert metrics.tool_call_count == 0

      SubagentStreamHandler.drain(pid)
    end
  end
end
