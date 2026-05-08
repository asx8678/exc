defmodule CodePuppyControl.Messaging.MessagesTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.Messages — BaseMessage and TextMessage constructors.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.Messages

  # ===========================================================================
  # base_message/1
  # ===========================================================================

  describe "base_message/1" do
    test "creates message with auto-generated id and timestamp" do
      {:ok, msg} = Messages.base_message(%{"category" => "system"})

      assert is_binary(msg["id"])
      assert String.length(msg["id"]) == 32
      assert is_integer(msg["timestamp_unix_ms"])
      assert msg["timestamp_unix_ms"] > 0
    end

    test "preserves explicitly provided id" do
      {:ok, msg} = Messages.base_message(%{"category" => "system", "id" => "my-custom-id"})

      assert msg["id"] == "my-custom-id"
    end

    test "preserves explicitly provided integer timestamp" do
      ts = 1_713_123_456_789
      {:ok, msg} = Messages.base_message(%{"category" => "system", "timestamp_unix_ms" => ts})

      assert msg["timestamp_unix_ms"] == ts
    end

    test "rejects float timestamp_unix_ms" do
      assert {:error, {:invalid_timestamp_unix_ms, 1.5}} =
               Messages.base_message(%{"category" => "system", "timestamp_unix_ms" => 1.5})
    end

    test "rejects string timestamp_unix_ms" do
      assert {:error, {:invalid_timestamp_unix_ms, "1234"}} =
               Messages.base_message(%{"category" => "system", "timestamp_unix_ms" => "1234"})
    end

    test "sets run_id and session_id to nil by default" do
      {:ok, msg} = Messages.base_message(%{"category" => "agent"})

      assert msg["run_id"] == nil
      assert msg["session_id"] == nil
    end

    test "preserves run_id and session_id when provided" do
      {:ok, msg} =
        Messages.base_message(%{
          "category" => "agent",
          "run_id" => "run-abc",
          "session_id" => "sess-xyz"
        })

      assert msg["run_id"] == "run-abc"
      assert msg["session_id"] == "sess-xyz"
    end

    test "accepts all valid categories" do
      for cat <- ~w(system tool_output agent user_interaction divider) do
        assert {:ok, msg} = Messages.base_message(%{"category" => cat})
        assert msg["category"] == cat
      end
    end

    test "rejects missing category" do
      assert {:error, :missing_category} = Messages.base_message(%{})
    end

    test "rejects invalid category" do
      assert {:error, {:invalid_category, "nope"}} =
               Messages.base_message(%{"category" => "nope"})
    end

    test "rejects non-map input" do
      assert {:error, {:not_a_map, "hello"}} = Messages.base_message("hello")
    end

    test "auto-generated ids are unique across calls" do
      {:ok, m1} = Messages.base_message(%{"category" => "system"})
      {:ok, m2} = Messages.base_message(%{"category" => "system"})

      assert m1["id"] != m2["id"]
    end

    test "timestamps increase or stay equal across rapid calls" do
      {:ok, m1} = Messages.base_message(%{"category" => "system"})
      {:ok, m2} = Messages.base_message(%{"category" => "system"})

      assert m2["timestamp_unix_ms"] >= m1["timestamp_unix_ms"]
    end
  end

  # ===========================================================================
  # text_message/1
  # ===========================================================================

  describe "text_message/1" do
    test "creates TextMessage with required fields and defaults" do
      {:ok, msg} = Messages.text_message(%{"level" => "info", "text" => "Hello!"})

      assert msg["level"] == "info"
      assert msg["text"] == "Hello!"
      assert msg["category"] == "system"
      assert msg["is_markdown"] == false
      assert is_binary(msg["id"])
      assert is_integer(msg["timestamp_unix_ms"])
    end

    test "defaults category to system" do
      {:ok, msg} = Messages.text_message(%{"level" => "warning", "text" => "Watch out!"})

      assert msg["category"] == "system"
    end

    test "allows overriding category" do
      {:ok, msg} =
        Messages.text_message(%{
          "level" => "error",
          "text" => "Failed!",
          "category" => "agent"
        })

      assert msg["category"] == "agent"
    end

    test "allows setting is_markdown" do
      {:ok, msg} =
        Messages.text_message(%{
          "level" => "info",
          "text" => "# Heading",
          "is_markdown" => true
        })

      assert msg["is_markdown"] == true
    end

    test "generates id and timestamp when absent" do
      before = System.system_time(:millisecond)
      {:ok, msg} = Messages.text_message(%{"level" => "debug", "text" => "trace"})
      after_ms = System.system_time(:millisecond)

      assert is_binary(msg["id"])
      assert String.length(msg["id"]) == 32
      assert msg["timestamp_unix_ms"] >= before
      assert msg["timestamp_unix_ms"] <= after_ms
    end

    test "preserves explicit integer id and timestamp" do
      {:ok, msg} =
        Messages.text_message(%{
          "level" => "success",
          "text" => "Done!",
          "id" => "explicit-id",
          "timestamp_unix_ms" => 999_999
        })

      assert msg["id"] == "explicit-id"
      assert msg["timestamp_unix_ms"] == 999_999
    end

    test "rejects float timestamp_unix_ms" do
      assert {:error, {:invalid_timestamp_unix_ms, 1.5}} =
               Messages.text_message(%{
                 "level" => "info",
                 "text" => "Hi",
                 "timestamp_unix_ms" => 1.5
               })
    end

    test "rejects string timestamp_unix_ms" do
      assert {:error, {:invalid_timestamp_unix_ms, "1234"}} =
               Messages.text_message(%{
                 "level" => "info",
                 "text" => "Hi",
                 "timestamp_unix_ms" => "1234"
               })
    end

    test "accepts all valid levels" do
      for level <- ~w(debug info warning error success) do
        assert {:ok, msg} = Messages.text_message(%{"level" => level, "text" => "Test"})
        assert msg["level"] == level
      end
    end

    test "rejects missing level" do
      assert {:error, :missing_level} =
               Messages.text_message(%{"text" => "Hello"})
    end

    test "rejects invalid level" do
      assert {:error, {:invalid_level, "fatal"}} =
               Messages.text_message(%{"level" => "fatal", "text" => "Boom"})
    end

    test "rejects missing text" do
      assert {:error, :missing_text} =
               Messages.text_message(%{"level" => "info"})
    end

    test "rejects non-string text" do
      assert {:error, {:invalid_text, 123}} =
               Messages.text_message(%{"level" => "info", "text" => 123})
    end

    test "rejects invalid category" do
      assert {:error, {:invalid_category, "bad"}} =
               Messages.text_message(%{
                 "level" => "info",
                 "text" => "Hi",
                 "category" => "bad"
               })
    end

    test "rejects non-map input" do
      assert {:error, {:not_a_map, :oops}} = Messages.text_message(:oops)
    end

    test "sets run_id and session_id to nil by default" do
      {:ok, msg} = Messages.text_message(%{"level" => "info", "text" => "Test"})

      assert msg["run_id"] == nil
      assert msg["session_id"] == nil
    end

    test "preserves run_id and session_id" do
      {:ok, msg} =
        Messages.text_message(%{
          "level" => "info",
          "text" => "Test",
          "run_id" => "run-1",
          "session_id" => "sess-1"
        })

      assert msg["run_id"] == "run-1"
      assert msg["session_id"] == "sess-1"
    end
  end
end
