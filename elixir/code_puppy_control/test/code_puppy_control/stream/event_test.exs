defmodule CodePuppyControl.Stream.EventTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.Stream.Event.{TextStart, TextDelta, TextEnd}
  alias CodePuppyControl.Stream.Event.{ToolCallStart, ToolCallArgsDelta, ToolCallEnd}
  alias CodePuppyControl.Stream.Event.{ThinkingStart, ThinkingDelta, ThinkingEnd}
  alias CodePuppyControl.Stream.Event.{UsageUpdate, Done}

  # from_llm/1 - part_start events

  describe "from_llm/1 - part_start events" do
    test "converts text part_start" do
      assert {:ok, %TextStart{index: 0, id: nil}} =
               Event.from_llm({:part_start, %{type: :text, index: 0, id: nil}})
    end

    test "converts tool_call part_start" do
      assert {:ok, %ToolCallStart{index: 1, id: "tc-42", name: nil}} =
               Event.from_llm({:part_start, %{type: :tool_call, index: 1, id: "tc-42"}})
    end

    test "returns :skip for unknown type" do
      assert :skip = Event.from_llm({:part_start, %{type: :unknown, index: 0}})
    end
  end

  describe "from_llm/1 - part_delta events" do
    test "converts text part_delta" do
      assert {:ok, %TextDelta{index: 0, text: "Hello"}} =
               Event.from_llm(
                 {:part_delta, %{type: :text, index: 0, text: "Hello", name: nil, arguments: nil}}
               )
    end

    test "converts tool_call name delta as ToolCallStart" do
      assert {:ok, %ToolCallStart{index: 0, id: nil, name: "read_file"}} =
               Event.from_llm(
                 {:part_delta,
                  %{type: :tool_call, index: 0, text: nil, name: "read_file", arguments: nil}}
               )
    end

    test "converts tool_call arguments delta" do
      assert {:ok, %ToolCallArgsDelta{index: 0, arguments: "{\"path\":"}} =
               Event.from_llm(
                 {:part_delta,
                  %{type: :tool_call, index: 0, text: nil, name: nil, arguments: "{\"path\":"}}
               )
    end

    test "returns :skip for empty tool_call delta" do
      assert :skip =
               Event.from_llm(
                 {:part_delta,
                  %{type: :tool_call, index: 0, text: nil, name: nil, arguments: nil}}
               )
    end
  end

  describe "from_llm/1 - part_end events" do
    test "converts text part_end" do
      assert {:ok, %TextEnd{index: 0, id: nil}} =
               Event.from_llm(
                 {:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}}
               )
    end

    test "converts tool_call part_end" do
      assert {:ok, %ToolCallEnd{index: 1, id: "tc-1", name: "exec", arguments: "{}"}} =
               Event.from_llm(
                 {:part_end,
                  %{type: :tool_call, index: 1, id: "tc-1", name: "exec", arguments: "{}"}}
               )
    end
  end

  describe "from_llm/1 - done event" do
    test "converts done with full response" do
      response = %{
        id: "msg-1",
        model: "gpt-4o",
        content: "Hello!",
        tool_calls: [],
        finish_reason: "stop",
        usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      }

      assert {:ok, %Done{} = done} = Event.from_llm({:done, response})
      assert done.id == "msg-1"
      assert done.model == "gpt-4o"
      assert done.finish_reason == "stop"

      assert done.usage == %UsageUpdate{
               prompt_tokens: 10,
               completion_tokens: 5,
               total_tokens: 15
             }
    end

    test "converts done with minimal response" do
      assert {:ok, %Done{} = done} = Event.from_llm({:done, %{}})
      assert done.id == nil
      assert done.usage == nil
    end
  end

  describe "from_llm/1 - unknown events" do
    test "returns :skip for arbitrary tuples" do
      assert :skip = Event.from_llm({:ping})
      assert :skip = Event.from_llm({:error, "something"})
      assert :skip = Event.from_llm(:random_atom)
    end
  end

  # to_wire/1

  describe "to_wire/1" do
    test "serializes TextStart" do
      assert %{"type" => "text_start", "index" => 0, "id" => nil} =
               Event.to_wire(%TextStart{index: 0, id: nil})
    end

    test "serializes TextDelta" do
      assert %{"type" => "text_delta", "index" => 0, "text" => "hi"} =
               Event.to_wire(%TextDelta{index: 0, text: "hi"})
    end

    test "serializes TextEnd" do
      assert %{"type" => "text_end", "index" => 0, "id" => "block-1"} =
               Event.to_wire(%TextEnd{index: 0, id: "block-1"})
    end

    test "serializes ToolCallStart" do
      assert %{"type" => "tool_call_start", "index" => 0, "id" => "tc-1", "name" => "exec"} =
               Event.to_wire(%ToolCallStart{index: 0, id: "tc-1", name: "exec"})
    end

    test "serializes ToolCallArgsDelta" do
      wire = Event.to_wire(%ToolCallArgsDelta{index: 0, arguments: "{\"k\":"})
      assert wire["type"] == "tool_call_args_delta"
      assert wire["index"] == 0
      assert wire["arguments"] == "{\"k\":"
    end

    test "serializes ToolCallEnd" do
      wire = Event.to_wire(%ToolCallEnd{index: 0, id: "tc-1", name: "exec", arguments: "{}"})
      assert wire["type"] == "tool_call_end"
      assert wire["id"] == "tc-1"
      assert wire["name"] == "exec"
    end

    test "serializes ThinkingStart" do
      assert %{"type" => "thinking_start", "index" => 0, "id" => nil} =
               Event.to_wire(%ThinkingStart{index: 0, id: nil})
    end

    test "serializes ThinkingDelta" do
      assert %{"type" => "thinking_delta", "index" => 0, "text" => "thinking..."} =
               Event.to_wire(%ThinkingDelta{index: 0, text: "thinking..."})
    end

    test "serializes ThinkingEnd" do
      assert %{"type" => "thinking_end", "index" => 0, "id" => nil} =
               Event.to_wire(%ThinkingEnd{index: 0, id: nil})
    end

    test "serializes UsageUpdate" do
      wire =
        Event.to_wire(%UsageUpdate{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150})

      assert wire["type"] == "usage_update"
      assert wire["prompt_tokens"] == 100
    end

    test "serializes Done" do
      wire =
        Event.to_wire(%Done{
          id: "msg-1",
          model: "gpt-4o",
          finish_reason: "stop",
          usage: %UsageUpdate{prompt_tokens: 1, completion_tokens: 2, total_tokens: 3}
        })

      assert wire["type"] == "done"
      assert wire["id"] == "msg-1"
      assert wire["usage"]["type"] == "usage_update"
    end
  end

  # from_wire/1

  describe "from_wire/1" do
    test "roundtrips TextDelta" do
      original = %TextDelta{index: 0, text: "hello"}
      wire = Event.to_wire(original)
      assert {:ok, ^original} = Event.from_wire(wire)
    end

    test "roundtrips ToolCallEnd" do
      original = %ToolCallEnd{index: 1, id: "tc-1", name: "exec", arguments: "{}"}
      wire = Event.to_wire(original)
      assert {:ok, ^original} = Event.from_wire(wire)
    end

    test "roundtrips Done with usage" do
      original = %Done{
        id: "msg-1",
        model: "gpt-4o",
        finish_reason: "stop",
        usage: %UsageUpdate{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      }

      wire = Event.to_wire(original)
      assert {:ok, result} = Event.from_wire(wire)
      assert result.id == "msg-1"
      assert result.usage.prompt_tokens == 10
    end

    test "roundtrips UsageUpdate" do
      original = %UsageUpdate{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150}
      wire = Event.to_wire(original)
      assert {:ok, ^original} = Event.from_wire(wire)
    end

    test "returns error for unknown type" do
      assert {:error, :unknown_type} = Event.from_wire(%{"type" => "bogus"})
    end
  end

  # JSON serialization

  describe "JSON roundtrip" do
    test "all event types survive Jason encode/decode" do
      events = [
        %TextStart{index: 0, id: "b1"},
        %TextDelta{index: 0, text: "Hello world"},
        %TextEnd{index: 0, id: "b1"},
        %ToolCallStart{index: 0, id: "tc-1", name: "exec"},
        %ToolCallArgsDelta{index: 0, arguments: "{\"cmd\": \"ls\"}"},
        %ToolCallEnd{index: 0, id: "tc-1", name: "exec", arguments: "{\"cmd\": \"ls\"}"},
        %ThinkingStart{index: 0, id: nil},
        %ThinkingDelta{index: 0, text: "reasoning..."},
        %ThinkingEnd{index: 0, id: nil},
        %UsageUpdate{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15},
        %Done{
          id: "msg-1",
          model: "gpt-4o",
          finish_reason: "stop",
          usage: %UsageUpdate{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
        }
      ]

      for event <- events do
        wire = Event.to_wire(event)
        json = Jason.encode!(wire)
        decoded = Jason.decode!(json)
        assert {:ok, _restored} = Event.from_wire(decoded)
      end
    end
  end
end
