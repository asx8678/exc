defmodule CodePuppyControl.Messages.PrunerTest do
  use ExUnit.Case
  alias CodePuppyControl.Messages.Pruner

  describe "prune_and_filter/2" do
    test "keeps matched tool call pairs" do
      messages = [
        %{
          "kind" => "request",
          "parts" => [
            %{"part_kind" => "tool-call", "tool_call_id" => "call_1", "content" => "test"}
          ]
        },
        %{
          "kind" => "response",
          "parts" => [
            %{"part_kind" => "tool-return", "tool_call_id" => "call_1", "content" => "result"}
          ]
        }
      ]

      result = Pruner.prune_and_filter(messages)

      assert result.surviving_indices == [0, 1]
      assert result.dropped_count == 0
      assert result.had_pending_tool_calls == false
      assert result.pending_tool_call_count == 0
    end

    test "drops messages with mismatched tool calls" do
      messages = [
        %{
          "kind" => "request",
          "parts" => [
            %{"part_kind" => "tool-call", "tool_call_id" => "call_1", "content" => "test"}
          ]
        },
        %{
          "kind" => "request",
          "parts" => [
            %{"part_kind" => "tool-call", "tool_call_id" => "call_2", "content" => "test2"}
          ]
        },
        %{
          "kind" => "response",
          "parts" => [
            %{"part_kind" => "tool-return", "tool_call_id" => "call_2", "content" => "result"}
          ]
        }
      ]

      result = Pruner.prune_and_filter(messages)

      # call_1 has no matching return, so message at index 0 should be dropped
      assert result.surviving_indices == [1, 2]
      assert result.dropped_count == 1
      assert result.had_pending_tool_calls == true
      assert result.pending_tool_call_count == 1
    end

    test "drops huge messages" do
      # Create a message that exceeds the max tokens limit
      huge_content = String.duplicate("a", 50000)

      messages = [
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => huge_content}]},
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "small"}]}
      ]

      result = Pruner.prune_and_filter(messages, 1000)

      # First message should be dropped due to size
      assert result.surviving_indices == [1]
      assert result.dropped_count == 1
    end

    test "drops empty thinking parts" do
      messages = [
        %{"kind" => "request", "parts" => [%{"part_kind" => "thinking", "content" => ""}]},
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "valid"}]}
      ]

      result = Pruner.prune_and_filter(messages)

      # Empty thinking part should be dropped
      assert result.surviving_indices == [1]
      assert result.dropped_count == 1
    end

    test "keeps non-empty thinking parts" do
      messages = [
        %{
          "kind" => "request",
          "parts" => [%{"part_kind" => "thinking", "content" => "some thought"}]
        },
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "valid"}]}
      ]

      result = Pruner.prune_and_filter(messages)

      # Non-empty thinking should be kept
      assert result.surviving_indices == [0, 1]
      assert result.dropped_count == 0
    end
  end

  describe "truncation_indices/3" do
    test "always keeps first message" do
      per_message_tokens = [100, 200, 300, 400, 500]

      result = Pruner.truncation_indices(per_message_tokens, 1000, false)

      assert List.first(result) == 0
    end

    test "respects budget from end" do
      per_message_tokens = [100, 200, 300, 400, 500]
      # Budget 1000: keep 0 (always), then walk from end:
      # 500 (idx 4) fits, remaining 500
      # 400 (idx 3) fits, remaining 100
      # 300 (idx 2) doesn't fit (100 - 300 = -200 < 0)
      # Result: [0, 3, 4]
      result = Pruner.truncation_indices(per_message_tokens, 1000, false)

      assert 0 in result
      assert 4 in result
      assert 3 in result
      # Index 2 should NOT be in result (would exceed budget)
      refute 2 in result
    end

    test "empty input returns empty" do
      result = Pruner.truncation_indices([], 1000, false)

      assert result == []
    end

    test "keeps second when second_has_thinking is true" do
      per_message_tokens = [100, 50, 300, 400, 500]

      result = Pruner.truncation_indices(per_message_tokens, 1000, true)

      assert 0 in result
      assert 1 in result
    end

    test "single message returns just index 0" do
      per_message_tokens = [500]

      result = Pruner.truncation_indices(per_message_tokens, 100, false)

      assert result == [0]
    end

    test "truncation_indices breaks on budget exceeded (contiguous tail)" do
      result = Pruner.truncation_indices([100, 50, 1000, 50, 100], 300, false)
      refute 1 in result
      assert result == [0, 3, 4]
    end
  end

  describe "split_for_summarization/3" do
    test "single message returns empty summarize" do
      per_message_tokens = [500]
      messages = [%{"kind" => "request", "parts" => []}]

      result = Pruner.split_for_summarization(per_message_tokens, messages, 1000)

      assert result.summarize_indices == []
      assert result.protected_indices == [0]
    end

    test "single message has correct token count" do
      result =
        Pruner.split_for_summarization([500], [%{"kind" => "request", "parts" => []}], 1000)

      assert result.protected_token_count == 500
    end

    test "protects tool call pairs" do
      per_message_tokens = [100, 200, 300, 400]

      messages = [
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "start"}]},
        %{
          "kind" => "request",
          "parts" => [
            %{"part_kind" => "tool-call", "tool_call_id" => "call_1", "content" => "call"}
          ]
        },
        %{
          "kind" => "response",
          "parts" => [
            %{"part_kind" => "tool-return", "tool_call_id" => "call_1", "content" => "return"}
          ]
        },
        %{"kind" => "response", "parts" => [%{"part_kind" => "text", "content" => "end"}]}
      ]

      # With enough budget, protect indices 0, 2, 3
      # But boundary adjustment should protect index 1 too if call_1 is in protected tail
      result = Pruner.split_for_summarization(per_message_tokens, messages, 600)

      # Index 0 is always protected
      assert 0 in result.protected_indices
      # protected_token_count should be positive
      assert result.protected_token_count > 0
    end

    test "splits correctly with sufficient budget" do
      per_message_tokens = [100, 200, 300, 400, 500]

      messages =
        Enum.map(1..5, fn i ->
          %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "msg #{i}"}]}
        end)

      # Budget 1200: starts with 100 (idx 0), then walk from end:
      # 500 (idx 4) fits: total 600, remaining 600
      # 400 (idx 3) fits: total 1000, remaining 200
      # 300 (idx 2) doesn't fit (1000+300=1300 > 1200)
      # Protected tail: [3, 4], boundary at 3
      # Summarize: indices 1..2
      result = Pruner.split_for_summarization(per_message_tokens, messages, 1200)

      # Index 0 always protected
      assert 0 in result.protected_indices
      # Protected tail indices from the end
      assert 4 in result.protected_indices
      assert 3 in result.protected_indices
      # Summarize middle: indices 1 and 2
      assert result.summarize_indices == [1, 2]
    end

    test "with limited budget only protects first message" do
      per_message_tokens = [500, 600, 700]

      messages = [
        %{"kind" => "request", "parts" => [%{"part_kind" => "text"}]},
        %{"kind" => "request", "parts" => [%{"part_kind" => "text"}]},
        %{"kind" => "request", "parts" => [%{"part_kind" => "text"}]}
      ]

      # Small budget (500) - starts with 500 already, so no room for tail
      # Only index 0 is protected
      result = Pruner.split_for_summarization(per_message_tokens, messages, 500)

      assert 0 in result.protected_indices
      # All other indices should be in summarize
      assert result.summarize_indices == [1, 2]
      assert result.protected_token_count == 500
    end

    test "boundary adjustment stops at non-tool-call messages" do
      messages = [
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "sys"}]},
        %{
          "kind" => "request",
          "parts" => [%{"part_kind" => "tool-call", "tool_call_id" => "A", "content" => "c"}]
        },
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "gap"}]},
        %{
          "kind" => "response",
          "parts" => [%{"part_kind" => "tool-return", "tool_call_id" => "A", "content" => "r"}]
        },
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "end"}]}
      ]

      result = Pruner.split_for_summarization([10, 10, 10, 10, 10], messages, 35)
      assert result.summarize_indices == [1, 2]
      assert result.protected_indices == [0, 3, 4]
    end
  end
end
