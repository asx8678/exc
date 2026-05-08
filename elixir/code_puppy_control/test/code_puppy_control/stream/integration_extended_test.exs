defmodule CodePuppyControl.Stream.IntegrationExtendedTest do
  @moduledoc """
  Extended stream integration tests ported from test_stream_parser.py and
  test_tui_stream_renderer.py behavioral contracts.

  Covers end-to-end streaming pipelines:
  - Normalizer → Collector pipeline
  - Collector edge cases (thinking events, usage, empty content)
  - Wire round-trip with complex events
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.Stream.Normalizer
  alias CodePuppyControl.Stream.Collector

  # ===========================================================================
  # Normalizer → Collector pipeline
  # ===========================================================================

  describe "normalizer → collector pipeline" do
    test "text stream events accumulate in collector" do
      events =
        [
          {:part_start, %{type: :text, index: 0, id: nil}},
          {:part_delta, %{type: :text, index: 0, text: "Hello ", name: nil, arguments: nil}},
          {:part_delta, %{type: :text, index: 0, text: "world!", name: nil, arguments: nil}},
          {:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}},
          {:done, %{id: "msg-1", model: "gpt-4o", finish_reason: "stop"}}
        ]
        |> Enum.map(&Normalizer.convert/1)
        |> Enum.filter(fn
          {:ok, _} -> true
          :skip -> false
        end)
        |> Enum.map(fn {:ok, e} -> e end)

      response = Collector.collect_stream(events)
      assert response.content == "Hello world!"
      assert response.id == "msg-1"
    end

    test "tool call stream events assemble correctly" do
      events =
        [
          {:part_start, %{type: :tool_call, index: 0, id: "tc-1"}},
          {:part_delta, %{type: :tool_call, index: 0, text: nil, name: "exec", arguments: nil}},
          {:part_delta,
           %{
             type: :tool_call,
             index: 0,
             text: nil,
             name: nil,
             arguments: Jason.encode!(%{"cmd" => "ls"})
           }},
          {:part_end,
           %{
             type: :tool_call,
             index: 0,
             id: "tc-1",
             name: "exec",
             arguments: Jason.encode!(%{"cmd" => "ls"})
           }},
          {:done, %{id: "msg-2", model: "gpt-4o", finish_reason: "stop"}}
        ]
        |> Enum.map(&Normalizer.convert/1)
        |> Enum.filter(fn
          {:ok, _} -> true
          :skip -> false
        end)
        |> Enum.map(fn {:ok, e} -> e end)

      response = Collector.collect_stream(events)
      assert length(response.tool_calls) == 1
      [tc] = response.tool_calls
      assert tc.name == "exec"
      assert tc.id == "tc-1"
    end

    test "interleaved text and tool call stream" do
      events =
        [
          {:part_start, %{type: :text, index: 0, id: nil}},
          {:part_delta, %{type: :text, index: 0, text: "Let me ", name: nil, arguments: nil}},
          {:part_start, %{type: :tool_call, index: 0, id: "tc-1"}},
          {:part_delta, %{type: :text, index: 0, text: "check", name: nil, arguments: nil}},
          {:part_delta, %{type: :tool_call, index: 0, text: nil, name: "exec", arguments: nil}},
          {:part_delta, %{type: :tool_call, index: 0, text: nil, name: nil, arguments: "{}"}},
          {:part_end, %{type: :tool_call, index: 0, id: "tc-1", name: "exec", arguments: "{}"}},
          {:done, %{id: "msg-3", model: "gpt-4o", finish_reason: "stop"}}
        ]
        |> Enum.map(&Normalizer.convert/1)
        |> Enum.filter(fn
          {:ok, _} -> true
          :skip -> false
        end)
        |> Enum.map(fn {:ok, e} -> e end)

      response = Collector.collect_stream(events)
      assert response.content == "Let me check"
      assert length(response.tool_calls) == 1
    end
  end

  # ===========================================================================
  # Collector edge cases
  # ===========================================================================

  describe "collector edge cases" do
    test "thinking events are collected without crashing" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.ThinkingStart{index: 0, id: nil})
        |> Collector.collect(%Event.ThinkingDelta{index: 0, text: "Hmm..."})
        |> Collector.collect(%Event.ThinkingEnd{index: 0, id: nil})
        |> Collector.collect(%Event.TextDelta{index: 0, text: "Answer"})
        |> Collector.collect(%Event.Done{id: "1", model: "m", finish_reason: "stop", usage: nil})

      response = Collector.to_response(collector)
      assert response.content == "Answer"
    end

    test "usage update is captured" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.TextDelta{index: 0, text: "Hi"})
        |> Collector.collect(%Event.UsageUpdate{
          prompt_tokens: 100,
          completion_tokens: 50,
          total_tokens: 150
        })
        |> Collector.collect(%Event.Done{id: "1", model: "m", finish_reason: "stop", usage: nil})

      response = Collector.to_response(collector)
      assert response.usage.prompt_tokens == 100
      assert response.usage.completion_tokens == 50
    end

    test "Done with usage captures both" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.TextDelta{index: 0, text: "Hi"})
        |> Collector.collect(%Event.Done{
          id: "1",
          model: "gpt-4o",
          finish_reason: "stop",
          usage: %Event.UsageUpdate{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
        })

      response = Collector.to_response(collector)
      assert response.id == "1"
      assert response.model == "gpt-4o"
      assert response.finish_reason == "stop"
      assert response.usage.prompt_tokens == 10
    end

    test "empty collector produces empty response" do
      response = Collector.to_response(Collector.new())
      assert response.content == nil
      assert response.tool_calls == []
      assert response.id == ""
    end

    test "ToolCallEnd with authoritative arguments replaces delta chunks" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.ToolCallStart{index: 0, id: "tc-1", name: "exec"})
        |> Collector.collect(%Event.ToolCallArgsDelta{
          index: 0,
          arguments: Jason.encode!(%{"cmd" => "ls"})
        })
        |> Collector.collect(%Event.ToolCallEnd{
          index: 0,
          id: "tc-1",
          name: "exec",
          arguments: Jason.encode!(%{"cmd" => "rm -rf"})
        })

      response = Collector.to_response(collector)
      [tc] = response.tool_calls
      # ToolCallEnd's authoritative arguments should replace delta chunks
      assert tc.arguments == %{"cmd" => "rm -rf"}
    end

    test "ToolCallEnd without arguments keeps accumulated deltas" do
      collector =
        Collector.new()
        |> Collector.collect(%Event.ToolCallStart{index: 0, id: "tc-1", name: "exec"})
        |> Collector.collect(%Event.ToolCallArgsDelta{
          index: 0,
          arguments: Jason.encode!(%{"cmd" => "ls"})
        })
        |> Collector.collect(%Event.ToolCallEnd{
          index: 0,
          id: "tc-1",
          name: "exec",
          arguments: ""
        })

      response = Collector.to_response(collector)
      [tc] = response.tool_calls
      # Should use accumulated deltas
      assert tc.arguments == %{"cmd" => "ls"}
    end
  end

  # ===========================================================================
  # Wire round-trip with complex payloads
  # ===========================================================================

  describe "wire round-trip with complex payloads" do
    test "ToolCallEnd with JSON arguments survives round-trip" do
      event = %Event.ToolCallEnd{
        index: 0,
        id: "tc-1",
        name: "read_file",
        arguments: Jason.encode!(%{"file_path" => "/path/to/file.ex", "offset" => 10})
      }

      wire = Event.to_wire(event)
      json = Jason.encode!(wire)
      decoded = Jason.decode!(json)
      assert {:ok, ^event} = Event.from_wire(decoded)
    end

    test "Done with nested usage survives full round-trip" do
      event = %Event.Done{
        id: "msg-1",
        model: "claude-3.5-sonnet",
        finish_reason: "stop",
        usage: %Event.UsageUpdate{
          prompt_tokens: 5000,
          completion_tokens: 1500,
          total_tokens: 6500
        }
      }

      wire = Event.to_wire(event)
      json = Jason.encode!(wire)
      decoded = Jason.decode!(json)
      assert {:ok, restored} = Event.from_wire(decoded)
      assert restored.id == "msg-1"
      assert restored.usage.prompt_tokens == 5000
    end

    test "TextDelta with special characters survives round-trip" do
      event = %Event.TextDelta{index: 0, text: "Hello 🌍! ñáéíóú «» \n\t\r"}

      wire = Event.to_wire(event)
      json = Jason.encode!(wire)
      decoded = Jason.decode!(json)
      assert {:ok, ^event} = Event.from_wire(decoded)
    end
  end

  # ===========================================================================
  # from_llm edge cases
  # ===========================================================================

  describe "from_llm/1 - edge cases" do
    test "done with string-keyed response" do
      response = %{
        "id" => "msg-1",
        "model" => "gpt-4o",
        "finish_reason" => "stop",
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "total_tokens" => 15
        }
      }

      assert {:ok, %Event.Done{} = done} = Event.from_llm({:done, response})
      assert done.id == "msg-1"
      assert done.model == "gpt-4o"
      assert done.usage.prompt_tokens == 10
    end

    test "done with minimal response" do
      assert {:ok, %Event.Done{} = done} = Event.from_llm({:done, %{}})
      assert done.id == nil
      assert done.usage == nil
    end

    test "text delta with nil text defaults to empty string" do
      assert {:ok, %Event.TextDelta{text: ""}} =
               Event.from_llm(
                 {:part_delta, %{type: :text, index: 0, text: nil, name: nil, arguments: nil}}
               )
    end

    test "tool_call delta with empty name and empty arguments is skipped" do
      assert :skip =
               Event.from_llm(
                 {:part_delta, %{type: :tool_call, index: 0, text: nil, name: "", arguments: ""}}
               )
    end
  end

  # ===========================================================================
  # Normalizer pass-through and contract
  # ===========================================================================

  describe "normalizer edge cases" do
    test "legacy :text chunk normalizes to TextDelta" do
      assert {:ok, %Event.TextDelta{index: 0, text: "Hello"}} =
               Normalizer.convert({:text, "Hello"})
    end

    test "legacy :tool_call normalizes to ToolCallEnd" do
      assert {:ok, %Event.ToolCallEnd{index: 0, id: "tc-1", name: "exec"}} =
               Normalizer.convert({:tool_call, "exec", %{"cmd" => "ls"}, "tc-1"})
    end

    test "legacy :done normalizes to Done" do
      assert {:ok, %Event.Done{}} = Normalizer.convert({:done, :complete})
    end

    test "unknown event returns :skip" do
      assert :skip = Normalizer.convert({:error, "something"})
      assert :skip = Normalizer.convert(:random_atom)
      assert :skip = Normalizer.convert(42)
    end
  end
end
