defmodule CodePuppyControl.Agent.ToolDispatchTest do
  @moduledoc """
  Unit tests for ToolDispatch.sanitize_tool_call_id/1
  and ToolDispatch.sanitize_tool_call_ids/1.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.Loop.ToolDispatch

  @valid_chars ~r/^[A-Za-z0-9_-]+$/

  describe "sanitize_tool_call_id/1" do
    test "passes through valid IDs unchanged" do
      assert ToolDispatch.sanitize_tool_call_id("call_abc123") == "call_abc123"
    end

    test "passes through IDs with dashes and underscores" do
      id = "call_my-tool_v2"
      assert ToolDispatch.sanitize_tool_call_id(id) == id
    end

    test "replaces empty string with generated ID" do
      result = ToolDispatch.sanitize_tool_call_id("")
      assert result != ""
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces nil with generated ID" do
      result = ToolDispatch.sanitize_tool_call_id(nil)
      assert result != ""
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces ID with invalid characters (dots)" do
      result = ToolDispatch.sanitize_tool_call_id("call.123")
      assert result != "call.123"
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces ID with invalid characters (colons, slashes)" do
      result = ToolDispatch.sanitize_tool_call_id("abc:def/ghi")
      assert result != "abc:def/ghi"
      refute result =~ ":"
      refute result =~ "/"
      assert Regex.match?(@valid_chars, result)
    end

    test "generates unique IDs for repeated calls with nil input" do
      ids = Enum.map(1..10, fn _ -> ToolDispatch.sanitize_tool_call_id(nil) end)
      assert length(Enum.uniq(ids)) == 10, "Generated IDs must be unique"
    end
  end

  describe "sanitize_tool_call_ids/1" do
    test "sanitizes list of tool calls with mixed valid and invalid IDs" do
      tool_calls = [
        %{id: "valid_id", name: :tool_a, arguments: %{}},
        %{id: "", name: :tool_b, arguments: %{}},
        %{id: "bad.chars", name: :tool_c, arguments: %{}}
      ]

      result = ToolDispatch.sanitize_tool_call_ids(tool_calls)

      assert length(result) == 3

      # First: valid, unchanged
      assert Enum.at(result, 0).id == "valid_id"

      # Second: empty → generated
      id2 = Enum.at(result, 1).id
      assert id2 != ""
      assert Regex.match?(@valid_chars, id2)

      # Third: invalid chars → generated
      id3 = Enum.at(result, 2).id
      assert id3 != "bad.chars"
      assert Regex.match?(@valid_chars, id3)
    end

    test "returns empty list for empty input" do
      assert ToolDispatch.sanitize_tool_call_ids([]) == []
    end

    test "preserves name and arguments fields" do
      tool_calls = [%{id: "", name: :echo_tool, arguments: %{"input" => "hello"}}]

      [result] = ToolDispatch.sanitize_tool_call_ids(tool_calls)

      assert result.name == :echo_tool
      assert result.arguments == %{"input" => "hello"}
      assert Regex.match?(@valid_chars, result.id)
    end
  end
end
