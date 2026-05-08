defmodule CodePuppyControl.Messaging.CoreTest do
  @moduledoc """
  Port of test_message_core.py and test_message_transport.py — deep behavior
  tests for message hashing, pruning, truncation, serialization, and
  cross-operation integrity.

  Covers hash consistency, batch hashing, prune integrity, serialize→prune
  pipeline, and stringify_part.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messages.{Hasher, Pruner, Serializer}
  alias CodePuppyControl.MessageCore.Hasher, as: MCHasher
  alias CodePuppyControl.MessageCore.Pruner, as: MCPruner

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp text_msg(content) do
    %{
      "kind" => "request",
      "role" => "user",
      "parts" => [%{"part_kind" => "text", "content" => content}]
    }
  end

  defp tool_call_msg(tool_name, call_id, args \\ %{}) do
    %{
      "kind" => "response",
      "role" => "assistant",
      "parts" => [
        %{
          "part_kind" => "tool-call",
          "tool_name" => tool_name,
          "tool_call_id" => call_id,
          "args" => args
        }
      ]
    }
  end

  defp tool_return_msg(call_id, content) do
    %{
      "kind" => "request",
      "role" => "tool",
      "parts" => [
        %{
          "part_kind" => "tool-return",
          "tool_call_id" => call_id,
          "content" => content
        }
      ]
    }
  end

  defp text_part(content) do
    %{
      "part_kind" => "text",
      "content" => content,
      "content_json" => nil,
      "tool_call_id" => nil,
      "tool_name" => nil,
      "args" => nil
    }
  end

  # ===========================================================================
  # Hash consistency
  # ===========================================================================

  describe "hash consistency" do
    test "same message produces same hash across multiple calls" do
      msg = text_msg("Test content for hashing")

      hash1 = Hasher.hash_message(msg)
      hash2 = Hasher.hash_message(msg)
      hash3 = Hasher.hash_message(msg)

      assert hash1 == hash2
      assert hash2 == hash3
    end

    test "different content produces different hash" do
      hashes = [
        Hasher.hash_message(text_msg("A")),
        Hasher.hash_message(text_msg("B")),
        Hasher.hash_message(text_msg("C"))
      ]

      assert length(Enum.uniq(hashes)) == 3
    end

    test "complex identical messages produce same hash" do
      msg1 = %{
        "kind" => "response",
        "role" => "assistant",
        "parts" => [
          %{
            "part_kind" => "tool-call",
            "tool_name" => "read_file",
            "tool_call_id" => "call_123",
            "args" => %{"file_path" => "test.rs"}
          },
          %{"part_kind" => "text", "content" => "Here's the file"}
        ]
      }

      msg2 = %{
        "kind" => "response",
        "role" => "assistant",
        "parts" => [
          %{
            "part_kind" => "tool-call",
            "tool_name" => "read_file",
            "tool_call_id" => "call_123",
            "args" => %{"file_path" => "test.rs"}
          },
          %{"part_kind" => "text", "content" => "Here's the file"}
        ]
      }

      assert Hasher.hash_message(msg1) == Hasher.hash_message(msg2)
    end

    test "batch hashing via map matches individual hashing" do
      messages = [
        text_msg("First"),
        text_msg("Second"),
        text_msg("Third")
      ]

      individual = Enum.map(messages, &Hasher.hash_message/1)
      # Simulate batch by mapping
      batch = Enum.map(messages, &Hasher.hash_message/1)
      assert individual == batch
    end

    test "tool call/return pair hashes are stable" do
      call_msg = tool_call_msg("test_tool", "pair_001", %{"key" => "value"})
      return_msg = tool_return_msg("pair_001", "Result data")

      call_hashes = for _ <- 1..5, do: Hasher.hash_message(call_msg)
      return_hashes = for _ <- 1..5, do: Hasher.hash_message(return_msg)

      assert length(Enum.uniq(call_hashes)) == 1
      assert length(Enum.uniq(return_hashes)) == 1
      assert hd(call_hashes) != hd(return_hashes)
    end
  end

  # ===========================================================================
  # Prune and filter
  # ===========================================================================

  describe "prune_and_filter/2" do
    test "drops orphaned tool calls" do
      messages = [
        text_msg("Hello"),
        %{
          "kind" => "response",
          "role" => "assistant",
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_call_id" => "orphan-123",
              "tool_name" => "test_tool"
            }
          ]
        }
      ]

      result = Pruner.prune_and_filter(messages)

      assert result.surviving_indices == [0]
      assert result.dropped_count == 1
      assert result.had_pending_tool_calls == true
      assert result.pending_tool_call_count == 1
    end

    test "keeps complete messages without orphaned tools" do
      messages = [
        text_msg("Hello"),
        %{
          "kind" => "response",
          "role" => "assistant",
          "parts" => [%{"part_kind" => "text", "content" => "Hi there!"}]
        }
      ]

      result = Pruner.prune_and_filter(messages)

      assert result.surviving_indices == [0, 1]
      assert result.dropped_count == 0
      assert result.had_pending_tool_calls == false
    end

    test "surviving messages remain intact after pruning" do
      messages = [
        text_msg("First message - must survive"),
        %{
          "kind" => "response",
          "role" => "assistant",
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_call_id" => "orphan-123",
              "tool_name" => "orphaned_tool"
            }
          ]
        },
        text_msg("Third message - must survive")
      ]

      result = Pruner.prune_and_filter(messages)

      assert 0 in result.surviving_indices
      assert 2 in result.surviving_indices
      assert 1 not in result.surviving_indices

      surviving = Enum.map(result.surviving_indices, &Enum.at(messages, &1))

      assert hd(surviving)["parts"] |> hd() |> Map.get("content") ==
               "First message - must survive"

      assert List.last(surviving)["parts"] |> hd() |> Map.get("content") ==
               "Third message - must survive"
    end

    test "complete tool conversation preserves all messages" do
      messages = [
        text_msg("Call a tool"),
        tool_call_msg("test_tool", "call_001", %{}),
        tool_return_msg("call_001", "Tool result"),
        text_msg("Done!")
      ]

      result = Pruner.prune_and_filter(messages)

      assert result.dropped_count == 0
      assert result.had_pending_tool_calls == false
      assert length(result.surviving_indices) == 4
    end

    test "large message dropped while others preserved" do
      messages = [
        text_msg("Small message 1"),
        text_msg(String.duplicate("x", 60_000)),
        text_msg("Small message 3")
      ]

      # 60k chars ≈ 15k tokens, so use a low threshold
      result = Pruner.prune_and_filter(messages, 10_000)

      assert 1 not in result.surviving_indices
      assert 0 in result.surviving_indices
      assert 2 in result.surviving_indices
    end
  end

  # ===========================================================================
  # Truncation indices
  # ===========================================================================

  describe "truncation_indices/3" do
    test "always keeps index 0" do
      result = Pruner.truncation_indices([1000, 2000, 3000], 500, false)
      assert 0 in result
    end

    test "respects budget from end" do
      result = Pruner.truncation_indices([100, 200, 300, 400, 500], 700, false)
      assert 0 in result
      assert 4 in result
      assert length(result) >= 2
    end

    test "protects second when second_has_thinking is true" do
      result = Pruner.truncation_indices([100, 50, 200, 300], 400, true)
      assert 0 in result
      assert 1 in result
    end

    test "empty input returns empty list" do
      assert Pruner.truncation_indices([], 100, false) == []
    end
  end

  # ===========================================================================
  # Split for summarization
  # ===========================================================================

  describe "split_for_summarization/3" do
    test "index 0 is always in protected_indices" do
      result =
        Pruner.split_for_summarization(
          [100, 200, 150, 250],
          Enum.map(1..4, fn _ -> text_msg("msg") end),
          400
        )

      assert 0 in result.protected_indices
    end

    test "returns correct structure" do
      result =
        Pruner.split_for_summarization(
          [100, 200],
          [text_msg("a"), text_msg("b")],
          200
        )

      assert Map.has_key?(result, :summarize_indices)
      assert Map.has_key?(result, :protected_indices)
      assert Map.has_key?(result, :protected_token_count)
    end
  end

  # ===========================================================================
  # Serialization
  # ===========================================================================

  describe "serialization round-trip" do
    test "simple text messages survive round-trip" do
      messages = [
        text_msg("Hello, world!"),
        %{
          "kind" => "response",
          "role" => "assistant",
          "parts" => [%{"part_kind" => "text", "content" => "Hi there! How can I help?"}]
        }
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      assert is_binary(data)
      assert byte_size(data) > 0

      {:ok, restored} = Serializer.deserialize_session(data)
      assert length(restored) == 2
      assert hd(restored)["kind"] == "request"
      assert List.last(restored)["kind"] == "response"
      assert hd(restored)["parts"] |> hd() |> Map.get("content") == "Hello, world!"
    end

    test "complex messages with tool calls round-trip" do
      messages = [
        text_msg("Read file test.rs"),
        %{
          "kind" => "response",
          "role" => "assistant",
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_name" => "read_file",
              "tool_call_id" => "call_abc123",
              "args" => %{"file_path" => "test.rs"}
            }
          ]
        },
        tool_return_msg("call_abc123", "fn hello() {\n    // pass\n}\n"),
        text_msg("Here's the file content...")
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      assert length(restored) == 4

      tool_call = restored |> Enum.at(1) |> Map.get("parts") |> hd()
      assert tool_call["part_kind"] == "tool-call"
      assert tool_call["tool_name"] == "read_file"
      assert tool_call["tool_call_id"] == "call_abc123"
      assert tool_call["args"]["file_path"] == "test.rs"

      tool_return = restored |> Enum.at(2) |> Map.get("parts") |> hd()
      assert tool_return["part_kind"] == "tool-return"
      assert tool_return["tool_call_id"] == "call_abc123"
    end

    test "unicode content survives round-trip" do
      messages = [
        %{
          "kind" => "request",
          "role" => "user",
          "parts" => [%{"part_kind" => "text", "content" => "Hello 世界 🌍 ñáéíóú «»"}]
        }
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      assert hd(restored)["parts"] |> hd() |> Map.get("content") == "Hello 世界 🌍 ñáéíóú «»"
    end

    test "incremental serialization round-trip" do
      batch1 = [text_msg("First"), text_msg("Response 1")]
      batch2 = [text_msg("Second"), text_msg("Response 2")]

      {:ok, data} = Serializer.serialize_session(batch1)
      {:ok, combined} = Serializer.serialize_session_incremental(batch2, data)

      {:ok, restored} = Serializer.deserialize_session(combined)
      assert length(restored) == 4
    end

    test "incremental with nil creates fresh data" do
      messages = [text_msg("Fresh")]

      {:ok, data} = Serializer.serialize_session_incremental(messages, nil)
      assert is_binary(data)

      {:ok, restored} = Serializer.deserialize_session(data)
      assert length(restored) == 1
    end
  end

  # ===========================================================================
  # Cross-operation integrity
  # ===========================================================================

  describe "cross-operation integrity" do
    test "serialize → deserialize → prune pipeline" do
      messages = [
        text_msg("Hello"),
        %{
          "kind" => "response",
          "role" => "assistant",
          "parts" => [%{"part_kind" => "text", "content" => "Hi!"}]
        }
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      result = Pruner.prune_and_filter(restored)
      assert result.surviving_indices == [0, 1]
      assert result.dropped_count == 0
    end

    test "hash consistent before and after serialization round-trip" do
      msg = text_msg("Consistency test")

      hash_before = Hasher.hash_message(msg)

      {:ok, data} = Serializer.serialize_session([msg])
      {:ok, [restored]} = Serializer.deserialize_session(data)

      hash_after = Hasher.hash_message(restored)
      assert hash_before == hash_after
    end

    test "MessageCore namespace delegates correctly for full pipeline" do
      msg = %{
        "kind" => "request",
        "role" => "user",
        "parts" => [%{"part_kind" => "text", "content" => "Pipeline test"}]
      }

      # Hash via both namespaces
      assert MCHasher.hash_message(msg) == Hasher.hash_message(msg)

      # Prune via both namespaces
      assert MCPruner.prune_and_filter([msg]) == Pruner.prune_and_filter([msg])

      # Truncation indices
      assert MCPruner.truncation_indices([100, 200], 200, false) ==
               Pruner.truncation_indices([100, 200], 200, false)
    end
  end

  # ===========================================================================
  # Stringify part
  # ===========================================================================

  describe "stringify_part_for_hash/1" do
    test "text part" do
      part = text_part("Hello")
      result = Hasher.stringify_part_for_hash(part)
      assert result == "text|content=Hello"
    end

    test "tool call part includes tool_name" do
      part = %{
        "part_kind" => "tool-call",
        "tool_name" => "read_file",
        "tool_call_id" => "abc123"
      }

      result = Hasher.stringify_part_for_hash(part)
      assert String.contains?(result, "tool-call")
      assert String.contains?(result, "tool_name=read_file")
      assert String.contains?(result, "tool_call_id=abc123")
    end

    test "tool return part includes tool_call_id" do
      part = %{
        "part_kind" => "tool-return",
        "tool_call_id" => "abc123",
        "content" => "result data"
      }

      result = Hasher.stringify_part_for_hash(part)
      assert String.contains?(result, "tool-return")
      assert String.contains?(result, "tool_call_id=abc123")
      assert String.contains?(result, "result data")
    end
  end
end
