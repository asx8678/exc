defmodule CodePuppyControl.LLM.Providers.ChatGPTCodexTest do
  @moduledoc """
  Tests for the ChatGPT Codex (Responses-style) provider implementation.

  Uses MockLLMHTTP to return fixture responses without hitting real APIs.
  Covers: request building, SSE streaming, tool calls, error handling.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.ChatGPTCodex
  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  @messages [%{role: "user", content: "Hello"}]
  @opts [
    api_key: "test-oauth-token",
    model: "gpt-5.4",
    base_url: "https://chatgpt.com/backend-api/codex",
    http_client: MockLLMHTTP
  ]

  @sse_headers [{"content-type", "text/event-stream"}]

  # ── Request Building Tests ──────────────────────────────────────────────

  describe "request building" do
    test "posts to /responses endpoint (not /v1/chat/completions)" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_url, url})
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_url, url}
      assert url =~ "/responses"
      refute url =~ "/v1/chat/completions"
    end

    test "does not duplicate /responses in URL" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          send(test_pid, {:request_url, url})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      # base_url already ends with /responses
      opts = Keyword.put(@opts, :base_url, "https://chatgpt.com/backend-api/codex/responses")
      ChatGPTCodex.stream_chat(@messages, [], opts, fn _ -> :ok end)

      assert_received {:request_url, url}
      refute url =~ "/responses/responses", "URL should not contain duplicate /responses: #{url}"
    end

    test "body has stream: true and store: false" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["stream"] == true
      assert body["store"] == false
    end

    test "body uses input not messages" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert Map.has_key?(body, "input")
      refute Map.has_key?(body, "messages"), "Should use 'input', not 'messages'"
    end

    test "system_prompt is placed in instructions field" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      opts = Keyword.put(@opts, :system_prompt, "You are a helpful assistant.")
      ChatGPTCodex.stream_chat(@messages, [], opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["instructions"] == "You are a helpful assistant."
    end

    test "no max_tokens in body (unsupported by Codex backend)" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "max_tokens"), "max_tokens should not be in Codex request"

      refute Map.has_key?(body, "max_output_tokens"),
             "max_output_tokens should not be in Codex request"
    end

    test "reasoning defaults injected for gpt-5 models" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["reasoning"]["effort"] == "medium"
      assert body["reasoning"]["summary"] == "auto"
    end

    test "reasoning not injected for non-reasoning models" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      opts = Keyword.put(@opts, :model, "gpt-4o-mini")
      ChatGPTCodex.stream_chat(@messages, [], opts, fn _ -> :ok end)

      assert_received {:request_body, body}

      refute Map.has_key?(body, "reasoning"),
             "Reasoning should not be injected for non-reasoning models"
    end

    test "explicit reasoning opts override defaults" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      opts = Keyword.put(@opts, :reasoning, %{"effort" => "high", "summary" => "auto"})
      ChatGPTCodex.stream_chat(@messages, [], opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["reasoning"]["effort"] == "high"
    end

    test "tools are in Responses-style format" do
      test_pid = self()

      tools = [
        %{
          type: "function",
          function: %{
            name: "get_weather",
            description: "Get the weather",
            parameters: %{
              "type" => "object",
              "properties" => %{"location" => %{"type" => "string"}}
            }
          }
        }
      ]

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      ChatGPTCodex.stream_chat(@messages, tools, @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert is_list(body["tools"])
      assert length(body["tools"]) == 1
      [tool] = body["tools"]
      assert tool["type"] == "function"
      assert tool["name"] == "get_weather"
      assert tool["description"] == "Get the weather"
    end

    test "extra_headers from opts are included" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, _url, opts ->
        send(test_pid, {:request_headers, opts[:headers]})

        {:ok,
         %{status: 200, body: MockLLMHTTP.chatgpt_codex_stream_fixture(), headers: @sse_headers}}
      end)

      opts =
        Keyword.put(@opts, :extra_headers, [
          {"ChatGPT-Account-Id", "acct-xyz"},
          {"originator", "codex_cli_rs"}
        ])

      ChatGPTCodex.stream_chat(@messages, [], opts, fn _ -> :ok end)

      assert_received {:request_headers, headers}
      assert List.keyfind(headers, "ChatGPT-Account-Id", 0) == {"ChatGPT-Account-Id", "acct-xyz"}
      assert List.keyfind(headers, "originator", 0) == {"originator", "codex_cli_rs"}
    end
  end

  # ── Streaming Tests ──────────────────────────────────────────────────────

  describe "stream_chat/4" do
    test "streams text content and emits normalized events" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.chatgpt_codex_stream_fixture(chunks: ["Hello", " world", "!"]),
             headers: @sse_headers
           }}
        else
          {:passthrough}
        end
      end)

      events =
        capture_stream_events(fn callback ->
          :ok = ChatGPTCodex.stream_chat(@messages, [], @opts, callback)
        end)

      starts = Enum.filter(events, &match?({:part_start, _}, &1))
      deltas = Enum.filter(events, &match?({:part_delta, _}, &1))
      ends = Enum.filter(events, &match?({:part_end, _}, &1))
      dones = Enum.filter(events, &match?({:done, _}, &1))

      assert length(starts) >= 1, "Expected at least one part_start"
      assert length(deltas) == 3, "Expected 3 text deltas, got #{length(deltas)}"
      assert length(ends) >= 1, "Expected at least one part_end"
      assert length(dones) == 1, "Expected exactly one :done"

      # Check delta content
      text_deltas =
        Enum.filter(deltas, fn {:part_delta, d} -> d.type == :text end)
        |> Enum.map(fn {:part_delta, d} -> d.text end)

      assert text_deltas == ["Hello", " world", "!"]

      # Check done response
      [{:done, response}] = dones
      assert response.content == "Hello world!"
      assert response.finish_reason == "stop"
    end

    test "streams tool calls and emits normalized events" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.chatgpt_codex_tool_stream_fixture(),
             headers: @sse_headers
           }}
        else
          {:passthrough}
        end
      end)

      events =
        capture_stream_events(fn callback ->
          :ok = ChatGPTCodex.stream_chat(@messages, [], @opts, callback)
        end)

      starts = Enum.filter(events, &match?({:part_start, %{type: :tool_call}}, &1))
      ends = Enum.filter(events, &match?({:part_end, %{type: :tool_call}}, &1))
      dones = Enum.filter(events, &match?({:done, _}, &1))

      assert length(starts) >= 1, "Expected at least one tool_call part_start"
      assert length(ends) >= 1, "Expected at least one tool_call part_end"
      assert length(dones) == 1

      [{:done, response}] = dones
      assert length(response.tool_calls) == 1

      [tc] = response.tool_calls
      assert tc.name == "get_weather"
      assert tc.arguments == %{"location" => "Boston"}
    end

    test "returns {:error, _} for non-2xx HTTP status" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok, %{status: 404, body: ~s({"error":"Not Found"}), headers: []}}
        else
          {:passthrough}
        end
      end)

      result = ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)

      assert {:error, %{status: 404}} = result
    end

    test "returns {:error, _} for HTTP 401" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok, %{status: 401, body: ~s({"error":"Unauthorized"}), headers: []}}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 401}} =
               ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)
    end

    test "returns {:error, _} for transport error" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:error, "Connection refused"}
        else
          {:passthrough}
        end
      end)

      assert {:error, _} = ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)
    end

    test "handles response.failed SSE event" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.chatgpt_codex_error_stream_fixture(),
             headers: @sse_headers
           }}
        else
          {:passthrough}
        end
      end)

      result = ChatGPTCodex.stream_chat(@messages, [], @opts, fn _ -> :ok end)

      assert {:error, _} = result
    end
  end

  # ── chat/3 Tests ─────────────────────────────────────────────────────────

  describe "chat/3" do
    test "collects stream into a single response" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.chatgpt_codex_stream_fixture(chunks: ["Hi", " there"]),
             headers: @sse_headers
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = ChatGPTCodex.chat(@messages, [], @opts)
      assert response.content == "Hi there"
    end

    test "collects tool calls into single response" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.chatgpt_codex_tool_stream_fixture(),
             headers: @sse_headers
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = ChatGPTCodex.chat(@messages, [], @opts)
      assert length(response.tool_calls) == 1
      [tc] = response.tool_calls
      assert tc.name == "get_weather"
    end
  end

  # ── Behaviour Tests ──────────────────────────────────────────────────────

  describe "behaviour conformance" do
    test "supports_tools? returns true" do
      assert ChatGPTCodex.supports_tools?() == true
    end

    test "supports_vision? returns false" do
      assert ChatGPTCodex.supports_vision?() == false
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp capture_stream_events(callback_fn) do
    events = :ets.new(:stream_events, [:ordered_set, :public])

    callback = fn event ->
      idx = :ets.info(events, :size)
      :ets.insert(events, {idx, event})
    end

    callback_fn.(callback)

    result =
      :ets.tab2list(events)
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, event} -> event end)

    :ets.delete(events)
    result
  end
end
