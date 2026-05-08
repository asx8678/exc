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

  # ── Empty Tool-Call ID Sanitization Tests ──────────────────────────────
  # (code_puppy-be7) Regression tests for the 400 error caused by empty
  # input[*].id / call_id fields in Responses API requests.

  describe "tool-call ID sanitization (code_puppy-be7)" do
    test "SSE: output_item.added with id but no call_id preserves the id" do
      # Simulate the scenario where output_item.added has "id" but no "call_id"
      sse_body =
        [
          %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => %{
              "type" => "function_call",
              "id" => "fc_abc123",
              "name" => "my_tool",
              "arguments" => ""
            }
          },
          %{
            "type" => "response.function_call_arguments.delta",
            "output_index" => 0,
            "call_id" => "fc_abc123",
            "name" => "my_tool",
            "delta" => "{\"x\":1}"
          },
          %{
            "type" => "response.function_call_arguments.done",
            "output_index" => 0,
            "call_id" => "fc_abc123",
            "name" => "my_tool",
            "arguments" => "{\"x\":1}"
          },
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_test",
              "model" => "gpt-5.4",
              "status" => "completed",
              "output" => [
                %{
                  "type" => "function_call",
                  "id" => "fc_abc123",
                  "call_id" => "fc_abc123",
                  "name" => "my_tool",
                  "arguments" => "{\"x\":1}"
                }
              ],
              "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
            }
          }
        ]
        |> Enum.map(fn ev -> "data: #{Jason.encode!(ev)}\n\n" end)
        |> Enum.join()
        |> then(&(&1 <> "data: [DONE]\n\n"))

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok, %{status: 200, body: sse_body, headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      events =
        capture_stream_events(fn callback ->
          :ok = ChatGPTCodex.stream_chat(@messages, [], @opts, callback)
        end)

      [{:done, response}] = Enum.filter(events, &match?({:done, _}, &1))
      [tc] = response.tool_calls
      # The tool call ID must be the one from output_item.added
      assert tc.id == "fc_abc123"
    end

    test "SSE: argument delta events omitting call_id do not overwrite existing id" do
      # Simulate: output_item.added sets call_id, then arg delta events
      # omit call_id (arriving as empty string via || "")
      sse_body =
        [
          %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => %{
              "type" => "function_call",
              "call_id" => "call_real_id",
              "name" => "my_tool",
              "arguments" => ""
            }
          },
          # Delta WITHOUT call_id — previously this would overwrite with ""
          %{
            "type" => "response.function_call_arguments.delta",
            "output_index" => 0,
            "name" => "my_tool",
            "delta" => "{\"a\":1}"
          },
          %{
            "type" => "response.function_call_arguments.done",
            "output_index" => 0,
            "call_id" => "call_real_id",
            "name" => "my_tool",
            "arguments" => "{\"a\":1}"
          },
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_test2",
              "model" => "gpt-5.4",
              "status" => "completed",
              "output" => [
                %{
                  "type" => "function_call",
                  "call_id" => "call_real_id",
                  "name" => "my_tool",
                  "arguments" => "{\"a\":1}"
                }
              ],
              "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
            }
          }
        ]
        |> Enum.map(fn ev -> "data: #{Jason.encode!(ev)}\n\n" end)
        |> Enum.join()
        |> then(&(&1 <> "data: [DONE]\n\n"))

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/responses" do
          {:ok, %{status: 200, body: sse_body, headers: @sse_headers}}
        else
          {:passthrough}
        end
      end)

      events =
        capture_stream_events(fn callback ->
          :ok = ChatGPTCodex.stream_chat(@messages, [], @opts, callback)
        end)

      [{:done, response}] = Enum.filter(events, &match?({:done, _}, &1))
      [tc] = response.tool_calls
      # The ID from output_item.added must be preserved, not overwritten by ""
      assert tc.id == "call_real_id"
    end

    test "next request body has no empty input[*].id or call_id after tool call" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:request_body, body})

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

      # Simulate replay: a tool message with a prior tool call
      messages = [
        %{role: "user", content: "run tool"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "call_test_1",
              type: "function",
              function: %{name: "get_weather", arguments: "{\"location\":\"Boston\"}"}
            }
          ]
        },
        %{role: "tool", content: "{\"temp\":72}", tool_call_id: "call_test_1"}
      ]

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      # No input item should have empty "id" or "call_id"
      for item <- input do
        if item["type"] == "function_call" do
          assert item["id"] != "", "function_call item had empty id: #{inspect(item)}"
          assert item["call_id"] != "", "function_call item had empty call_id: #{inspect(item)}"
          # (code_puppy-be7.4) function_call.id must start with "fc"
          assert String.starts_with?(item["id"], "fc_"),
                 "function_call id must start with fc_: #{inspect(item["id"])}"
        end

        if item["type"] == "function_call_output" do
          assert item["call_id"] != "",
                 "function_call_output item had empty call_id: #{inspect(item)}"
        end
      end

      # (code_puppy-be7.4) function_call_output.call_id must match function_call.call_id
      fcs = Enum.filter(input, &(&1["type"] == "function_call"))
      outputs = Enum.filter(input, &(&1["type"] == "function_call_output"))

      for {fc, out} <- Enum.zip(fcs, outputs) do
        assert fc["call_id"] == out["call_id"],
               "function_call call_id #{inspect(fc["call_id"])} must match output call_id #{inspect(out["call_id"])}"
      end
    end

    test "tool message with empty tool_call_id gets a safe generated call_id" do
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

      # Tool message with nil tool_call_id (degraded path)
      messages = [
        %{role: "user", content: "run tool"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{id: nil, type: "function", function: %{name: "my_tool", arguments: "{}"}}
          ]
        },
        %{role: "tool", content: "result", tool_call_id: nil}
      ]

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      # The function_call_output must have a non-empty call_id
      outputs = Enum.filter(input, fn item -> item["type"] == "function_call_output" end)

      for output <- outputs do
        assert output["call_id"] != "", "Generated call_id must not be empty"
        # Must match valid Responses API ID pattern (letters, numbers, underscores, dashes)
        assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, output["call_id"]),
               "call_id must match valid pattern: #{inspect(output["call_id"])}"
      end

      # (code_puppy-be7.4) function_call.id must start with "fc"
      fcs = Enum.filter(input, fn item -> item["type"] == "function_call" end)

      for fc <- fcs do
        assert String.starts_with?(fc["id"], "fc_"),
               "function_call id must start with fc_: #{inspect(fc["id"])}"
      end

      # (code_puppy-be7.4) output call_ids must match function_call call_ids pairwise
      for {fc, out} <- Enum.zip(fcs, outputs) do
        assert fc["call_id"] == out["call_id"],
               "function_call call_id #{inspect(fc["call_id"])} must match output call_id #{inspect(out["call_id"])}"
      end
    end

    # (code_puppy-be7.2) Regression tests for character validation
    test "IDs with invalid characters are sanitized before request" do
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

      # Tool call ID with invalid characters (dots, colons, slashes)
      messages = [
        %{role: "user", content: "run tool"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "call_abc.123/def:456",
              type: "function",
              function: %{name: "my_tool", arguments: "{}"}
            }
          ]
        },
        %{role: "tool", content: "result", tool_call_id: "call_abc.123/def:456"}
      ]

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      # No item should have the original invalid ID
      for item <- input do
        if item["type"] == "function_call" do
          refute item["id"] =~ ".", "function_call id had dot: #{inspect(item["id"])}"
          refute item["id"] =~ "/", "function_call id had slash: #{inspect(item["id"])}"

          assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, item["id"]),
                 "function_call id has invalid chars: #{inspect(item["id"])}"

          # (code_puppy-be7.4) function_call.id must start with "fc"
          assert String.starts_with?(item["id"], "fc_"),
                 "function_call id must start with fc_: #{inspect(item["id"])}"
        end

        if item["type"] == "function_call_output" do
          assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, item["call_id"]),
                 "function_call_output call_id has invalid chars: #{inspect(item["call_id"])}"
        end
      end

      # (code_puppy-be7.4) output call_id must match function_call call_id
      fcs = Enum.filter(input, &(&1["type"] == "function_call"))
      outputs = Enum.filter(input, &(&1["type"] == "function_call_output"))

      for {fc, out} <- Enum.zip(fcs, outputs) do
        assert fc["call_id"] == out["call_id"],
               "function_call call_id #{inspect(fc["call_id"])} must match output call_id #{inspect(out["call_id"])}"
      end
    end

    # (code_puppy-be7.3) Regression: multiple empty-ID tool calls must pair
    # correctly in order with their tool results, not all point at the last
    # synthetic ID.
    test "multiple empty-id tool calls pair in order with tool results" do
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

      # Two assistant tool_calls both with id: ""
      # followed by two tool messages both with tool_call_id: ""
      messages = [
        %{role: "user", content: "run two tools"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "",
              type: "function",
              function: %{name: "get_weather", arguments: "{\"loc\":\"A\"}"}
            },
            %{
              id: "",
              type: "function",
              function: %{name: "get_time", arguments: "{\"loc\":\"A\"}"}
            }
          ]
        },
        %{role: "tool", content: "{\"temp\":72}", tool_call_id: ""},
        %{role: "tool", content: "{\"time\":\"3pm\"}", tool_call_id: ""}
      ]

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      # Extract function_call items (in order) and function_call_output items (in order)
      function_calls =
        Enum.filter(input, &(&1["type"] == "function_call"))

      function_call_outputs =
        Enum.filter(input, &(&1["type"] == "function_call_output"))

      assert length(function_calls) == 2,
             "Expected 2 function_call items, got #{length(function_calls)}"

      assert length(function_call_outputs) == 2,
             "Expected 2 function_call_output items, got #{length(function_call_outputs)}"

      # All IDs must be non-empty and valid
      for fc <- function_calls do
        assert fc["id"] != "", "function_call id must not be empty"
        assert fc["call_id"] != "", "function_call call_id must not be empty"

        assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, fc["id"]),
               "function_call id has invalid chars: #{inspect(fc["id"])}"

        # (code_puppy-be7.4) function_call.id must start with "fc"
        assert String.starts_with?(fc["id"], "fc_"),
               "function_call id must start with fc_: #{inspect(fc["id"])}"
      end

      for output <- function_call_outputs do
        assert output["call_id"] != "", "function_call_output call_id must not be empty"

        assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, output["call_id"]),
               "function_call_output call_id has invalid chars: #{inspect(output["call_id"])}"
      end

      # Pairwise matching: first output matches first function call, second matches second
      [fc1, fc2] = function_calls
      [out1, out2] = function_call_outputs

      assert fc1["call_id"] == out1["call_id"],
             "First function_call call_id #{inspect(fc1["call_id"])} must match first output call_id #{inspect(out1["call_id"])}"

      assert fc2["call_id"] == out2["call_id"],
             "Second function_call call_id #{inspect(fc2["call_id"])} must match second output call_id #{inspect(out2["call_id"])}"

      # The two synthetic IDs must be different (each tool call gets its own)
      assert fc1["call_id"] != fc2["call_id"],
             "Two empty-id tool calls must get distinct synthetic IDs, both got #{inspect(fc1["call_id"])}"
    end

    test "both nil IDs generate matching synthetic IDs" do
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

      # Both IDs nil — synthetic IDs must match
      messages = [
        %{role: "user", content: "run tool"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{id: nil, type: "function", function: %{name: "get_weather", arguments: "{}"}}
          ]
        },
        %{role: "tool", content: "sunny", tool_call_id: nil}
      ]

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      # Find the function_call and function_call_output items
      fc = Enum.find(input, &(&1["type"] == "function_call"))
      output = Enum.find(input, &(&1["type"] == "function_call_output"))

      assert fc != nil, "Expected a function_call item"
      assert output != nil, "Expected a function_call_output item"

      # The function_call's call_id must match the output's call_id
      assert fc["call_id"] == output["call_id"],
             "Synthetic IDs must match: function_call call_id=#{inspect(fc["call_id"])} != function_call_output call_id=#{inspect(output["call_id"])}"

      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, fc["call_id"]),
             "call_id has invalid chars: #{inspect(fc["call_id"])}"

      # (code_puppy-be7.4) function_call.id must start with "fc"
      assert String.starts_with?(fc["id"], "fc_"),
             "function_call id must start with fc_: #{inspect(fc["id"])}"
    end

    # (code_puppy-be7.4) Regression: provider call_id "call_mS6k..." must
    # produce function_call.id starting with "fc", while call_id remains
    # "call_mS6k..." and function_call_output.call_id matches it exactly.
    test "provider call_id like call_mS6k produces fc-prefixed item id and matching call_ids" do
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

      messages = [
        %{role: "user", content: "run tool"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "call_mS6k4S5dHefGwE7wdEQoNEP1",
              type: "function",
              function: %{name: "get_weather", arguments: "{\"location\":\"Boston\"}"}
            }
          ]
        },
        %{role: "tool", content: "{\"temp\":72}", tool_call_id: "call_mS6k4S5dHefGwE7wdEQoNEP1"}
      ]

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      fc = Enum.find(input, &(&1["type"] == "function_call"))
      output = Enum.find(input, &(&1["type"] == "function_call_output"))

      assert fc != nil, "Expected a function_call item"
      assert output != nil, "Expected a function_call_output item"

      # function_call.id must start with "fc" (not "call_")
      assert String.starts_with?(fc["id"], "fc_"),
             "function_call.id must start with fc_, got: #{inspect(fc["id"])}"

      # function_call.call_id preserves the original provider correlation id
      assert fc["call_id"] == "call_mS6k4S5dHefGwE7wdEQoNEP1",
             "function_call.call_id must preserve original call_id, got: #{inspect(fc["call_id"])}"

      # function_call_output.call_id must match function_call.call_id exactly
      assert output["call_id"] == fc["call_id"],
             "function_call_output.call_id #{inspect(output["call_id"])} must match function_call.call_id #{inspect(fc["call_id"])}"

      # function_call.id and function_call.call_id should differ
      # (the item id is a separate fc-prefixed id)
      assert fc["id"] != fc["call_id"],
             "function_call.id and call_id should be different for call_-prefixed ids, both: #{inspect(fc["id"])}"
    end

    # (code_puppy-be7.4) Backward compat: history with fc_-prefixed id
    # reuses it as the item id and also as call_id (since fc_ is valid
    # for both fields).
    test "existing fc_-prefixed id is reused as both item id and call_id" do
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

      messages = [
        %{role: "user", content: "run tool"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "fc_abc123",
              type: "function",
              function: %{name: "my_tool", arguments: "{}"}
            }
          ]
        },
        %{role: "tool", content: "result", tool_call_id: "fc_abc123"}
      ]

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      fc = Enum.find(input, &(&1["type"] == "function_call"))
      output = Enum.find(input, &(&1["type"] == "function_call_output"))

      assert fc != nil
      assert output != nil

      # fc_-prefixed id is reused as the item id
      assert fc["id"] == "fc_abc123",
             "Expected function_call.id to be fc_abc123, got: #{inspect(fc["id"])}"

      # call_id is also fc_abc123 (reused since it's valid for both)
      assert fc["call_id"] == "fc_abc123",
             "Expected function_call.call_id to be fc_abc123, got: #{inspect(fc["call_id"])}"

      # output matches
      assert output["call_id"] == "fc_abc123",
             "Expected function_call_output.call_id to be fc_abc123, got: #{inspect(output["call_id"])}"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

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
