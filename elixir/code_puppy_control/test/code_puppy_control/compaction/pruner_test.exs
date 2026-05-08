defmodule CodePuppyControl.Compaction.PrunerExtendedTest do
  @moduledoc """
  Extended pruner tests ported from test_message_transport.py and
  test_message_integration.py.

  Covers deeper behavioral contracts for prune_and_filter,
  truncation_indices, and split_for_summarization.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messages.Pruner
  alias CodePuppyControl.Messages.Serializer

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
        %{"part_kind" => "tool-return", "tool_call_id" => call_id, "content" => content}
      ]
    }
  end

  # ===========================================================================
  # prune_and_filter - extended tests
  # ===========================================================================

  describe "prune_and_filter/2 - integrity" do
    test "surviving messages are completely intact" do
      messages = [
        text_msg("First message - must survive"),
        tool_call_msg("orphaned_tool", "orphan-123", %{"some" => "data"}),
        text_msg("Third message - must survive")
      ]

      result = Pruner.prune_and_filter(messages)

      assert 0 in result.surviving_indices
      assert 2 in result.surviving_indices
      assert 1 not in result.surviving_indices

      surviving = Enum.map(result.surviving_indices, &Enum.at(messages, &1))
      first = hd(surviving)
      third = List.last(surviving)

      assert first["kind"] == "request"
      assert first["role"] == "user"
      assert hd(first["parts"])["content"] == "First message - must survive"

      assert third["kind"] == "request"
      assert third["role"] == "user"
      assert hd(third["parts"])["content"] == "Third message - must survive"
    end

    test "complete conversation preserves all messages" do
      messages = [
        text_msg("Call a tool"),
        tool_call_msg("test_tool", "call_001"),
        tool_return_msg("call_001", "Tool result"),
        text_msg("Done!")
      ]

      result = Pruner.prune_and_filter(messages)

      assert result.dropped_count == 0
      assert result.had_pending_tool_calls == false
      assert length(result.surviving_indices) == 4

      for i <- result.surviving_indices do
        msg = Enum.at(messages, i)
        assert msg["kind"] in ["request", "response"]
        assert length(msg["parts"]) > 0
      end
    end

    test "oversized message dropped, others preserved intact" do
      huge = String.duplicate("x", 60_000)

      messages = [
        text_msg("Small message 1"),
        text_msg(huge),
        text_msg("Small message 3")
      ]

      # 60k chars ≈ 15k tokens, so use a low threshold to trigger the drop
      result = Pruner.prune_and_filter(messages, 10_000)

      assert 1 not in result.surviving_indices
      assert 0 in result.surviving_indices
      assert 2 in result.surviving_indices

      surviving = Enum.map(result.surviving_indices, &Enum.at(messages, &1))
      assert hd(surviving)["parts"] |> hd() |> Map.get("content") == "Small message 1"
      assert List.last(surviving)["parts"] |> hd() |> Map.get("content") == "Small message 3"
    end
  end

  # ===========================================================================
  # truncation_indices - extended tests
  # ===========================================================================

  describe "truncation_indices/3 - extended" do
    test "single message returns just index 0" do
      assert Pruner.truncation_indices([500], 100, false) == [0]
    end

    test "budget larger than total includes all indices" do
      tokens = [100, 200, 300]
      result = Pruner.truncation_indices(tokens, 1000, false)
      assert result == [0, 1, 2]
    end

    test "tight budget keeps first and last only" do
      tokens = [100, 500, 100]
      result = Pruner.truncation_indices(tokens, 250, false)
      assert 0 in result
      assert 2 in result
      refute 1 in result
    end
  end

  # ===========================================================================
  # split_for_summarization - extended tests
  # ===========================================================================

  describe "split_for_summarization/3 - extended" do
    test "protects tool call pairs across boundary" do
      messages = [
        text_msg("sys"),
        tool_call_msg("tool", "A"),
        text_msg("gap"),
        tool_return_msg("A", "result"),
        text_msg("end")
      ]

      result = Pruner.split_for_summarization([10, 10, 10, 10, 10], messages, 35)
      assert 0 in result.protected_indices
      assert result.protected_token_count > 0
    end

    test "sufficient budget protects all messages" do
      tokens = [100, 200, 300]
      messages = Enum.map(1..3, &text_msg("msg #{&1}"))

      result = Pruner.split_for_summarization(tokens, messages, 1000)
      assert result.summarize_indices == []
      assert result.protected_indices == [0, 1, 2]
    end
  end

  # ===========================================================================
  # Serialize → Prune pipeline
  # ===========================================================================

  describe "serialize then prune pipeline" do
    test "messages survive serialize → deserialize → prune pipeline" do
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

    test "prune after round-trip handles orphaned tool calls correctly" do
      messages = [
        text_msg("Start"),
        tool_call_msg("orphan", "no-return")
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      result = Pruner.prune_and_filter(restored)
      assert 0 in result.surviving_indices
      assert 1 not in result.surviving_indices
    end
  end

  # ===========================================================================
  # Prune → Serialize pipeline
  # ===========================================================================

  describe "prune then serialize pipeline" do
    test "pruned messages serialize correctly" do
      messages = [
        text_msg("Keep this"),
        tool_call_msg("orphan", "no-return"),
        text_msg("Also keep this")
      ]

      result = Pruner.prune_and_filter(messages)
      surviving = Enum.map(result.surviving_indices, &Enum.at(messages, &1))

      {:ok, data} = Serializer.serialize_session(surviving)
      {:ok, restored} = Serializer.deserialize_session(data)

      assert length(restored) == 2
    end
  end
end
