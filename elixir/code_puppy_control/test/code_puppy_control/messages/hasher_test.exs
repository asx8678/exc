defmodule CodePuppyControl.Messages.HasherTest do
  @moduledoc """
  Tests for the Messages.Hasher module.

  Ported from Rust `code_puppy_core/src/message_hashing.rs` tests.
  """

  use ExUnit.Case

  alias CodePuppyControl.Messages.Hasher

  # ============================================================================
  # Helper functions for building test data
  # ============================================================================

  defp make_text_part(content) do
    %{
      part_kind: "text",
      content: content,
      content_json: nil,
      tool_call_id: nil,
      tool_name: nil,
      args: nil
    }
  end

  defp make_tool_call_part(tool_name, args, tool_call_id \\ nil) do
    %{
      part_kind: "tool_call",
      content: nil,
      content_json: nil,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      args: args
    }
  end

  defp make_tool_result_part(tool_call_id, content) do
    %{
      part_kind: "tool_result",
      content: content,
      content_json: nil,
      tool_call_id: tool_call_id,
      tool_name: nil,
      args: nil
    }
  end

  defp make_message(kind \\ "request", role \\ nil, instructions \\ nil, parts \\ []) do
    %{
      kind: kind,
      role: role,
      instructions: instructions,
      parts: parts
    }
  end

  # ============================================================================
  # hash_message/1 tests
  # ============================================================================

  describe "hash_message/1" do
    test "same message produces same hash" do
      msg1 = make_message("request", "user", nil, [make_text_part("hello")])
      msg2 = make_message("request", "user", nil, [make_text_part("hello")])

      assert Hasher.hash_message(msg1) == Hasher.hash_message(msg2)
    end

    test "different messages produce different hashes" do
      msg1 = make_message("request", "user", nil, [make_text_part("hello")])
      msg2 = make_message("request", "user", nil, [make_text_part("world")])

      assert Hasher.hash_message(msg1) != Hasher.hash_message(msg2)
    end

    test "empty parts produce stable hash" do
      msg1 = make_message("request", "user", nil, [])
      msg2 = make_message("request", "user", nil, [])

      assert Hasher.hash_message(msg1) == Hasher.hash_message(msg2)
      assert is_integer(Hasher.hash_message(msg1))
      assert Hasher.hash_message(msg1) >= 0
    end

    test "messages with tool calls hash differently" do
      text_msg = make_message("request", "user", nil, [make_text_part("use a tool")])

      tool_msg =
        make_message("request", "assistant", nil, [
          make_tool_call_part("search", ~s({"query": "test"}), "call_123")
        ])

      assert Hasher.hash_message(text_msg) != Hasher.hash_message(tool_msg)
    end

    test "different roles produce different hashes" do
      msg1 = make_message("request", "user", nil, [make_text_part("hello")])
      msg2 = make_message("request", "assistant", nil, [make_text_part("hello")])

      assert Hasher.hash_message(msg1) != Hasher.hash_message(msg2)
    end

    test "different instructions produce different hashes" do
      msg1 = make_message("request", "user", "Be helpful", [make_text_part("hello")])
      msg2 = make_message("request", "user", "Be concise", [make_text_part("hello")])

      assert Hasher.hash_message(msg1) != Hasher.hash_message(msg2)
    end

    test "nil vs empty role handled correctly" do
      msg_with_empty = make_message("request", "", nil, [make_text_part("hello")])
      msg_with_nil = make_message("request", nil, nil, [make_text_part("hello")])

      # Both nil and empty string should produce the same hash (no role header)
      assert Hasher.hash_message(msg_with_empty) == Hasher.hash_message(msg_with_nil)
    end

    test "nil vs empty instructions handled correctly" do
      msg_with_empty = make_message("request", "user", "", [make_text_part("hello")])
      msg_with_nil = make_message("request", "user", nil, [make_text_part("hello")])

      # Both nil and empty string should produce the same hash (no instructions header)
      assert Hasher.hash_message(msg_with_empty) == Hasher.hash_message(msg_with_nil)
    end

    test "multiple parts produce different hash than single part" do
      msg1 = make_message("request", "user", nil, [make_text_part("hello world")])

      msg2 =
        make_message("request", "user", nil, [make_text_part("hello"), make_text_part("world")])

      assert Hasher.hash_message(msg1) != Hasher.hash_message(msg2)
    end

    test "order of parts matters" do
      msg1 =
        make_message("request", "user", nil, [make_text_part("first"), make_text_part("second")])

      msg2 =
        make_message("request", "user", nil, [make_text_part("second"), make_text_part("first")])

      assert Hasher.hash_message(msg1) != Hasher.hash_message(msg2)
    end
  end

  # ============================================================================
  # stringify_part_for_hash/1 tests
  # ============================================================================

  describe "stringify_part_for_hash/1" do
    test "text part stringifies correctly" do
      part = make_text_part("hello world")
      result = Hasher.stringify_part_for_hash(part)

      assert result == "text|content=hello world"
    end

    test "tool call part stringifies correctly" do
      part = make_tool_call_part("search", ~s({"query": "test"}), "call_123")
      result = Hasher.stringify_part_for_hash(part)

      assert result == "tool_call|tool_call_id=call_123|tool_name=search|content=None"
    end

    test "tool result part stringifies correctly" do
      part = make_tool_result_part("call_123", "search results here")
      result = Hasher.stringify_part_for_hash(part)

      assert result == "tool_result|tool_call_id=call_123|content=search results here"
    end

    test "part with content_json uses json as content" do
      part = %{
        part_kind: "json",
        content: nil,
        content_json: ~s({"key": "value"}),
        tool_call_id: nil,
        tool_name: nil,
        args: nil
      }

      result = Hasher.stringify_part_for_hash(part)
      assert result == "json|content={\"key\": \"value\"}"
    end

    test "part with nil content shows content=None" do
      part = %{
        part_kind: "empty",
        content: nil,
        content_json: nil,
        tool_call_id: nil,
        tool_name: nil,
        args: nil
      }

      result = Hasher.stringify_part_for_hash(part)
      assert result == "empty|content=None"
    end

    test "part with empty string content shows content=" do
      part = %{
        part_kind: "text",
        content: "",
        content_json: nil,
        tool_call_id: nil,
        tool_name: nil,
        args: nil
      }

      result = Hasher.stringify_part_for_hash(part)
      # Empty string is still a present value
      assert result == "text|content="
    end

    test "part without tool attributes omits them" do
      part = make_text_part("simple content")
      result = Hasher.stringify_part_for_hash(part)

      refute String.contains?(result, "tool_call_id")
      refute String.contains?(result, "tool_name")
      assert result == "text|content=simple content"
    end

    test "part with only tool_call_id" do
      part = %{
        part_kind: "partial",
        content: "test",
        content_json: nil,
        tool_call_id: "id_123",
        tool_name: nil,
        args: nil
      }

      result = Hasher.stringify_part_for_hash(part)
      assert result == "partial|tool_call_id=id_123|content=test"
    end

    test "part with only tool_name" do
      part = %{
        part_kind: "partial",
        content: "test",
        content_json: nil,
        tool_call_id: nil,
        tool_name: "my_tool",
        args: nil
      }

      result = Hasher.stringify_part_for_hash(part)
      assert result == "partial|tool_name=my_tool|content=test"
    end

    test "content takes precedence over content_json" do
      part = %{
        part_kind: "both",
        content: "plain text",
        content_json: ~s({"json": "data"}),
        tool_call_id: nil,
        tool_name: nil,
        args: nil
      }

      result = Hasher.stringify_part_for_hash(part)
      # Should use content, not content_json
      assert result == "both|content=plain text"
    end
  end

  # ============================================================================
  # Edge cases and invariants
  # ============================================================================

  describe "edge cases" do
    test "hash is always non-negative" do
      msg = make_message("request", "user", nil, [make_text_part("test")])
      hash = Hasher.hash_message(msg)

      assert is_integer(hash)
      assert hash >= 0
    end

    test "unicode content is handled correctly" do
      msg = make_message("request", "user", nil, [make_text_part("Hello 世界 🌍")])
      hash = Hasher.hash_message(msg)

      assert is_integer(hash)

      # Same unicode content should hash the same
      msg2 = make_message("request", "user", nil, [make_text_part("Hello 世界 🌍")])
      assert hash == Hasher.hash_message(msg2)
    end

    test "content with special characters is handled" do
      msg = make_message("request", "user", nil, [make_text_part("hello|world||test")])
      hash = Hasher.hash_message(msg)

      assert is_integer(hash)

      # Different special chars should hash differently
      msg2 = make_message("request", "user", nil, [make_text_part("hello|world|test")])
      assert hash != Hasher.hash_message(msg2)
    end

    test "large message hashes consistently" do
      large_content = String.duplicate("a", 10_000)
      msg1 = make_message("request", "user", nil, [make_text_part(large_content)])
      msg2 = make_message("request", "user", nil, [make_text_part(large_content)])

      assert Hasher.hash_message(msg1) == Hasher.hash_message(msg2)
    end

    test "message with many parts" do
      parts = for i <- 1..100, do: make_text_part("part #{i}")
      msg = make_message("request", "user", nil, parts)

      hash = Hasher.hash_message(msg)
      assert is_integer(hash)
      assert hash >= 0
    end

    test "complex tool interaction message" do
      msg =
        make_message("request", "assistant", "You are helpful", [
          make_text_part("I'll search for that"),
          make_tool_call_part("search", ~s({"query": "elixir hashing"}), "call_1"),
          make_tool_result_part("call_1", "Elixir provides :erlang.phash2/1"),
          make_text_part("Here's what I found...")
        ])

      hash = Hasher.hash_message(msg)
      assert is_integer(hash)
      assert hash >= 0
    end
  end

  # ============================================================================
  # Property-like tests (invariants)
  # ============================================================================

  describe "property tests" do
    test "hash is deterministic" do
      msg =
        make_message("request", "user", "test instructions", [
          make_text_part("content 1"),
          make_tool_call_part("tool", ~s({"arg": 1}), "id_1")
        ])

      hash1 = Hasher.hash_message(msg)
      hash2 = Hasher.hash_message(msg)
      hash3 = Hasher.hash_message(msg)

      assert hash1 == hash2
      assert hash2 == hash3
    end

    test "single bit change produces different hash" do
      base = make_message("request", "user", "helpful", [make_text_part("test")])
      base_hash = Hasher.hash_message(base)

      # Note: 'kind' field is NOT included in the hash calculation
      # Only role, instructions, and parts affect the hash
      assert base_hash != Hasher.hash_message(%{base | role: "assistant"})
      assert base_hash != Hasher.hash_message(%{base | instructions: "new"})
      assert base_hash != Hasher.hash_message(%{base | parts: [make_text_part("different")]})
    end

    test "structurally identical messages hash identically" do
      msg1 = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: [
          %{
            part_kind: "text",
            content: "hi",
            content_json: nil,
            tool_call_id: nil,
            tool_name: nil,
            args: nil
          }
        ]
      }

      msg2 = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: [
          %{
            part_kind: "text",
            content: "hi",
            content_json: nil,
            tool_call_id: nil,
            tool_name: nil,
            args: nil
          }
        ]
      }

      assert Hasher.hash_message(msg1) == Hasher.hash_message(msg2)
    end
  end
end
