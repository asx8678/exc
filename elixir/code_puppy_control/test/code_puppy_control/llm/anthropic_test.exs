defmodule CodePuppyControl.LLM.Providers.AnthropicTest do
  @moduledoc """
  Tests for the Anthropic provider implementation.

  Uses MockLLMHTTP to return fixture responses without hitting real APIs.
  Covers: non-streaming chat, SSE streaming, tool use, system message extraction.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.Anthropic
  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    # Ensure MockLLMHTTP is started under test supervision for proper isolation
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  @messages [%{role: "user", content: "Hello"}]
  @opts [api_key: "test-key", model: "claude-sonnet-4-20250514", http_client: MockLLMHTTP]

  describe "chat/3" do
    test "parses a successful response" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_chat_fixture(content: "Hi there!"),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = Anthropic.chat(@messages, [], @opts)
      assert response.content == "Hi there!"
      assert response.finish_reason == "end_turn"
      assert response.tool_calls == []
      assert response.usage.prompt_tokens == 10
      assert response.usage.completion_tokens == 20
    end

    test "parses tool use from response" do
      tool_use = %{
        "type" => "tool_use",
        "id" => "toolu_abc",
        "name" => "get_weather",
        "input" => %{"location" => "NYC"}
      }

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 200,
             body:
               MockLLMHTTP.anthropic_chat_fixture(
                 content: nil,
                 tool_use: tool_use,
                 stop_reason: "tool_use"
               ),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = Anthropic.chat(@messages, [], @opts)
      assert response.content == nil
      assert response.finish_reason == "tool_use"
      assert length(response.tool_calls) == 1

      [tc] = response.tool_calls
      assert tc.id == "toolu_abc"
      assert tc.name == "get_weather"
      assert tc.arguments == %{"location" => "NYC"}
    end

    test "handles HTTP error status" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 401,
             body:
               Jason.encode!(%{
                 "error" => %{"type" => "authentication_error", "message" => "Invalid API key"}
               }),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 401}} = Anthropic.chat(@messages, [], @opts)
    end

    test "extracts system messages to top-level field" do
      test_pid = self()

      messages_with_system = [
        %{role: "system", content: "You are helpful."},
        %{role: "user", content: "Hello"}
      ]

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/messages" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      Anthropic.chat(messages_with_system, [], @opts)

      assert_received {:request_body, body}
      assert body["system"] == "You are helpful."
      assert length(body["messages"]) == 1
      assert hd(body["messages"])["role"] == "user"
    end

    test "formats tool definitions for Anthropic API" do
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
        if url =~ "/messages" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      Anthropic.chat(@messages, tools, @opts)

      assert_received {:request_body, body}
      assert is_list(body["tools"])
      assert length(body["tools"]) == 1

      tool = hd(body["tools"])
      assert tool["name"] == "get_weather"
      assert tool["description"] == "Get the weather"
      assert tool["input_schema"]["type"] == "object"
    end
  end

  describe "stream_chat/4" do
    test "streams text content and emits events" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_stream_fixture(chunks: ["Hello", " world", "!"]),
             headers: [{"content-type", "text/event-stream"}]
           }}
        else
          {:passthrough}
        end
      end)

      events =
        capture_stream_events(fn callback ->
          :ok = Anthropic.stream_chat(@messages, [], @opts, callback)
        end)

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
      assert response.finish_reason == "end_turn"
    end

    test "streams tool use and emits events" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_tool_stream_fixture(),
             headers: [{"content-type", "text/event-stream"}]
           }}
        else
          {:passthrough}
        end
      end)

      events =
        capture_stream_events(fn callback ->
          :ok = Anthropic.stream_chat(@messages, [], @opts, callback)
        end)

      starts = Enum.filter(events, &match?({:part_start, %{type: :tool_call}}, &1))
      _deltas = Enum.filter(events, &match?({:part_delta, %{type: :tool_call}}, &1))
      ends = Enum.filter(events, &match?({:part_end, %{type: :tool_call}}, &1))
      dones = Enum.filter(events, &match?({:done, _}, &1))

      assert length(starts) == 1
      # Anthropic sends name in content_block_start, then input_json_delta
      assert length(ends) == 1
      assert length(dones) == 1

      # Check done response has tool call
      [{:done, response}] = dones
      assert response.finish_reason == "tool_use"
      assert length(response.tool_calls) == 1

      [tc] = response.tool_calls
      assert tc.name == "get_weather"
      assert tc.arguments == %{"location" => "Boston"}
    end

    test "stream_chat returns {:error, _} for HTTP 500" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok, %{status: 500, body: "Internal Server Error", headers: []}}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 500}} =
               Anthropic.stream_chat(@messages, [], @opts, fn _ -> :ok end)
    end

    test "stream_chat returns {:error, _} for HTTP 401" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 401,
             body:
               Jason.encode!(%{
                 "error" => %{"type" => "authentication_error", "message" => "Invalid API key"}
               }),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 401}} =
               Anthropic.stream_chat(@messages, [], @opts, fn _ -> :ok end)
    end

    test "stream_chat returns {:error, _} for transport error" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:error, "Connection refused"}
        else
          {:passthrough}
        end
      end)

      assert {:error, _} = Anthropic.stream_chat(@messages, [], @opts, fn _ -> :ok end)
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

  # ── format_content(nil, msg) replay regression ───────────────────────────
  #
  # Tests the bug where assistant messages with content: nil and tool_calls
  # present silently returned "" instead of emitting Anthropic tool_use blocks.
  # This caused replay divergence — the LLM never saw the prior tool calls and
  # re-invoked them on every turn.
  #
  # We test through chat/3 (intercepting the request body) because format_message
  # and format_content are private.

  describe "format_content/2: nil content with tool_calls" do
    test "nil content + tool_calls emits Anthropic tool_use blocks (not empty string)" do
      test_pid = self()

      messages = [
        %{role: "user", content: "Hello"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "tc-replay-1",
              type: "function",
              function: %{name: "read_file", arguments: "{\"path\":\"foo.ex\"}"}
            }
          ]
        }
      ]

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/messages" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, _} = Anthropic.chat(messages, [], @opts)

      assert_received {:request_body, body}
      # 2 messages: user + assistant
      assert length(body["messages"]) == 2

      assistant_msg = Enum.at(body["messages"], 1)
      assert assistant_msg["role"] == "assistant"
      # Must NOT be the empty string ""
      assert is_list(assistant_msg["content"]),
             "Expected tool_use blocks list, got: #{inspect(assistant_msg["content"])}"

      [block] = assistant_msg["content"]
      assert block["type"] == "tool_use"
      assert block["id"] == "tc-replay-1"
      assert block["name"] == "read_file"
      assert block["input"] == %{"path" => "foo.ex"}
    end

    test "nil content + multiple tool_calls emits all tool_use blocks" do
      test_pid = self()

      messages = [
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{id: "tc-a", type: "function", function: %{name: "tool_a", arguments: "{\"a\":1}"}},
            %{id: "tc-b", type: "function", function: %{name: "tool_b", arguments: "{\"b\":2}"}}
          ]
        }
      ]

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/messages" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok, %{status: 200, body: MockLLMHTTP.anthropic_chat_fixture(), headers: []}}
        else
          {:passthrough}
        end
      end)

      assert {:ok, _} = Anthropic.chat(messages, [], @opts)

      assert_received {:request_body, body}
      [assistant_msg] = body["messages"]
      assert is_list(assistant_msg["content"])
      assert length(assistant_msg["content"]) == 2

      [block_a, block_b] = assistant_msg["content"]
      assert block_a["type"] == "tool_use"
      assert block_a["name"] == "tool_a"
      assert block_b["type"] == "tool_use"
      assert block_b["name"] == "tool_b"
    end

    test "nil content + string-keyed tool_calls still emits tool_use blocks" do
      test_pid = self()

      messages = [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "tc-str",
              "type" => "function",
              "function" => %{"name" => "str_tool", "arguments" => "{\"x\":true}"}
            }
          ]
        }
      ]

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/messages" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok, %{status: 200, body: MockLLMHTTP.anthropic_chat_fixture(), headers: []}}
        else
          {:passthrough}
        end
      end)

      assert {:ok, _} = Anthropic.chat(messages, [], @opts)

      assert_received {:request_body, body}
      [assistant_msg] = body["messages"]
      assert is_list(assistant_msg["content"])

      [block] = assistant_msg["content"]
      assert block["type"] == "tool_use"
      assert block["id"] == "tc-str"
      assert block["name"] == "str_tool"
    end

    test "nil content + tool_call_id emits tool_result with empty string content" do
      test_pid = self()

      messages = [
        %{role: "tool", content: nil, tool_call_id: "tc-result-1"}
      ]

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/messages" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok, %{status: 200, body: MockLLMHTTP.anthropic_chat_fixture(), headers: []}}
        else
          {:passthrough}
        end
      end)

      assert {:ok, _} = Anthropic.chat(messages, [], @opts)

      assert_received {:request_body, body}
      [tool_msg] = body["messages"]
      assert is_list(tool_msg["content"])

      [block] = tool_msg["content"]
      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "tc-result-1"
      assert block["content"] == ""
    end

    test "nil content with neither tool_calls nor tool_call_id returns empty string" do
      test_pid = self()

      messages = [%{role: "assistant", content: nil}]

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/messages" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

          {:ok, %{status: 200, body: MockLLMHTTP.anthropic_chat_fixture(), headers: []}}
        else
          {:passthrough}
        end
      end)

      assert {:ok, _} = Anthropic.chat(messages, [], @opts)

      assert_received {:request_body, body}
      [assistant_msg] = body["messages"]
      assert assistant_msg["content"] == ""
    end
  end

  # ── Extra Headers Tests ─────────────────────────────────────────

  describe "extra_headers forwarding" do
    test "custom endpoint headers are included in request" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/messages" do
          send(test_pid, {:request_headers, opts[:headers]})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      opts =
        @opts
        |> Keyword.put(:extra_headers, [
          {"x-custom-header", "anthropic-value"},
          {"x-another", "99"}
        ])

      Anthropic.chat(@messages, [], opts)

      assert_received {:request_headers, headers}

      # Standard headers should be present
      assert List.keyfind(headers, "x-api-key", 0) != nil
      assert List.keyfind(headers, "anthropic-version", 0) != nil

      # Extra headers should be appended
      assert List.keyfind(headers, "x-custom-header", 0) == {"x-custom-header", "anthropic-value"}
      assert List.keyfind(headers, "x-another", 0) == {"x-another", "99"}
    end

    test "works without extra_headers (backward compatible)" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_chat_fixture(),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      # No extra_headers in opts — should work fine
      assert {:ok, _} = Anthropic.chat(@messages, [], @opts)
    end
  end
end
