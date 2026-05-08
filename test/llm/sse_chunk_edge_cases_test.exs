defmodule CodePuppyControl.LLM.SSEChunkEdgeCasesTest do
  @moduledoc """
  SSE chunk-boundary specific edge case tests.

  Tests specific split scenarios that are likely to cause parsing errors:
  - Splits inside JSON keys and values
  - Splits at SSE event boundaries (`\\n\\n`)
  - Splits between event: and data: lines (Anthropic)
  - Empty chunks interspersed between data chunks
  - Escaped characters split mid-sequence
  - Tool call arguments split across chunks
  - Multi-event rapid succession
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.LLM.Providers.OpenAI
  alias CodePuppyControl.LLM.Providers.Anthropic
  alias CodePuppyControl.Test.MockLLMHTTP
  alias CodePuppyControl.Test.SSEChunkHelpers

  import SSEChunkHelpers,
    only: [split_at_points: 2, collect_stream: 4, done_response: 1, extract_text_deltas: 1]

  @default_messages [%{role: "user", content: "Hello"}]
  @default_tools []

  # ══════════════════════════════════════════════════════════════════════════
  # OpenAI SPECIFIC EDGE CASES
  # ══════════════════════════════════════════════════════════════════════════

  describe "OpenAI specific edge cases" do
    test "split inside 'data: {\"choices\"' — mid-key" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["Hello", " world"])

      case :binary.match(body, "choices") do
        {pos, _len} ->
          chunks = split_at_points(body, [pos + 3])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(OpenAI, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "gpt-4o"
            )

          assert done_response(events).content == "Hello world"

        :nomatch ->
          flunk("Could not find 'choices' in SSE body — fixture format may have changed")
      end
    end

    test "split inside '\"content\":\"hel' — mid-value" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["Hello there"])

      case :binary.match(body, "Hello there") do
        {pos, _len} ->
          chunks = split_at_points(body, [pos + 6])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(OpenAI, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "gpt-4o"
            )

          assert done_response(events).content == "Hello there"

        :nomatch ->
          flunk("Could not find content value in SSE body")
      end
    end

    test "split at 'data: [DONE]\\n' before final newline" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["Hi"])

      case :binary.match(body, "[DONE]") do
        {pos, len} ->
          chunks = split_at_points(body, [pos + len])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(OpenAI, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "gpt-4o"
            )

          assert done_response(events).content == "Hi"

        :nomatch ->
          flunk("Could not find [DONE] in SSE body")
      end
    end

    test "split between two rapid events (at \\n\\n boundary)" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["A", "B", "C"])

      case :binary.match(body, "\n\n") do
        {pos, _len} ->
          chunks = split_at_points(body, [pos + 1])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(OpenAI, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "gpt-4o"
            )

          assert done_response(events).content == "ABC"

        :nomatch ->
          flunk("Could not find event boundary in SSE body")
      end
    end

    test "empty chunks interspersed between data chunks" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["Hello", " there", "!"])

      raw_chunks = split_at_points(body, [10, 10, 20, 20])
      chunks_with_empties = Enum.flat_map(raw_chunks, fn chunk -> [chunk, ""] end)
      mock = SSEChunkHelpers.build_chunked_mock(chunks_with_empties)

      {_result, events} =
        collect_stream(OpenAI, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "gpt-4o"
        )

      assert done_response(events).content == "Hello there!"
    end

    test "split inside JSON string value with escaped characters" do
      data1 = %{
        "id" => "chatcmpl-esc",
        "object" => "chat.completion.chunk",
        "model" => "gpt-4o",
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "line1\nline2"}, "finish_reason" => nil}
        ]
      }

      data2 = %{
        "id" => "chatcmpl-esc",
        "object" => "chat.completion.chunk",
        "model" => "gpt-4o",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      }

      body =
        "data: #{Jason.encode!(data1)}\n\ndata: #{Jason.encode!(data2)}\n\ndata: [DONE]\n\n"

      case :binary.match(body, "line1\\nline2") do
        {pos, _len} ->
          chunks = split_at_points(body, [pos + 7])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(OpenAI, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "gpt-4o"
            )

          assert done_response(events).content == "line1\nline2"

        :nomatch ->
          flunk(
            "Could not find escaped content in SSE body (searched for JSON-escaped backslash-n)"
          )
      end
    end

    test "split inside multibyte UTF-8 content bytes" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["🙂漢字"])

      case :binary.match(body, "🙂") do
        {pos, _len} ->
          chunks = split_at_points(body, [pos + 1])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(OpenAI, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "gpt-4o"
            )

          assert done_response(events).content == "🙂漢字"

        :nomatch ->
          flunk("Could not find UTF-8 content in OpenAI SSE body")
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # OpenAI STREAMING FORMAT SPECIFICS
  # ══════════════════════════════════════════════════════════════════════════

  describe "OpenAI streaming format" do
    test "multiple content deltas concatenate in order" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["A", "B", "C", "D"])
      mock = SSEChunkHelpers.build_chunked_mock([body])

      {_result, events} =
        collect_stream(OpenAI, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "gpt-4o"
        )

      assert extract_text_deltas(events) == "ABCD"
    end

    test "stream events include part_start, part_delta, part_end, and done" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["Hi"])
      mock = SSEChunkHelpers.build_chunked_mock([body])

      {_result, events} =
        collect_stream(OpenAI, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "gpt-4o"
        )

      part_starts = Enum.filter(events, &match?({:part_start, _}, &1))
      part_ends = Enum.filter(events, &match?({:part_end, _}, &1))
      done_events = Enum.filter(events, &match?({:done, _}, &1))

      assert length(part_starts) >= 1, "Expected at least one part_start"
      assert length(part_ends) >= 1, "Expected at least one part_end"
      assert length(done_events) == 1, "Expected exactly one :done event"
    end

    test "usage data in final chunk is captured" do
      body = MockLLMHTTP.openai_stream_fixture(chunks: ["test"])
      mock = SSEChunkHelpers.build_chunked_mock([body])

      {_result, events} =
        collect_stream(OpenAI, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "gpt-4o"
        )

      resp = done_response(events)
      assert resp.usage.prompt_tokens > 0
      assert resp.usage.completion_tokens > 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # ANTHROPIC SPECIFIC EDGE CASES
  # ══════════════════════════════════════════════════════════════════════════

  describe "Anthropic specific edge cases" do
    test "split inside 'event: content_block_delta' — mid-event-type" do
      body = MockLLMHTTP.anthropic_stream_fixture(chunks: ["Hi", " there"])

      case :binary.match(body, "content_block_delta") do
        {pos, _len} ->
          chunks = split_at_points(body, [pos + 14])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(Anthropic, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "claude-sonnet-4-20250514"
            )

          assert done_response(events).content == "Hi there"

        :nomatch ->
          flunk("Could not find 'content_block_delta' in SSE body")
      end
    end

    test "split between event: and data: lines of same event" do
      body = MockLLMHTTP.anthropic_stream_fixture(chunks: ["Yo"])

      case :binary.match(body, "event: content_block_delta\ndata:") do
        {pos, _len} ->
          split_point = pos + 27
          chunks = split_at_points(body, [split_point])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(Anthropic, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "claude-sonnet-4-20250514"
            )

          assert done_response(events).content == "Yo"

        :nomatch ->
          flunk("Could not find event/data pair in SSE body")
      end
    end

    test "split inside multibyte UTF-8 content bytes" do
      body = MockLLMHTTP.anthropic_stream_fixture(chunks: ["🙂世界"])

      case :binary.match(body, "🙂") do
        {pos, _len} ->
          chunks = split_at_points(body, [pos + 1])
          mock = SSEChunkHelpers.build_chunked_mock(chunks)

          {_result, events} =
            collect_stream(Anthropic, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "claude-sonnet-4-20250514"
            )

          assert done_response(events).content == "🙂世界"

        :nomatch ->
          flunk("Could not find UTF-8 content in Anthropic SSE body")
      end
    end

    test "different event types arriving in rapid succession" do
      body = MockLLMHTTP.anthropic_stream_fixture(chunks: ["A", "B"])

      size = byte_size(body)
      splits = for i <- 1..4, do: div(size * i, 5)
      chunks = split_at_points(body, splits)
      mock = SSEChunkHelpers.build_chunked_mock(chunks)

      {_result, events} =
        collect_stream(Anthropic, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "claude-sonnet-4-20250514"
        )

      assert done_response(events).content == "AB"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # ANTHROPIC STREAMING FORMAT SPECIFICS
  # ══════════════════════════════════════════════════════════════════════════

  describe "Anthropic streaming format" do
    test "full lifecycle: message_start → deltas → content_block_stop → message_delta → message_stop" do
      body = MockLLMHTTP.anthropic_stream_fixture(chunks: ["Hello"])
      mock = SSEChunkHelpers.build_chunked_mock([body])

      {_result, events} =
        collect_stream(Anthropic, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "claude-sonnet-4-20250514"
        )

      resp = done_response(events)
      assert resp.content == "Hello"
      assert resp.finish_reason == "end_turn"
      assert resp.usage.prompt_tokens == 10
      assert resp.usage.completion_tokens == 1
      assert resp.usage.total_tokens == 11
    end

    test "multiple text deltas concatenate in order" do
      body = MockLLMHTTP.anthropic_stream_fixture(chunks: ["X", "Y", "Z"])
      mock = SSEChunkHelpers.build_chunked_mock([body])

      {_result, events} =
        collect_stream(Anthropic, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "claude-sonnet-4-20250514"
        )

      assert extract_text_deltas(events) == "XYZ"
    end

    test "stop_reason captured from message_delta event" do
      body = MockLLMHTTP.anthropic_stream_fixture(chunks: ["ok"])
      mock = SSEChunkHelpers.build_chunked_mock([body])

      {_result, events} =
        collect_stream(Anthropic, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "claude-sonnet-4-20250514"
        )

      assert done_response(events).finish_reason == "end_turn"
    end

    test "ping event is handled gracefully" do
      base_body = MockLLMHTTP.anthropic_stream_fixture(chunks: ["pong"])
      ping_event = "event: ping\ndata: {}\n\n"

      # Find the first event boundary (\n\n) in the SSE body and insert
      # the ping event right after it, between the message_start and
      # content_block_start events.
      case :binary.match(base_body, "\n\n") do
        {boundary_pos, 2} ->
          insert_at = boundary_pos + 2
          <<before::binary-size(insert_at), rest::binary>> = base_body
          body = before <> ping_event <> rest
          mock = SSEChunkHelpers.build_chunked_mock([body])

          {_result, events} =
            collect_stream(Anthropic, @default_messages, @default_tools,
              http_client: mock,
              api_key: "test-key",
              model: "claude-sonnet-4-20250514"
            )

          assert done_response(events).content == "pong"

        :nomatch ->
          flunk("Could not find event boundary in SSE body for ping insertion")
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # TOOL CALL STREAMING WITH CHUNK BOUNDARIES
  # ══════════════════════════════════════════════════════════════════════════

  describe "tool call arguments split across chunks — OpenAI" do
    test "tool call with arguments split at random boundary" do
      body =
        MockLLMHTTP.openai_tool_stream_fixture(
          tool_name: "get_weather",
          arguments: ~s({"location": "Boston", "unit": "celsius"})
        )

      size = byte_size(body)
      splits = [div(size, 3), div(size * 2, 3)]
      chunks = split_at_points(body, splits)
      mock = SSEChunkHelpers.build_chunked_mock(chunks)

      {_result, events} =
        collect_stream(OpenAI, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "gpt-4o"
        )

      resp = done_response(events)
      assert length(resp.tool_calls) == 1
      tc = hd(resp.tool_calls)
      assert tc.name == "get_weather"
      assert tc.arguments == %{"location" => "Boston", "unit" => "celsius"}
    end

    test "tool call argument accumulation across many small chunks" do
      body =
        MockLLMHTTP.openai_tool_stream_fixture(
          tool_name: "run_command",
          arguments: ~s({"command": "ls -la /tmp"})
        )

      size = byte_size(body)
      splits = for i <- 20..(size - 1), rem(i, 20) == 0, do: i
      chunks = split_at_points(body, splits)
      mock = SSEChunkHelpers.build_chunked_mock(chunks)

      {_result, events} =
        collect_stream(OpenAI, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "gpt-4o"
        )

      resp = done_response(events)
      assert length(resp.tool_calls) == 1
      tc = hd(resp.tool_calls)
      assert tc.name == "run_command"
      assert tc.arguments == %{"command" => "ls -la /tmp"}
    end
  end

  describe "tool call arguments split across chunks — Anthropic" do
    test "tool use with input_json split at random boundary" do
      body =
        MockLLMHTTP.anthropic_tool_stream_fixture(
          tool_name: "get_weather",
          input_json: ~s({"location": "Boston", "unit": "celsius"})
        )

      size = byte_size(body)
      splits = [div(size, 3), div(size * 2, 3)]
      chunks = split_at_points(body, splits)
      mock = SSEChunkHelpers.build_chunked_mock(chunks)

      {_result, events} =
        collect_stream(Anthropic, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "claude-sonnet-4-20250514"
        )

      resp = done_response(events)
      assert length(resp.tool_calls) == 1
      tc = hd(resp.tool_calls)
      assert tc.name == "get_weather"
      assert tc.arguments == %{"location" => "Boston", "unit" => "celsius"}
    end

    test "tool use with input_json in many tiny chunks" do
      body =
        MockLLMHTTP.anthropic_tool_stream_fixture(
          tool_name: "run_command",
          input_json: ~s({"command": "ls -la"})
        )

      size = byte_size(body)
      splits = for i <- 15..(size - 1), rem(i, 15) == 0, do: i
      chunks = split_at_points(body, splits)
      mock = SSEChunkHelpers.build_chunked_mock(chunks)

      {_result, events} =
        collect_stream(Anthropic, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "claude-sonnet-4-20250514"
        )

      resp = done_response(events)
      assert length(resp.tool_calls) == 1
      tc = hd(resp.tool_calls)
      assert tc.name == "run_command"
      assert tc.arguments == %{"command" => "ls -la"}
    end
  end
end
