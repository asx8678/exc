defmodule CodePuppyControl.LLM.SSEChunkErrorTest do
  @moduledoc """
  SSE chunk-boundary error handling tests.

  Tests error scenarios with chunked SSE delivery:
  - Malformed JSON in data field
  - Error events mid-stream (OpenAI and Anthropic)
  - Error events split across chunks
  - Truncated streams (no [DONE])
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.LLM.Providers.OpenAI
  alias CodePuppyControl.LLM.Providers.Anthropic
  alias CodePuppyControl.Test.SSEChunkHelpers

  import SSEChunkHelpers,
    only: [split_at_points: 2, collect_stream: 4, done_response: 1, extract_text_deltas: 1]

  @default_messages [%{role: "user", content: "Hello"}]
  @default_tools []

  # ══════════════════════════════════════════════════════════════════════════
  # OpenAI ERROR HANDLING
  # ══════════════════════════════════════════════════════════════════════════

  describe "OpenAI error handling with chunked delivery" do
    test "malformed JSON in data field is skipped gracefully" do
      good1 = %{
        "id" => "chatcmpl-err",
        "object" => "chat.completion.chunk",
        "model" => "gpt-4o",
        "choices" => [%{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => nil}]
      }

      good2 = %{
        "id" => "chatcmpl-err",
        "object" => "chat.completion.chunk",
        "model" => "gpt-4o",
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => " world"}, "finish_reason" => nil}
        ]
      }

      final = %{
        "id" => "chatcmpl-err",
        "object" => "chat.completion.chunk",
        "model" => "gpt-4o",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      }

      body =
        "data: #{Jason.encode!(good1)}\n\n" <>
          "data: {BROKEN JSON!!!\n\n" <>
          "data: #{Jason.encode!(good2)}\n\n" <>
          "data: #{Jason.encode!(final)}\n\n" <>
          "data: [DONE]\n\n"

      size = byte_size(body)
      chunks = split_at_points(body, [div(size, 2)])
      mock = SSEChunkHelpers.build_chunked_mock(chunks)

      {_result, events} =
        collect_stream(OpenAI, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "gpt-4o"
        )

      assert done_response(events).content == "Hello world"
    end

    test "error event mid-stream returns error" do
      good = %{
        "id" => "chatcmpl-err2",
        "object" => "chat.completion.chunk",
        "model" => "gpt-4o",
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "partial"}, "finish_reason" => nil}
        ]
      }

      error = %{"error" => %{"message" => "rate limit exceeded", "type" => "rate_limit_error"}}

      body =
        "data: #{Jason.encode!(good)}\n\n" <>
          "data: #{Jason.encode!(error)}\n\n"

      mock = SSEChunkHelpers.build_chunked_mock([body])

      result =
        OpenAI.stream_chat(
          @default_messages,
          @default_tools,
          [http_client: mock, api_key: "test-key", model: "gpt-4o"],
          fn _event -> :ok end
        )

      assert {:error, %{body: %{"message" => "rate limit exceeded"}}} = result
    end

    test "error event split across chunks still returns error" do
      good = %{
        "id" => "chatcmpl-err3",
        "object" => "chat.completion.chunk",
        "model" => "gpt-4o",
        "choices" => [%{"index" => 0, "delta" => %{"content" => "x"}, "finish_reason" => nil}]
      }

      error = %{"error" => %{"message" => "server error", "type" => "internal_error"}}

      body =
        "data: #{Jason.encode!(good)}\n\n" <>
          "data: #{Jason.encode!(error)}\n\n"

      size = byte_size(body)
      chunks = split_at_points(body, [div(size, 2)])
      mock = SSEChunkHelpers.build_chunked_mock(chunks)

      result =
        OpenAI.stream_chat(
          @default_messages,
          @default_tools,
          [http_client: mock, api_key: "test-key", model: "gpt-4o"],
          fn _event -> :ok end
        )

      assert {:error, %{body: %{"message" => "server error"}}} = result
    end

    test "truncated stream (no [DONE]) still delivers partial content" do
      good = %{
        "id" => "chatcmpl-trunc",
        "object" => "chat.completion.chunk",
        "model" => "gpt-4o",
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "partial"}, "finish_reason" => nil}
        ]
      }

      body = "data: #{Jason.encode!(good)}\n\n"
      mock = SSEChunkHelpers.build_chunked_mock([body])

      {_result, events} =
        collect_stream(OpenAI, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "gpt-4o"
        )

      assert extract_text_deltas(events) == "partial"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Anthropic ERROR HANDLING
  # ══════════════════════════════════════════════════════════════════════════

  describe "Anthropic error handling with chunked delivery" do
    test "error event mid-stream returns error" do
      body =
        "event: message_start\n" <>
          "data: #{Jason.encode!(%{"type" => "message_start", "message" => %{"id" => "msg_err", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-4-20250514", "content" => [], "stop_reason" => nil, "usage" => %{"input_tokens" => 5, "output_tokens" => 0}}})}\n\n" <>
          "event: error\n" <>
          "data: #{Jason.encode!(%{"type" => "error", "error" => %{"type" => "rate_limit_error", "message" => "Too many requests"}})}\n\n"

      mock = SSEChunkHelpers.build_chunked_mock([body])

      result =
        Anthropic.stream_chat(
          @default_messages,
          @default_tools,
          [http_client: mock, api_key: "test-key", model: "claude-sonnet-4-20250514"],
          fn _event -> :ok end
        )

      assert {:error, %{"type" => "rate_limit_error", "message" => "Too many requests"}} = result
    end

    test "error event split across chunks still returns error" do
      body =
        "event: message_start\n" <>
          "data: #{Jason.encode!(%{"type" => "message_start", "message" => %{"id" => "msg_err2", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-4-20250514", "content" => [], "stop_reason" => nil, "usage" => %{"input_tokens" => 5, "output_tokens" => 0}}})}\n\n" <>
          "event: error\n" <>
          "data: #{Jason.encode!(%{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "Server is overloaded"}})}\n\n"

      size = byte_size(body)
      chunks = split_at_points(body, [div(size, 2)])
      mock = SSEChunkHelpers.build_chunked_mock(chunks)

      result =
        Anthropic.stream_chat(
          @default_messages,
          @default_tools,
          [http_client: mock, api_key: "test-key", model: "claude-sonnet-4-20250514"],
          fn _event -> :ok end
        )

      assert {:error, %{"type" => "overloaded_error"}} = result
    end

    test "malformed JSON in data field is skipped gracefully" do
      start_ev =
        "event: message_start\n" <>
          "data: #{Jason.encode!(%{"type" => "message_start", "message" => %{"id" => "msg_bad", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-4-20250514", "content" => [], "stop_reason" => nil, "usage" => %{"input_tokens" => 5, "output_tokens" => 0}}})}\n\n"

      block_start =
        "event: content_block_start\n" <>
          "data: #{Jason.encode!(%{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}})}\n\n"

      delta =
        "event: content_block_delta\n" <>
          "data: #{Jason.encode!(%{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hi"}})}\n\n"

      bad_delta =
        "event: content_block_delta\n" <>
          "data: {BROKEN!!!\n\n"

      block_stop =
        "event: content_block_stop\n" <>
          "data: #{Jason.encode!(%{"type" => "content_block_stop", "index" => 0})}\n\n"

      msg_delta =
        "event: message_delta\n" <>
          "data: #{Jason.encode!(%{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 1}})}\n\n"

      msg_stop =
        "event: message_stop\n" <>
          "data: #{Jason.encode!(%{"type" => "message_stop"})}\n\n"

      body = start_ev <> block_start <> delta <> bad_delta <> block_stop <> msg_delta <> msg_stop

      mock = SSEChunkHelpers.build_chunked_mock([body])

      {_result, events} =
        collect_stream(Anthropic, @default_messages, @default_tools,
          http_client: mock,
          api_key: "test-key",
          model: "claude-sonnet-4-20250514"
        )

      assert extract_text_deltas(events) == "Hi"
    end
  end
end
