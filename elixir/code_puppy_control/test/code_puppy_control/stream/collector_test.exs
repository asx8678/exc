defmodule CodePuppyControl.Stream.CollectorTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Stream.Collector
  alias CodePuppyControl.Stream.Event

  describe "new/0" do
    test "creates empty collector" do
      collector = Collector.new()
      assert collector.text_parts == %{}
      assert collector.tool_call_parts == %{}
      assert collector.id == nil
    end
  end

  describe "collect/2 - text events" do
    test "accumulates text deltas" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.TextStart{index: 0, id: nil})
        |> Collector.collect(%Event.TextDelta{index: 0, text: "Hello "})
        |> Collector.collect(%Event.TextDelta{index: 0, text: "world!"})
        |> Collector.collect(%Event.TextEnd{index: 0, id: nil})

      response = Collector.to_response(collector)
      assert response.content == "Hello world!"
    end

    test "handles multiple text blocks" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.TextDelta{index: 0, text: "First "})
        |> Collector.collect(%Event.TextDelta{index: 1, text: "Second"})

      response = Collector.to_response(collector)
      assert response.content == "First Second"
    end
  end

  describe "collect/2 - tool call events" do
    test "assembles complete tool call" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.ToolCallStart{index: 0, id: "tc-1", name: "exec"})
        |> Collector.collect(%Event.ToolCallArgsDelta{index: 0, arguments: "{\"cmd\":"})
        |> Collector.collect(%Event.ToolCallArgsDelta{index: 0, arguments: " \"ls\"}"})
        |> Collector.collect(%Event.ToolCallEnd{
          index: 0,
          id: "tc-1",
          name: "exec",
          arguments: ""
        })

      response = Collector.to_response(collector)
      assert length(response.tool_calls) == 1
      [tc] = response.tool_calls
      assert tc.id == "tc-1"
      assert tc.name == "exec"
      assert tc.arguments == %{"cmd" => "ls"}
    end

    test "handles multiple tool calls" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.ToolCallStart{index: 0, id: "tc-1", name: "read"})
        |> Collector.collect(%Event.ToolCallArgsDelta{index: 0, arguments: "{\"path\": \"/a\"}"})
        |> Collector.collect(%Event.ToolCallStart{index: 1, id: "tc-2", name: "write"})
        |> Collector.collect(%Event.ToolCallArgsDelta{index: 1, arguments: "{\"path\": \"/b\"}"})
        |> Collector.collect(%Event.ToolCallEnd{
          index: 0,
          id: "tc-1",
          name: "read",
          arguments: ""
        })
        |> Collector.collect(%Event.ToolCallEnd{
          index: 1,
          id: "tc-2",
          name: "write",
          arguments: ""
        })

      response = Collector.to_response(collector)
      assert length(response.tool_calls) == 2
      assert Enum.at(response.tool_calls, 0).name == "read"
      assert Enum.at(response.tool_calls, 1).name == "write"
    end
  end

  describe "collect/2 - interleaved events" do
    test "handles text and tool calls interleaved" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.TextDelta{index: 0, text: "Let me "})
        |> Collector.collect(%Event.ToolCallStart{index: 0, id: "tc-1", name: "exec"})
        |> Collector.collect(%Event.ToolCallArgsDelta{index: 0, arguments: "{}"})
        |> Collector.collect(%Event.TextDelta{index: 0, text: "check"})
        |> Collector.collect(%Event.ToolCallEnd{
          index: 0,
          id: "tc-1",
          name: "exec",
          arguments: ""
        })

      response = Collector.to_response(collector)
      assert response.content == "Let me check"
      assert length(response.tool_calls) == 1
    end
  end

  describe "collect/2 - done event" do
    test "captures response metadata" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.TextDelta{index: 0, text: "Hi"})
        |> Collector.collect(%Event.Done{
          id: "msg-1",
          model: "gpt-4o",
          finish_reason: "stop",
          usage: %Event.UsageUpdate{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
        })

      response = Collector.to_response(collector)
      assert response.id == "msg-1"
      assert response.model == "gpt-4o"
      assert response.finish_reason == "stop"
      assert response.usage.prompt_tokens == 10
    end
  end

  describe "collect/2 - usage events" do
    test "captures standalone usage update" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.UsageUpdate{
          prompt_tokens: 100,
          completion_tokens: 50,
          total_tokens: 150
        })

      response = Collector.to_response(collector)
      assert response.usage == %{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150}
    end
  end

  describe "to_response/1" do
    test "returns empty response for empty collector" do
      response = Collector.to_response(Collector.new())
      assert response.content == nil
      assert response.tool_calls == []
      assert response.id == ""
      assert response.model == ""
    end

    test "handles empty text parts" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.TextStart{index: 0, id: nil})
        |> Collector.collect(%Event.TextEnd{index: 0, id: nil})

      response = Collector.to_response(collector)
      assert response.content == nil
    end
  end

  describe "collect_stream/1" do
    test "one-shot collection from event list" do
      events = [
        %Event.TextDelta{index: 0, text: "Hello"},
        %Event.ToolCallStart{index: 0, id: "tc-1", name: "exec"},
        %Event.ToolCallArgsDelta{index: 0, arguments: "{}"},
        %Event.ToolCallEnd{index: 0, id: "tc-1", name: "exec", arguments: ""},
        %Event.Done{
          id: "msg-1",
          model: "gpt-4o",
          finish_reason: "stop",
          usage: %Event.UsageUpdate{prompt_tokens: 1, completion_tokens: 2, total_tokens: 3}
        }
      ]

      response = Collector.collect_stream(events)
      assert response.content == "Hello"
      assert length(response.tool_calls) == 1
      assert response.id == "msg-1"
    end
  end
end
