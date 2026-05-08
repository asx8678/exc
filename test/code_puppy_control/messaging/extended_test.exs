defmodule CodePuppyControl.Messaging.ExtendedTest do
  @moduledoc """
  Port of test_messaging_extended.py — message queue extended functionality.

  Covers message types, groups, buffering, concurrent access,
  queue lifecycle, and UIMessage creation. Adapted from Python threading
  model to Elixir's process/concurrent model.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messages.{Hasher, Pruner, Serializer}

  # ---------------------------------------------------------------------------
  # Helpers — use string-keyed maps (matching Messages.Pruner convention)
  # ---------------------------------------------------------------------------

  defp sample_message(type \\ "info", content \\ "Test message", meta \\ %{}) do
    %{
      "kind" => "request",
      "role" => "user",
      "parts" => [
        %{"part_kind" => "text", "content" => content}
      ],
      "_meta" => Map.merge(%{"type" => type}, meta)
    }
  end

  # ---------------------------------------------------------------------------
  # Message types and rendering helpers
  # ---------------------------------------------------------------------------

  describe "message types" do
    test "each message type produces a valid hash" do
      types = [
        sample_message("info", "Info message"),
        sample_message("error", "Error message"),
        sample_message("success", "Success message"),
        sample_message("warning", "Warning message"),
        sample_message("tool_output", "Tool output"),
        sample_message("command_output", "Command output"),
        sample_message("agent_reasoning", "Agent reasoning"),
        sample_message("system", "System message"),
        sample_message("divider", "---")
      ]

      for msg <- types do
        hash = Hasher.hash_message(msg)
        assert is_integer(hash)
        assert hash >= 0
      end

      # All different content should produce different hashes
      hashes = Enum.map(types, &Hasher.hash_message/1)
      assert length(Enum.uniq(hashes)) == length(hashes)
    end
  end

  # ---------------------------------------------------------------------------
  # Message groups and filtering
  # ---------------------------------------------------------------------------

  describe "message groups" do
    test "messages can be filtered by group metadata" do
      group_a = sample_message("info", "Group A message", %{"group" => "group_a"})
      group_b = sample_message("error", "Group B message", %{"group" => "group_b"})
      no_group = sample_message("success", "No group message")

      all = [group_a, group_b, no_group]

      group_a_msgs = Enum.filter(all, fn m -> get_in(m, ["_meta", "group"]) == "group_a" end)
      group_b_msgs = Enum.filter(all, fn m -> get_in(m, ["_meta", "group"]) == "group_b" end)
      no_group_msgs = Enum.filter(all, fn m -> get_in(m, ["_meta", "group"]) == nil end)

      assert length(group_a_msgs) == 1
      assert length(group_b_msgs) == 1
      assert length(no_group_msgs) == 1
    end

    test "filtering by group preserves multiple matches" do
      msgs = [
        sample_message("info", "M1", %{"group" => "alpha"}),
        sample_message("error", "M2", %{"group" => "beta"}),
        sample_message("success", "M3", %{"group" => "alpha"}),
        sample_message("warning", "M4")
      ]

      alpha = Enum.filter(msgs, fn m -> get_in(m, ["_meta", "group"]) == "alpha" end)
      assert length(alpha) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Queue clearing and FIFO ordering
  # ---------------------------------------------------------------------------

  describe "queue operations" do
    test "messages are processed in FIFO order" do
      msgs = [
        sample_message("info", "Msg 1"),
        sample_message("error", "Msg 2"),
        sample_message("success", "Msg 3")
      ]

      {:ok, data} = Serializer.serialize_session(msgs)
      {:ok, restored} = Serializer.deserialize_session(data)

      contents =
        Enum.map(restored, fn m ->
          m["parts"] |> hd() |> Map.get("content")
        end)

      assert contents == ["Msg 1", "Msg 2", "Msg 3"]
    end

    test "queue clearing via prune_and_filter" do
      msgs = [
        sample_message("info", "Message 1"),
        sample_message("error", "Message 2"),
        sample_message("success", "Message 3")
      ]

      result = Pruner.prune_and_filter(msgs)
      # All should survive (no orphaned tool calls)
      assert result.dropped_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Buffered messages before renderer
  # ---------------------------------------------------------------------------

  describe "buffering behavior" do
    test "messages buffered before pruning are still valid after" do
      msg1 = sample_message("info", "Buffered message 1")
      msg2 = sample_message("error", "Buffered message 2")

      {:ok, data} = Serializer.serialize_session([msg1, msg2])
      {:ok, restored} = Serializer.deserialize_session(data)

      assert length(restored) == 2
      # Check content survives
      contents =
        Enum.map(restored, fn m ->
          m["parts"] |> hd() |> Map.get("content")
        end)

      assert "Buffered message 1" in contents
      assert "Buffered message 2" in contents
    end

    test "serialization preserves message order (FIFO)" do
      msgs = for i <- 1..10, do: sample_message("info", "Message #{i}")

      {:ok, data} = Serializer.serialize_session(msgs)
      {:ok, restored} = Serializer.deserialize_session(data)

      contents =
        Enum.map(restored, fn m ->
          m["parts"] |> hd() |> Map.get("content")
        end)

      expected = Enum.map(1..10, &"Message #{&1}")
      assert contents == expected
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamps
  # ---------------------------------------------------------------------------

  describe "message timestamps" do
    test "serialized messages preserve temporal ordering" do
      msg1 = sample_message("info", "First")
      msg2 = sample_message("info", "Second")

      {:ok, data} = Serializer.serialize_session([msg1, msg2])
      {:ok, [first, second]} = Serializer.deserialize_session(data)

      # Order is preserved
      assert first["parts"] |> hd() |> Map.get("content") == "First"
      assert second["parts"] |> hd() |> Map.get("content") == "Second"
    end
  end

  # ---------------------------------------------------------------------------
  # UIMessage creation and defaults
  # ---------------------------------------------------------------------------

  describe "message creation" do
    test "minimal message with default fields" do
      msg = sample_message("info", "Test")

      assert msg["kind"] == "request"
      assert msg["role"] == "user"
      assert length(msg["parts"]) == 1
      assert hd(msg["parts"])["part_kind"] == "text"
    end

    test "message with custom metadata" do
      meta = %{"key" => "value", "count" => 42}
      msg = sample_message("info", "Test", meta)

      assert msg["_meta"]["key"] == "value"
      assert msg["_meta"]["count"] == 42
    end
  end

  # ---------------------------------------------------------------------------
  # Queue full behavior
  # ---------------------------------------------------------------------------

  describe "queue capacity" do
    test "prune_and_filter handles many messages" do
      msgs = for i <- 1..50, do: sample_message("info", "Msg #{i}")

      result = Pruner.prune_and_filter(msgs)
      assert result.dropped_count == 0
      assert length(result.surviving_indices) == 50
    end

    test "prune drops oversized messages" do
      huge_content = String.duplicate("x", 60_000)

      msgs = [
        sample_message("info", huge_content),
        sample_message("info", "Small message")
      ]

      # 60k chars ≈ 15k tokens; threshold of 10k should drop the big one
      result = Pruner.prune_and_filter(msgs, 10_000)
      assert 1 in result.surviving_indices
      assert 0 not in result.surviving_indices
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrent access (Elixir-native)
  # ---------------------------------------------------------------------------

  describe "concurrent access" do
    test "hash_message is safe from multiple processes" do
      msg = sample_message("info", "Concurrent test")

      tasks =
        for _i <- 1..10 do
          Task.async(fn -> Hasher.hash_message(msg) end)
        end

      results = Task.await_many(tasks, 5000)

      # All results should be identical (pure function)
      assert Enum.uniq(results) == [hd(results)]
    end

    test "serializer is safe from multiple processes" do
      msgs = [sample_message("info", "Concurrent serialization")]

      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            {:ok, data} = Serializer.serialize_session(msgs)
            {:ok, restored} = Serializer.deserialize_session(data)
            restored
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All results should be identical
      assert Enum.uniq(results) == [hd(results)]
    end
  end

  # ---------------------------------------------------------------------------
  # Divider messages
  # ---------------------------------------------------------------------------

  describe "divider messages" do
    test "divider content is preserved through serialization" do
      divider = String.duplicate("─", 100)
      msg = sample_message("divider", divider)

      {:ok, data} = Serializer.serialize_session([msg])
      {:ok, [restored]} = Serializer.deserialize_session(data)

      assert hd(restored["parts"])["content"] == divider
    end
  end
end
