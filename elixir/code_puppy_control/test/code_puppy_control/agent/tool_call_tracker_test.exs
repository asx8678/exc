defmodule CodePuppyControl.Agent.ToolCallTrackerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.ToolCallTracker

  # ═══════════════════════════════════════════════════════════════════════
  # collect_ids/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "collect_ids/1" do
    test "returns empty sets for empty list" do
      result = ToolCallTracker.collect_ids([])
      assert MapSet.size(result.call_ids) == 0
      assert MapSet.size(result.return_ids) == 0
    end

    test "collects tool call IDs from assistant messages" do
      messages = [
        %{
          "role" => "assistant",
          "tool_calls" => [
            %{id: "tc_1", name: "read", arguments: %{}},
            %{id: "tc_2", name: "write", arguments: %{}}
          ]
        }
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.new(["tc_1", "tc_2"]) == result.call_ids
      assert MapSet.size(result.return_ids) == 0
    end

    test "collects tool return IDs from tool messages" do
      messages = [
        %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"}
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.size(result.call_ids) == 0
      assert MapSet.new(["tc_1"]) == result.return_ids
    end

    test "collects from mixed assistant and tool messages" do
      messages = [
        %{
          "role" => "assistant",
          "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]
        },
        %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"},
        %{
          "role" => "assistant",
          "tool_calls" => [%{id: "tc_2", name: "w", arguments: %{}}]
        }
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.new(["tc_1", "tc_2"]) == result.call_ids
      assert MapSet.new(["tc_1"]) == result.return_ids
    end

    test "handles string-keyed tool calls" do
      messages = [
        %{
          "role" => "assistant",
          "tool_calls" => [%{"id" => "tc_str", "name" => "r", "arguments" => %{}}]
        }
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.new(["tc_str"]) == result.call_ids
    end

    test "handles atom-keyed messages" do
      messages = [
        %{role: "tool", tool_call_id: "tc_atom", content: "ok"}
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.new(["tc_atom"]) == result.return_ids
    end

    test "handles atom-keyed assistant messages with tool_calls" do
      # Agent.Loop.finalize_turn produces atom-keyed assistant messages.
      # Regression: code-puppy-v2o.1 — collect_ids missed these, causing
      # prune_interrupted to treat in-progress tool calls as interrupted.
      messages = [
        %{
          role: "assistant",
          content: nil,
          tool_calls: [%{id: "tc_a1", name: :read, arguments: %{}}]
        }
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.new(["tc_a1"]) == result.call_ids
      assert MapSet.size(result.return_ids) == 0
    end

    test "mixed atom/string-keyed messages collect all IDs" do
      messages = [
        %{
          role: "assistant",
          content: nil,
          tool_calls: [%{id: "tc_atom", name: :r, arguments: %{}}]
        },
        %{"role" => "assistant", "tool_calls" => [%{id: "tc_str", name: "w", arguments: %{}}]},
        %{role: "tool", tool_call_id: "tc_atom", content: "ok"},
        %{"role" => "tool", "tool_call_id" => "tc_str", "content" => "ok"}
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.new(["tc_atom", "tc_str"]) == result.call_ids
      assert MapSet.new(["tc_atom", "tc_str"]) == result.return_ids
    end

    test "handles parts-style messages" do
      messages = [
        %{
          "role" => "assistant",
          "parts" => [
            %{"part_kind" => "tool-call", "tool_call_id" => "tc_parts_1"},
            %{"part_kind" => "text", "content" => "thinking..."}
          ]
        },
        %{
          "role" => "tool",
          "parts" => [
            %{"part_kind" => "tool-return", "tool_call_id" => "tc_parts_1", "content" => "result"}
          ]
        }
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.new(["tc_parts_1"]) == result.call_ids
      assert MapSet.new(["tc_parts_1"]) == result.return_ids
    end

    test "ignores messages without tool-related keys" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"}
      ]

      result = ToolCallTracker.collect_ids(messages)
      assert MapSet.size(result.call_ids) == 0
      assert MapSet.size(result.return_ids) == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # check_pending/1, has_pending_tool_calls?/1, pending_tool_call_count/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "check_pending/1" do
    test "returns false, 0 for empty messages" do
      assert ToolCallTracker.check_pending([]) == {false, 0}
    end

    test "returns true with unmatched tool calls" do
      messages = [
        %{
          "role" => "assistant",
          "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]
        }
      ]

      assert ToolCallTracker.check_pending(messages) == {true, 1}
    end

    test "returns false when all tool calls have returns" do
      messages = [
        %{
          "role" => "assistant",
          "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]
        },
        %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"}
      ]

      assert ToolCallTracker.check_pending(messages) == {false, 0}
    end

    test "counts pending correctly with mixed state" do
      messages = [
        %{
          "role" => "assistant",
          "tool_calls" => [
            %{id: "tc_1", name: "r", arguments: %{}},
            %{id: "tc_2", name: "w", arguments: %{}}
          ]
        },
        %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"}
      ]

      assert ToolCallTracker.check_pending(messages) == {true, 1}
    end

    test "orphaned tool returns are not counted as pending (only calls are)" do
      messages = [
        %{"role" => "tool", "tool_call_id" => "tc_orphan", "content" => "result"}
      ]

      # Orphaned return: return_ids has tc_orphan but call_ids doesn't
      # check_pending only counts call_ids - return_ids, not the reverse
      # This matches Python's behavior: has_pending_tool_calls checks for
      # tool calls waiting for results, not the other way around
      result = ToolCallTracker.check_pending(messages)
      assert result == {false, 0}
    end
  end

  describe "has_pending_tool_calls?/1" do
    test "returns false for no pending" do
      refute ToolCallTracker.has_pending_tool_calls?([])
    end

    test "returns true for pending tool calls" do
      messages = [
        %{
          "role" => "assistant",
          "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]
        }
      ]

      assert ToolCallTracker.has_pending_tool_calls?(messages)
    end
  end

  describe "pending_tool_call_count/1" do
    test "returns 0 for no pending" do
      assert ToolCallTracker.pending_tool_call_count([]) == 0
    end

    test "returns correct count" do
      messages = [
        %{
          "role" => "assistant",
          "tool_calls" => [
            %{id: "tc_1", name: "r", arguments: %{}},
            %{id: "tc_2", name: "w", arguments: %{}}
          ]
        }
      ]

      assert ToolCallTracker.pending_tool_call_count(messages) == 2
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # prune_interrupted/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "prune_interrupted/1" do
    test "returns empty list for empty input" do
      assert ToolCallTracker.prune_interrupted([]) == []
    end

    test "returns unchanged list when no mismatches" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{
          "role" => "assistant",
          "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]
        },
        %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"}
      ]

      result = ToolCallTracker.prune_interrupted(messages)
      assert length(result) == 3
    end

    test "removes messages with mismatched tool call IDs" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{
          "role" => "assistant",
          "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]
        },
        # tc_1 has a return, tc_2 does not → tc_2's assistant message is mismatched
        %{
          "role" => "assistant",
          "tool_calls" => [
            %{id: "tc_1", name: "r", arguments: %{}},
            %{id: "tc_2", name: "w", arguments: %{}}
          ]
        },
        %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"}
      ]

      result = ToolCallTracker.prune_interrupted(messages)
      # The second assistant message contains tc_2 which is mismatched
      assert length(result) < length(messages)
    end

    test "removes orphaned tool returns" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "tool", "tool_call_id" => "tc_orphan", "content" => "result"}
      ]

      result = ToolCallTracker.prune_interrupted(messages)
      assert length(result) == 1
      assert result == [%{"role" => "user", "content" => "hello"}]
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Part classification
  # ═══════════════════════════════════════════════════════════════════════

  describe "tool_call_part?/1" do
    test "detects string-keyed tool call part" do
      assert ToolCallTracker.tool_call_part?(%{
               "part_kind" => "tool-call",
               "tool_call_id" => "tc_1"
             })
    end

    test "detects hyphenated tool-call kind" do
      assert ToolCallTracker.tool_call_part?(%{
               "part_kind" => "tool-call",
               "tool_call_id" => "tc_1"
             })
    end

    test "rejects text part" do
      refute ToolCallTracker.tool_call_part?(%{"part_kind" => "text", "content" => "hi"})
    end

    test "rejects tool return part" do
      refute ToolCallTracker.tool_call_part?(%{
               "part_kind" => "tool-return",
               "tool_call_id" => "tc_1"
             })
    end
  end

  describe "tool_return_part?/1" do
    test "detects tool return part" do
      assert ToolCallTracker.tool_return_part?(%{
               "part_kind" => "tool-return",
               "tool_call_id" => "tc_1"
             })
    end

    test "rejects tool call part" do
      refute ToolCallTracker.tool_return_part?(%{
               "part_kind" => "tool-call",
               "tool_call_id" => "tc_1"
             })
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # find_safe_split_index/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "find_safe_split_index/2" do
    test "returns index 0 for index <= 1" do
      assert ToolCallTracker.find_safe_split_index([], 0) == 0
      assert ToolCallTracker.find_safe_split_index([], 1) == 1
    end

    test "returns original index when no tool pairs cross the boundary" do
      messages = [
        %{"role" => "system", "content" => "system"},
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"}
      ]

      assert ToolCallTracker.find_safe_split_index(messages, 2) == 2
    end

    test "adjusts index to include tool_use whose return is in protected zone" do
      messages = [
        %{"role" => "system", "content" => "system"},
        %{
          "role" => "assistant",
          "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]
        },
        %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"},
        %{"role" => "user", "content" => "continue"}
      ]

      # Split at 2 means the tool_return (index 2) is in the protected zone
      # but the tool_call (index 1) is not → adjust to include index 1
      result = ToolCallTracker.find_safe_split_index(messages, 3)
      # The tool_return at index 2 has its call at index 1
      assert result <= 3
    end
  end
end
