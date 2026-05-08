defmodule CodePuppyControl.LLM.SSEChunkBoundaryTest do
  @moduledoc """
  SSE chunk-boundary property tests and exhaustive boundary tests.

  Verifies that SSE parsing produces identical results regardless of where
  network chunks split the byte stream. Uses StreamData to generate random
  split points and compares chunked vs. whole-body parsing.

  Also includes exhaustive single-split tests that try every possible
  byte offset as a split point.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias CodePuppyControl.LLM.Providers.OpenAI
  alias CodePuppyControl.LLM.Providers.Anthropic
  alias CodePuppyControl.Test.MockLLMHTTP
  alias CodePuppyControl.Test.SSEChunkHelpers

  import SSEChunkHelpers, only: [split_at_points: 2, collect_stream: 4, done_response: 1]

  @default_messages [%{role: "user", content: "Hello"}]
  @default_tools []

  defp openai_sse_body(text_chunks), do: MockLLMHTTP.openai_stream_fixture(chunks: text_chunks)

  defp anthropic_sse_body(text_chunks),
    do: MockLLMHTTP.anthropic_stream_fixture(chunks: text_chunks)

  # ══════════════════════════════════════════════════════════════════════════
  # PROPERTY TESTS: Random chunk splitting
  # ══════════════════════════════════════════════════════════════════════════

  describe "property: random chunk splitting — OpenAI" do
    property "SSE parsing produces same result regardless of chunk boundaries" do
      import StreamData

      check all(
              text_chunks <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 5
                ),
              max_runs: 40
            ) do
        body = openai_sse_body(text_chunks)

        check all(
                split_points <- SSEChunkHelpers.split_points_gen(byte_size(body)),
                max_runs: 8
              ) do
          assert_chunked_matches_whole(OpenAI, body, "gpt-4o", split_points)
        end
      end
    end
  end

  describe "property: random chunk splitting — Anthropic" do
    property "SSE parsing produces same result regardless of chunk boundaries" do
      import StreamData

      check all(
              text_chunks <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 5
                ),
              max_runs: 40
            ) do
        body = anthropic_sse_body(text_chunks)

        check all(
                split_points <- SSEChunkHelpers.split_points_gen(byte_size(body)),
                max_runs: 8
              ) do
          assert_chunked_matches_whole(Anthropic, body, "claude-sonnet-4-20250514", split_points)
        end
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # EXHAUSTIVE BOUNDARY TEST: Every possible single split
  # ══════════════════════════════════════════════════════════════════════════

  describe "exhaustive single-split boundary coverage" do
    test "OpenAI: every possible single split point produces correct result" do
      body = openai_sse_body(["AB"])

      for split_point <- 1..(byte_size(body) - 1) do
        chunks = split_at_points(body, [split_point])
        mock = SSEChunkHelpers.build_chunked_mock(chunks)

        {_result, events} =
          collect_stream(OpenAI, @default_messages, @default_tools,
            http_client: mock,
            api_key: "test-key",
            model: "gpt-4o"
          )

        resp = done_response(events)

        assert resp.content == "AB",
               "Failed at split point #{split_point}: got #{inspect(resp.content)}"
      end
    end

    test "Anthropic: every possible single split point produces correct result" do
      body = anthropic_sse_body(["AB"])

      for split_point <- 1..(byte_size(body) - 1) do
        chunks = split_at_points(body, [split_point])
        mock = SSEChunkHelpers.build_chunked_mock(chunks)

        {_result, events} =
          collect_stream(Anthropic, @default_messages, @default_tools,
            http_client: mock,
            api_key: "test-key",
            model: "claude-sonnet-4-20250514"
          )

        resp = done_response(events)

        assert resp.content == "AB",
               "Failed at split point #{split_point}: got #{inspect(resp.content)}"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # SHARED ASSERTIONS
  # ══════════════════════════════════════════════════════════════════════════

  defp assert_chunked_matches_whole(provider, body, model, split_points) do
    whole_mock = SSEChunkHelpers.build_chunked_mock([body])

    {_result, whole_events} =
      collect_stream(provider, @default_messages, @default_tools,
        http_client: whole_mock,
        api_key: "test-key",
        model: model
      )

    whole_resp = done_response(whole_events)

    chunks = split_at_points(body, split_points)
    chunked_mock = SSEChunkHelpers.build_chunked_mock(chunks)

    {_result, chunked_events} =
      collect_stream(provider, @default_messages, @default_tools,
        http_client: chunked_mock,
        api_key: "test-key",
        model: model
      )

    chunked_resp = done_response(chunked_events)

    assert chunked_resp.content == whole_resp.content,
           "Content mismatch: chunked=#{inspect(chunked_resp.content)}, whole=#{inspect(whole_resp.content)}"

    assert chunked_resp.tool_calls == whole_resp.tool_calls,
           "Tool calls mismatch"

    assert chunked_resp.finish_reason == whole_resp.finish_reason,
           "Finish reason mismatch"
  end
end
