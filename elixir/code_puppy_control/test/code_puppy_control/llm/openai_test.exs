defmodule CodePuppyControl.LLM.Providers.OpenAITest do
  @moduledoc """
  Tests for the OpenAI provider implementation.

  Uses MockLLMHTTP to return fixture responses without hitting real APIs.
  Covers: non-streaming chat, SSE streaming, tool calls, error handling.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.OpenAI
  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    # Ensure MockLLMHTTP is started under test supervision for proper isolation
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  @messages [%{role: "user", content: "Hello"}]
  @opts [api_key: "test-key", model: "gpt-4o", http_client: MockLLMHTTP]

  describe "chat/3" do
    test "parses a successful response" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(content: "Hi there!"),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = OpenAI.chat(@messages, [], @opts)
      assert response.content == "Hi there!"
      assert response.finish_reason == "stop"
      assert response.tool_calls == []
      assert response.usage.prompt_tokens == 10
      assert response.usage.completion_tokens == 20
    end

    test "parses tool calls from response" do
      tool_calls = [
        %{
          "id" => "call_abc",
          "type" => "function",
          "function" => %{"name" => "get_weather", "arguments" => ~s({"location":"NYC"})}
        }
      ]

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 200,
             body:
               MockLLMHTTP.openai_chat_fixture(
                 content: nil,
                 tool_calls: tool_calls,
                 finish_reason: "tool_calls"
               ),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = OpenAI.chat(@messages, [], @opts)
      assert response.content == nil
      assert response.finish_reason == "tool_calls"
      assert length(response.tool_calls) == 1

      [tc] = response.tool_calls
      assert tc.id == "call_abc"
      assert tc.name == "get_weather"
      assert tc.arguments == %{"location" => "NYC"}
    end

    test "handles HTTP error status" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 401,
             body:
               Jason.encode!(%{
                 "error" => %{"message" => "Invalid API key", "type" => "auth_error"}
               }),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 401}} = OpenAI.chat(@messages, [], @opts)
    end

    test "sends correct request body" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/chat/completions" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      OpenAI.chat(@messages, [], @opts)

      assert_received {:request_body, body}
      assert body["model"] == "gpt-4o"
      assert body["stream"] == false
      assert length(body["messages"]) == 1
      assert hd(body["messages"])["role"] == "user"
      assert hd(body["messages"])["content"] == "Hello"
    end

    test "includes tools in request body" do
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
        if url =~ "/chat/completions" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      OpenAI.chat(@messages, tools, @opts)

      assert_received {:request_body, body}
      assert is_list(body["tools"])
      assert length(body["tools"]) == 1
      assert hd(body["tools"])["function"]["name"] == "get_weather"
    end
  end

  describe "stream_chat/4" do
    test "streams text content and emits events" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_stream_fixture(chunks: ["Hello", " world", "!"]),
             headers: [{"content-type", "text/event-stream"}]
           }}
        else
          {:passthrough}
        end
      end)

      events =
        capture_stream_events(fn callback ->
          :ok = OpenAI.stream_chat(@messages, [], @opts, callback)
        end)

      # Should have part_start, part_deltas, part_end, done
      starts = Enum.filter(events, &match?({:part_start, _}, &1))
      deltas = Enum.filter(events, &match?({:part_delta, _}, &1))
      ends = Enum.filter(events, &match?({:part_end, _}, &1))
      dones = Enum.filter(events, &match?({:done, _}, &1))

      assert length(starts) == 1
      assert length(deltas) == 3
      assert length(ends) == 1
      assert length(dones) == 1

      # Check delta content
      delta_texts = Enum.map(deltas, fn {:part_delta, d} -> d.text end)
      assert delta_texts == ["Hello", " world", "!"]

      # Check done response
      [{:done, response}] = dones
      assert response.content == "Hello world!"
      assert response.finish_reason == "stop"
    end

    test "streams tool calls and emits events" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_tool_stream_fixture(),
             headers: [{"content-type", "text/event-stream"}]
           }}
        else
          {:passthrough}
        end
      end)

      events =
        capture_stream_events(fn callback ->
          :ok = OpenAI.stream_chat(@messages, [], @opts, callback)
        end)

      starts = Enum.filter(events, &match?({:part_start, %{type: :tool_call}}, &1))
      _deltas = Enum.filter(events, &match?({:part_delta, %{type: :tool_call}}, &1))
      ends = Enum.filter(events, &match?({:part_end, %{type: :tool_call}}, &1))
      dones = Enum.filter(events, &match?({:done, _}, &1))

      assert length(starts) == 1
      assert length(ends) == 1
      assert length(dones) == 1

      # Check done response has tool call
      [{:done, response}] = dones
      assert response.finish_reason == "tool_calls"
      assert length(response.tool_calls) == 1

      [tc] = response.tool_calls
      assert tc.name == "get_weather"
      assert tc.arguments == %{"location" => "Boston"}
    end

    test "stream_chat returns {:error, _} for HTTP 500" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok, %{status: 500, body: "Internal Server Error", headers: []}}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 500}} =
               OpenAI.stream_chat(@messages, [], @opts, fn _ -> :ok end)
    end

    test "stream_chat returns {:error, _} for HTTP 401" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 401,
             body: ~s({"error":{"message":"Invalid API key","type":"auth_error"}}),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 401}} =
               OpenAI.stream_chat(@messages, [], @opts, fn _ -> :ok end)
    end

    test "stream_chat returns {:error, _} for HTTP 429 rate limit" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 429,
             body: ~s({"error":{"message":"Rate limited","type":"rate_limit"}}),
             headers: [{"retry-after", "5"}]
           }}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 429}} =
               OpenAI.stream_chat(@messages, [], @opts, fn _ -> :ok end)
    end

    test "stream_chat returns {:error, _} for transport error" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:error, "Connection refused"}
        else
          {:passthrough}
        end
      end)

      assert {:error, _} = OpenAI.stream_chat(@messages, [], @opts, fn _ -> :ok end)
    end
  end

  # ── URL Building Tests ─────────────────────────────────────────

  describe "URL building" do
    test "does not duplicate /v1 in path when base_url already ends with /v1" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          send(test_pid, {:request_url, url})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      opts = Keyword.put(@opts, :base_url, "https://example.com/v1")
      OpenAI.chat(@messages, [], opts)

      assert_received {:request_url, url}
      assert url == "https://example.com/v1/chat/completions"
      refute url =~ "/v1/v1/", "URL should not contain duplicate /v1: #{url}"
    end

    test "does not duplicate /v1 when base_url ends with /v1/" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          send(test_pid, {:request_url, url})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      opts = Keyword.put(@opts, :base_url, "https://example.com/v1/")
      OpenAI.chat(@messages, [], opts)

      assert_received {:request_url, url}
      assert url == "https://example.com/v1/chat/completions"
      refute url =~ "/v1/v1/", "URL should not contain duplicate /v1: #{url}"
    end

    test "builds correct URL for base_url without /v1" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          send(test_pid, {:request_url, url})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      opts = Keyword.put(@opts, :base_url, "https://api.openai.com")
      OpenAI.chat(@messages, [], opts)

      assert_received {:request_url, url}
      assert url == "https://api.openai.com/v1/chat/completions"
    end
  end

  # ── Extra Headers Tests ─────────────────────────────────────────

  describe "extra_headers forwarding" do
    test "custom endpoint headers are included in request" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/chat/completions" do
          send(test_pid, {:request_headers, opts[:headers]})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      opts =
        @opts
        |> Keyword.put(:extra_headers, [{"x-custom-header", "my-value"}, {"x-another", "42"}])

      OpenAI.chat(@messages, [], opts)

      assert_received {:request_headers, headers}

      # Standard headers should be present
      assert List.keyfind(headers, "authorization", 0) != nil
      assert List.keyfind(headers, "content-type", 0) != nil

      # Extra headers should be appended
      assert List.keyfind(headers, "x-custom-header", 0) == {"x-custom-header", "my-value"}
      assert List.keyfind(headers, "x-another", 0) == {"x-another", "42"}
    end

    test "works without extra_headers (backward compatible)" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      # No extra_headers in opts — should work fine
      assert {:ok, _} = OpenAI.chat(@messages, [], @opts)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

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
