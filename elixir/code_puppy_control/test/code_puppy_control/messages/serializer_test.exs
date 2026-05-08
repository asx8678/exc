defmodule CodePuppyControl.Messages.SerializerTest do
  use ExUnit.Case
  alias CodePuppyControl.Messages.Serializer

  describe "round-trip serialization" do
    test "serialize then deserialize produces same messages" do
      messages = [
        %{
          "kind" => "request",
          "role" => "user",
          "instructions" => nil,
          "parts" => [
            %{
              "part_kind" => "text",
              "content" => "hello",
              "content_json" => nil,
              "tool_call_id" => nil,
              "tool_name" => nil,
              "args" => nil
            }
          ]
        }
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      assert is_binary(data)
      assert byte_size(data) > 0

      {:ok, restored} = Serializer.deserialize_session(data)
      assert restored == messages
    end

    test "incremental serialization appends correctly" do
      # First batch of messages
      messages1 = [
        %{
          "kind" => "request",
          "role" => "user",
          "instructions" => nil,
          "parts" => [
            %{
              "part_kind" => "text",
              "content" => "first message",
              "content_json" => nil,
              "tool_call_id" => nil,
              "tool_name" => nil,
              "args" => nil
            }
          ]
        }
      ]

      # Second batch of messages
      messages2 = [
        %{
          "kind" => "response",
          "role" => "assistant",
          "instructions" => nil,
          "parts" => [
            %{
              "part_kind" => "text",
              "content" => "second message",
              "content_json" => nil,
              "tool_call_id" => nil,
              "tool_name" => nil,
              "args" => nil
            }
          ]
        }
      ]

      # Serialize first batch
      {:ok, data1} = Serializer.serialize_session(messages1)

      # Incrementally append second batch
      {:ok, combined_data} = Serializer.serialize_session_incremental(messages2, data1)

      # Deserialize and verify both messages are present
      {:ok, restored} = Serializer.deserialize_session(combined_data)
      assert length(restored) == 2
      assert Enum.at(restored, 0) == Enum.at(messages1, 0)
      assert Enum.at(restored, 1) == Enum.at(messages2, 0)
    end

    test "incremental serialization with nil existing_data is same as fresh serialize" do
      messages = [
        %{
          "kind" => "request",
          "role" => "user",
          "instructions" => nil,
          "parts" => []
        }
      ]

      {:ok, fresh_data} = Serializer.serialize_session(messages)
      {:ok, incremental_data} = Serializer.serialize_session_incremental(messages, nil)

      assert fresh_data == incremental_data
    end

    test "empty message list" do
      messages = []

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      assert restored == []
    end

    test "messages with tool calls" do
      messages = [
        %{
          "kind" => "request",
          "role" => "user",
          "instructions" => nil,
          "parts" => [
            %{
              "part_kind" => "tool_call",
              "content" => nil,
              "content_json" => ~s({"arg": "value"}),
              "tool_call_id" => "call_123",
              "tool_name" => "some_tool",
              "args" => nil
            }
          ]
        },
        %{
          "kind" => "response",
          "role" => "tool",
          "instructions" => nil,
          "parts" => [
            %{
              "part_kind" => "tool_result",
              "content" => "tool output",
              "content_json" => nil,
              "tool_call_id" => "call_123",
              "tool_name" => nil,
              "args" => nil
            }
          ]
        }
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      assert restored == messages
    end

    test "handles nil fields gracefully" do
      messages = [
        %{
          "kind" => "request",
          "role" => nil,
          "instructions" => nil,
          "parts" => [
            %{
              "part_kind" => "text",
              "content" => nil,
              "content_json" => nil,
              "tool_call_id" => nil,
              "tool_name" => nil,
              "args" => nil
            }
          ]
        }
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      assert restored == messages
    end

    test "multiple parts in single message" do
      messages = [
        %{
          "kind" => "request",
          "role" => "user",
          "instructions" => nil,
          "parts" => [
            %{
              "part_kind" => "text",
              "content" => "part 1",
              "content_json" => nil,
              "tool_call_id" => nil,
              "tool_name" => nil,
              "args" => nil
            },
            %{
              "part_kind" => "text",
              "content" => "part 2",
              "content_json" => nil,
              "tool_call_id" => nil,
              "tool_name" => nil,
              "args" => nil
            }
          ]
        }
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      assert restored == messages
      assert length(Enum.at(restored, 0)["parts"]) == 2
    end

    test "complex nested content" do
      messages = [
        %{
          "kind" => "request",
          "role" => "user",
          "instructions" => "some instructions",
          "parts" => [
            %{
              "part_kind" => "text",
              "content" =>
                "Hello, world! This is a longer message with special chars: äöü € 日本語 🎉",
              "content_json" => nil,
              "tool_call_id" => nil,
              "tool_name" => nil,
              "args" => nil
            }
          ]
        }
      ]

      {:ok, data} = Serializer.serialize_session(messages)
      {:ok, restored} = Serializer.deserialize_session(data)

      assert restored == messages
    end
  end

  describe "error handling" do
    test "deserialize invalid data returns error" do
      invalid_data = <<0xFF, 0xFF, 0xFF>>
      assert {:error, _} = Serializer.deserialize_session(invalid_data)
    end

    test "deserialize empty binary returns error" do
      assert {:error, _} = Serializer.deserialize_session("")
    end
  end
end
