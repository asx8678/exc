defmodule CodePuppyControl.Compaction.ToolArgTruncationTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Compaction.ToolArgTruncation

  describe "truncate_value/3" do
    test "does not truncate short strings" do
      {result, modified?} = ToolArgTruncation.truncate_value("short string", 500)
      assert result == "short string"
      assert modified? == false
    end

    test "truncates long strings" do
      long = String.duplicate("a", 600)
      {result, modified?} = ToolArgTruncation.truncate_value(long, 500)

      assert modified? == true
      assert String.length(result) > 500
      assert result =~ "truncated"
    end

    test "handles non-string values" do
      {result, modified?} = ToolArgTruncation.truncate_value(42, 500)
      assert result == 42
      assert modified? == false
    end
  end

  describe "truncate_tool_call_args/3" do
    test "truncates content key for target tools" do
      long_content = String.duplicate("x", 600)

      args = %{
        "content" => long_content,
        "file_path" => "lib/test.ex"
      }

      {new_args, modified?} = ToolArgTruncation.truncate_tool_call_args("create_file", args)

      assert modified? == true
      assert String.length(new_args["content"]) < String.length(long_content)
      assert new_args["file_path"] == "lib/test.ex"
    end

    test "does not truncate non-target tools" do
      args = %{"content" => String.duplicate("x", 600)}
      {new_args, modified?} = ToolArgTruncation.truncate_tool_call_args("read_file", args)

      assert modified? == false
      assert new_args == args
    end

    test "truncates multiple target keys" do
      args = %{
        "old_string" => String.duplicate("a", 600),
        "new_string" => String.duplicate("b", 600)
      }

      {_new_args, modified?} = ToolArgTruncation.truncate_tool_call_args("replace_in_file", args)
      assert modified? == true
    end

    test "handles non-map args" do
      {result, modified?} = ToolArgTruncation.truncate_tool_call_args("create_file", "string_arg")
      assert modified? == false
      assert result == "string_arg"
    end
  end

  describe "truncate_tool_return_content/2" do
    test "does not truncate short content" do
      {result, modified?} = ToolArgTruncation.truncate_tool_return_content("short")
      assert result == "short"
      assert modified? == false
    end

    test "truncates long content preserving head and tail" do
      head = String.duplicate("H", 500)
      tail = String.duplicate("T", 200)
      middle = String.duplicate("M", 10000)
      content = head <> middle <> tail

      {result, modified?} = ToolArgTruncation.truncate_tool_return_content(content)

      assert modified? == true
      assert result =~ "[Truncated:"
      assert result =~ head
      assert result =~ tail
      assert String.length(result) < String.length(content)
    end

    test "handles non-string content" do
      {result, modified?} = ToolArgTruncation.truncate_tool_return_content(42)
      assert result == 42
      assert modified? == false
    end
  end

  describe "pretruncate_messages/2" do
    test "does not truncate recent messages" do
      messages = [
        %{
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_name" => "create_file",
              "args" => %{"content" => String.duplicate("x", 600)}
            }
          ]
        },
        %{"parts" => [%{"part_kind" => "text", "content" => "hello"}]}
      ]

      {result, count} = ToolArgTruncation.pretruncate_messages(messages, keep_recent: 10)

      # Too few messages to truncate (keep_recent: 10 > length: 2)
      assert count == 0
      assert length(result) == 2
    end

    test "truncates old messages, preserves recent" do
      old_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-call",
            "tool_name" => "create_file",
            "args" => %{"content" => String.duplicate("x", 600)}
          }
        ]
      }

      recent_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-call",
            "tool_name" => "create_file",
            "args" => %{"content" => String.duplicate("y", 600)}
          }
        ]
      }

      messages = List.duplicate(old_msg, 15) ++ [recent_msg]

      {result, count} = ToolArgTruncation.pretruncate_messages(messages, keep_recent: 1)

      # 15 old messages should be truncated
      assert count == 15
      assert length(result) == 16

      # Last message (recent) should be unchanged
      last = List.last(result)
      last_part = last["parts"] |> List.first()
      assert String.length(last_part["args"]["content"]) == 600

      # First message (old) should be truncated
      first = List.first(result)
      first_part = first["parts"] |> List.first()
      assert String.length(first_part["args"]["content"]) < 600
    end

    test "truncates tool return content in old messages" do
      old_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-return",
            "tool_call_id" => "tc-1",
            "content" => String.duplicate("R", 6000)
          }
        ]
      }

      recent_msg = %{"parts" => [%{"part_kind" => "text", "content" => "hi"}]}

      messages = List.duplicate(old_msg, 12) ++ [recent_msg]

      {result, count} = ToolArgTruncation.pretruncate_messages(messages, keep_recent: 1)

      assert count == 12

      # First message's return should be truncated
      first = List.first(result)
      first_part = first["parts"] |> List.first()
      assert first_part["content"] =~ "[Truncated:"
    end

    test "preserves tool pair integrity" do
      call_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-call",
            "tool_name" => "create_file",
            "tool_call_id" => "tc-1",
            "args" => %{"content" => String.duplicate("C", 600), "file_path" => "a.ex"}
          }
        ]
      }

      return_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-return",
            "tool_call_id" => "tc-1",
            "content" => String.duplicate("R", 6000)
          }
        ]
      }

      # Put tool pair in old section, recent msg after
      recent_msg = %{"parts" => [%{"part_kind" => "text", "content" => "ok"}]}
      messages = [call_msg, return_msg, recent_msg]

      {result, count} = ToolArgTruncation.pretruncate_messages(messages, keep_recent: 1)

      # Both old messages should be truncated
      assert count == 2

      # But both still present in result (pair integrity maintained)
      assert length(result) == 3

      # The tool call part should have truncated args
      first_parts = Enum.at(result, 0)["parts"]
      call_part = List.first(first_parts)
      assert String.length(call_part["args"]["content"]) < 600

      # The tool return should have truncated content
      second_parts = Enum.at(result, 1)["parts"]
      return_part = List.first(second_parts)
      assert return_part["content"] =~ "[Truncated:"
    end

    test "handles empty messages list" do
      {result, count} = ToolArgTruncation.pretruncate_messages([])
      assert result == []
      assert count == 0
    end

    test "handles messages with atom keys" do
      messages = [
        %{
          parts: [
            %{
              part_kind: "tool-call",
              tool_name: "create_file",
              args: %{"content" => String.duplicate("x", 600)}
            }
          ]
        }
      ]

      {result, _count} = ToolArgTruncation.pretruncate_messages(messages, keep_recent: 0)
      assert length(result) == 1
    end
  end

  describe "truncate_message_parts/2" do
    test "truncates tool-call and tool-return parts" do
      message = %{
        "parts" => [
          %{"part_kind" => "text", "content" => "unchanged"},
          %{
            "part_kind" => "tool-call",
            "tool_name" => "create_file",
            "args" => %{"content" => String.duplicate("x", 600)}
          },
          %{
            "part_kind" => "tool-return",
            "tool_call_id" => "tc-1",
            "content" => String.duplicate("r", 6000)
          }
        ]
      }

      result = ToolArgTruncation.truncate_message_parts(message)

      parts = result["parts"]
      assert length(parts) == 3

      # Text part unchanged
      assert Enum.at(parts, 0)["content"] == "unchanged"

      # Tool call args truncated
      assert String.length(Enum.at(parts, 1)["args"]["content"]) < 600

      # Tool return truncated
      assert Enum.at(parts, 2)["content"] =~ "[Truncated:"
    end

    test "returns original when nothing to truncate" do
      message = %{
        "parts" => [
          %{"part_kind" => "text", "content" => "short"}
        ]
      }

      result = ToolArgTruncation.truncate_message_parts(message)
      assert result == message
    end
  end
end
