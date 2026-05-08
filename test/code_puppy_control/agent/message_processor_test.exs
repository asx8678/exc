defmodule CodePuppyControl.Agent.MessageProcessorTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.MessageProcessor
  alias CodePuppyControl.Agent.State

  # ═══════════════════════════════════════════════════════════════════════
  # ensure_ends_with_request/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "ensure_ends_with_request/1" do
    test "returns empty list unchanged" do
      assert MessageProcessor.ensure_ends_with_request([]) == []
    end

    test "returns list unchanged when it ends with user message" do
      messages = [%{"role" => "user", "content" => "hello"}]
      assert MessageProcessor.ensure_ends_with_request(messages) == messages
    end

    test "trims trailing assistant messages" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"}
      ]

      result = MessageProcessor.ensure_ends_with_request(messages)
      assert length(result) == 1
      assert result == [%{"role" => "user", "content" => "hello"}]
    end

    test "trims multiple trailing assistant messages" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"},
        %{"role" => "assistant", "content" => "more"}
      ]

      result = MessageProcessor.ensure_ends_with_request(messages)
      assert length(result) == 1
    end

    test "preserves non-trailing non-assistant messages" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"},
        %{"role" => "user", "content" => "more"}
      ]

      result = MessageProcessor.ensure_ends_with_request(messages)
      # Ends with user message, so nothing trimmed
      assert length(result) == 3
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # filter_huge/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "filter_huge/2" do
    test "passes small messages through" do
      messages = [%{"role" => "user", "content" => "hi"}]
      assert MessageProcessor.filter_huge(messages) == messages
    end

    test "filters messages exceeding token threshold" do
      # Create a message with very large content
      big_content = String.duplicate("x", 500_000)
      big_msg = %{"role" => "user", "content" => big_content}
      small_msg = %{"role" => "user", "content" => "hi"}

      result = MessageProcessor.filter_huge([big_msg, small_msg], max_tokens: 100_000)
      assert length(result) == 1
      assert hd(result) == small_msg
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # estimate_message_tokens/1 & estimate_batch_tokens/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "estimate_message_tokens/1" do
    test "estimates tokens for simple message" do
      msg = %{"role" => "user", "content" => "hello world"}
      tokens = MessageProcessor.estimate_message_tokens(msg)
      assert tokens >= 1
      # "hello world" = 11 chars, 11/2.5 ≈ 4.4 → ceil = 5
      assert tokens == 5
    end

    test "returns minimum 1 token for empty content" do
      msg = %{"role" => "system", "content" => ""}
      tokens = MessageProcessor.estimate_message_tokens(msg)
      assert tokens == 1
    end

    test "accounts for tool calls in token estimation" do
      msg = %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [%{id: "tc_1", name: "read_file", arguments: %{path: "/tmp/test"}}]
      }

      tokens = MessageProcessor.estimate_message_tokens(msg)
      assert tokens >= 1
    end
  end

  describe "estimate_batch_tokens/1" do
    test "sums tokens across messages" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi there"}
      ]

      tokens = MessageProcessor.estimate_batch_tokens(messages)
      assert tokens >= 2
    end

    test "returns 0 for empty list" do
      assert MessageProcessor.estimate_batch_tokens([]) == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # accumulate/4
  # ═══════════════════════════════════════════════════════════════════════

  describe "accumulate/4" do
    test "adds new messages to history" do
      history = [%{"role" => "user", "content" => "hello"}]
      hashes = MapSet.new([State.message_hash(hd(history))])
      # Use different role to ensure different hash (message_hash only uses role + parts)
      new = [%{"role" => "system", "content" => "now what"}]

      {h, _hashes, count} = MessageProcessor.accumulate(history, hashes, new)
      assert count == 1
      assert length(h) == 2
    end

    test "deduplicates messages by hash" do
      msg = %{"role" => "user", "content" => "hello"}
      hash = State.message_hash(msg)
      history = [msg]
      hashes = MapSet.new([hash])

      # Try to add the same message again
      {h, _hashes, count} = MessageProcessor.accumulate(history, hashes, [msg])
      assert count == 0
      assert length(h) == 1
    end

    test "handles multiple new messages with mixed dedup" do
      existing = %{"role" => "user", "content" => "hello"}
      new_msg = %{"role" => "system", "content" => "do something"}
      duplicate = %{"role" => "user", "content" => "hello"}

      history = [existing]
      hashes = MapSet.new([State.message_hash(existing)])

      {h, _hashes, count} = MessageProcessor.accumulate(history, hashes, [new_msg, duplicate])
      # new_msg has different role (different hash), duplicate has same role (same hash)
      assert count == 1
      assert length(h) == 2
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # truncation/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "truncation/2" do
    test "always preserves system message" do
      messages = [
        %{"role" => "system", "content" => "You are helpful"}
      ]

      result = MessageProcessor.truncation(messages, protected_tokens: 1)
      assert length(result) == 1
      assert hd(result)["role"] == "system"
    end

    test "protects recent messages within token budget" do
      messages = [
        %{"role" => "system", "content" => "system"},
        %{"role" => "user", "content" => "old message"},
        %{"role" => "assistant", "content" => "old response"},
        %{"role" => "user", "content" => "recent"}
      ]

      result = MessageProcessor.truncation(messages, protected_tokens: 100)
      # System message + recent message should be kept
      assert hd(result)["role"] == "system"
      assert List.last(result)["content"] == "recent"
    end

    test "returns empty list unchanged" do
      assert MessageProcessor.truncation([], protected_tokens: 100) == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # process_history/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "process_history/2" do
    test "passes through when compaction is disabled" do
      messages = [%{"role" => "user", "content" => "hello"}]
      {result, compacted} = MessageProcessor.process_history(messages, compaction_enabled: false)
      assert result == messages
      refute compacted
    end

    test "passes through empty messages" do
      {result, compacted} = MessageProcessor.process_history([], compaction_enabled: true)
      assert result == []
      refute compacted
    end

    test "passes through when below threshold" do
      messages = [%{"role" => "user", "content" => "hello"}]

      {result, compacted} =
        MessageProcessor.process_history(messages,
          compaction_enabled: true,
          model_context_length: 1_000_000,
          compaction_threshold: 0.8
        )

      assert result == messages
      refute compacted
    end
  end
end
