defmodule CodePuppyControl.Stream.IntegrationTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Stream.{Event, Normalizer, Collector}

  describe "LLM Provider -> Normalizer -> Collector pipeline" do
    test "text-only OpenAI-style stream" do
      # Simulate OpenAI provider events
      provider_events = [
        {:part_start, %{type: :text, index: 0, id: nil}},
        {:part_delta, %{type: :text, index: 0, text: "Hello ", name: nil, arguments: nil}},
        {:part_delta, %{type: :text, index: 0, text: "world!", name: nil, arguments: nil}},
        {:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}},
        {:done,
         %{
           id: "msg-1",
           model: "gpt-4o",
           content: "Hello world!",
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
         }}
      ]

      # Normalize events
      canonical_events = normalize_events(provider_events)

      # Collect into response
      response = Collector.collect_stream(canonical_events)

      assert response.content == "Hello world!"
      assert response.id == "msg-1"
      assert response.model == "gpt-4o"
      assert response.finish_reason == "stop"
      assert response.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
    end

    test "tool call OpenAI-style stream" do
      provider_events = [
        {:part_start, %{type: :tool_call, index: 0, id: "tc-1"}},
        {:part_delta,
         %{type: :tool_call, index: 0, text: nil, name: "read_file", arguments: nil}},
        {:part_delta,
         %{type: :tool_call, index: 0, text: nil, name: nil, arguments: "{\"path\": \""}},
        {:part_delta,
         %{type: :tool_call, index: 0, text: nil, name: nil, arguments: "/tmp/test.txt\"}"}},
        {:part_end,
         %{
           type: :tool_call,
           index: 0,
           id: "tc-1",
           name: "read_file",
           arguments: "{\"path\": \"/tmp/test.txt\"}"
         }},
        {:done,
         %{
           id: "msg-2",
           model: "gpt-4o",
           content: nil,
           tool_calls: [],
           finish_reason: "tool_calls",
           usage: %{prompt_tokens: 20, completion_tokens: 10, total_tokens: 30}
         }}
      ]

      canonical_events = normalize_events(provider_events)
      response = Collector.collect_stream(canonical_events)

      assert response.content == nil
      assert length(response.tool_calls) == 1
      [tc] = response.tool_calls
      assert tc.id == "tc-1"
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "/tmp/test.txt"}
      assert response.finish_reason == "tool_calls"
    end

    test "text + tool call Anthropic-style stream" do
      # Anthropic uses separate content blocks
      provider_events = [
        {:part_start, %{type: :text, index: 0, id: nil}},
        {:part_delta,
         %{type: :text, index: 0, text: "I'll read that file.", name: nil, arguments: nil}},
        {:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}},
        {:part_start, %{type: :tool_call, index: 1, id: "toolu_abc"}},
        {:part_delta,
         %{type: :tool_call, index: 1, text: nil, name: "read_file", arguments: nil}},
        {:part_delta,
         %{type: :tool_call, index: 1, text: nil, name: nil, arguments: "{\"path\":\"/f\"}"}},
        {:part_end,
         %{
           type: :tool_call,
           index: 1,
           id: "toolu_abc",
           name: "read_file",
           arguments: "{\"path\":\"/f\"}"
         }},
        {:done,
         %{
           id: "msg-3",
           model: "claude-sonnet-4-20250514",
           content: "I'll read that file.",
           tool_calls: [],
           finish_reason: "tool_use",
           usage: %{prompt_tokens: 50, completion_tokens: 25, total_tokens: 75}
         }}
      ]

      canonical_events = normalize_events(provider_events)
      response = Collector.collect_stream(canonical_events)

      assert response.content == "I'll read that file."
      assert length(response.tool_calls) == 1
      [tc] = response.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "/f"}
    end

    test "legacy MockLLM events through normalizer" do
      # Simulates what MockLLM in Agent.Loop tests emits
      legacy_events = [
        {:text, "Hello from mock"},
        {:tool_call, "echo_tool", %{"input" => "test"}, "tc-mock-1"},
        {:done, :complete}
      ]

      canonical_events = normalize_events(legacy_events)
      response = Collector.collect_stream(canonical_events)

      assert response.content == "Hello from mock"
      assert length(response.tool_calls) == 1
      [tc] = response.tool_calls
      assert tc.name == "echo_tool"
      assert tc.arguments == %{"input" => "test"}
    end

    test "multiple tool calls from same stream" do
      provider_events = [
        {:part_start, %{type: :tool_call, index: 0, id: "tc-1"}},
        {:part_delta, %{type: :tool_call, index: 0, text: nil, name: "tool_a", arguments: nil}},
        {:part_delta, %{type: :tool_call, index: 0, text: nil, name: nil, arguments: "{}"}},
        {:part_end, %{type: :tool_call, index: 0, id: "tc-1", name: "tool_a", arguments: "{}"}},
        {:part_start, %{type: :tool_call, index: 1, id: "tc-2"}},
        {:part_delta, %{type: :tool_call, index: 1, text: nil, name: "tool_b", arguments: nil}},
        {:part_delta, %{type: :tool_call, index: 1, text: nil, name: nil, arguments: "{}"}},
        {:part_end, %{type: :tool_call, index: 1, id: "tc-2", name: "tool_b", arguments: "{}"}},
        {:done,
         %{
           id: "msg-4",
           model: "gpt-4o",
           content: nil,
           tool_calls: [],
           finish_reason: "tool_calls",
           usage: nil
         }}
      ]

      canonical_events = normalize_events(provider_events)
      response = Collector.collect_stream(canonical_events)

      assert length(response.tool_calls) == 2
      names = Enum.map(response.tool_calls, & &1.name)
      assert "tool_a" in names
      assert "tool_b" in names
    end
  end

  describe "wire format transport" do
    test "events survive JSON round-trip through normalizer and collector" do
      provider_events = [
        {:part_start, %{type: :text, index: 0, id: nil}},
        {:part_delta,
         %{type: :text, index: 0, text: "Transport test", name: nil, arguments: nil}},
        {:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}},
        {:done,
         %{
           id: "msg-transport",
           model: "test",
           content: "Transport test",
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
         }}
      ]

      # Normalize
      canonical_events = normalize_events(provider_events)

      # Serialize to wire format
      wire_events = Enum.map(canonical_events, &Event.to_wire/1)

      # Simulate JSON transport
      json_events =
        Enum.map(wire_events, fn wire ->
          wire |> Jason.encode!() |> Jason.decode!()
        end)

      # Deserialize back
      restored_events =
        Enum.map(json_events, fn json ->
          {:ok, event} = Event.from_wire(json)
          event
        end)

      # Collect and verify
      response = Collector.collect_stream(restored_events)
      assert response.content == "Transport test"
      assert response.id == "msg-transport"
      assert response.usage == %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
    end
  end

  # Helper: normalize a list of events
  defp normalize_events(provider_events) do
    test_pid = self()

    callback = fn event ->
      send(test_pid, {:raw, event})
    end

    normalized = Normalizer.normalize(callback)

    for event <- provider_events do
      normalized.(event)
    end

    # Unwrap {:stream, event} tuples for the collector
    collect_raw([])
    |> Enum.map(fn
      {:stream, event} -> event
      other -> other
    end)
  end

  defp collect_raw(acc) do
    receive do
      {:raw, event} -> collect_raw([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
