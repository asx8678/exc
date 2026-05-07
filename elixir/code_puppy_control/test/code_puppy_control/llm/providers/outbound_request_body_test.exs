defmodule CodePuppyControl.LLM.Providers.OutboundRequestBodyTest do
  @moduledoc """
  Outbound request body contract tests for all LLM providers.

  These tests intercept the HTTP request body via MockLLMHTTP and assert
  the exact shape of the outbound payload. They catch prompt/body shape
  regressions, system prompt normalization issues, tool payload shape
  changes, and provider-specific quirks — without hitting real APIs.

  Provider differences tested:

  | Provider  | System Prompt Location   | Tool Shape Key    | Auth Header        | Body Key  |
  |----------|-------------------------|--------------------|--------------------|-----------|
  | Anthropic| Top-level `system`       | `input_schema`     | `x-api-key`        | `messages`|
  | OpenAI   | In `messages` array     | `function.parameters`| `Authorization`  | `messages`|
  | Google   | Top-level `systemInstruction`| `functionDeclarations`| Query param `key`| `contents`|
  | Groq     | In `messages` array     | `function.parameters`| `Authorization`  | `messages`|
  | Azure    | In `messages` array     | `function.parameters`| `api-key`         | `messages`|
  | Together | In `messages` array     | `function.parameters`| `Authorization`  | `messages`|
  | Codex    | Top-level `instructions`| `name` (flat)     | `Authorization`    | `input`   |
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.{
    Anthropic,
    OpenAI,
    Google,
    Groq,
    Azure,
    Together,
    ChatGPTCodex
  }

  alias CodePuppyControl.Test.MockLLMHTTP

  # ── Shared helpers ────────────────────────────────────────────────────────

  defp setup_mock, do: start_supervised!(MockLLMHTTP)

  defp capture_body(test_pid, url_pattern, fixture_fn) do
    MockLLMHTTP.register(fn :post, url, opts ->
      if url =~ url_pattern do
        body = Jason.decode!(opts[:body])
        send(test_pid, {:request_body, body})
        send(test_pid, {:request_headers, opts[:headers]})
        send(test_pid, {:request_url, url})
        fixture_fn.()
      else
        {:passthrough}
      end
    end)
  end

  defp capture_body_stream(test_pid, url_pattern, stream_fixture) do
    MockLLMHTTP.register(fn :post, url, opts ->
      if url =~ url_pattern do
        body = Jason.decode!(opts[:body])
        send(test_pid, {:request_body, body})
        send(test_pid, {:request_headers, opts[:headers]})
        send(test_pid, {:request_url, url})

        {:ok,
         %{status: 200, body: stream_fixture, headers: [{"content-type", "text/event-stream"}]}}
      else
        {:passthrough}
      end
    end)
  end

  defp ok_fixture,
    do: {:ok, %{status: 200, body: MockLLMHTTP.anthropic_chat_fixture(), headers: []}}

  defp ok_openai_fixture,
    do: {:ok, %{status: 200, body: MockLLMHTTP.openai_chat_fixture(), headers: []}}

  defp ok_google_fixture,
    do: {:ok, %{status: 200, body: MockLLMHTTP.google_chat_fixture(), headers: []}}

  @sample_tool %{
    type: "function",
    function: %{
      name: "read_file",
      description: "Read a file from disk",
      parameters: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"]
      }
    }
  }

  # ══════════════════════════════════════════════════════════════════════════
  # ANTHROPIC
  # ══════════════════════════════════════════════════════════════════════════

  describe "Anthropic outbound body" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @opts [api_key: "sk-ant-test", model: "claude-sonnet-4-20250514", http_client: MockLLMHTTP]

    test "system prompt from opts merges with system messages" do
      test_pid = self()

      messages = [
        %{role: "system", content: "From messages."},
        %{role: "user", content: "Hi"}
      ]

      capture_body(test_pid, "/messages", &ok_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "From opts.")
      Anthropic.chat(messages, [], opts)

      assert_received {:request_body, body}
      # Anthropic merges opts + messages, opts first
      assert body["system"] == "From opts.\n\nFrom messages."
      # System messages removed from messages array
      assert length(body["messages"]) == 1
      assert hd(body["messages"])["role"] == "user"
    end

    test "system prompt from opts only when no system messages" do
      test_pid = self()

      messages = [%{role: "user", content: "Hi"}]

      capture_body(test_pid, "/messages", &ok_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "Be helpful")
      Anthropic.chat(messages, [], opts)

      assert_received {:request_body, body}
      assert body["system"] == "Be helpful"
    end

    test "no system field when no system prompt from any source" do
      test_pid = self()

      messages = [%{role: "user", content: "Hi"}]

      capture_body(test_pid, "/messages", &ok_fixture/0)

      Anthropic.chat(messages, [], @opts)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "system")
    end

    test "tool definitions use input_schema not parameters" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_fixture/0)

      Anthropic.chat([%{role: "user", content: "Hi"}], [@sample_tool], @opts)

      assert_received {:request_body, body}
      assert is_list(body["tools"])
      [tool] = body["tools"]
      assert tool["name"] == "read_file"
      assert tool["description"] == "Read a file from disk"
      # Anthropic uses input_schema, not parameters
      assert Map.has_key?(tool, "input_schema")
      refute Map.has_key?(tool, "parameters")
      assert tool["input_schema"]["type"] == "object"
    end

    test "tool_result messages use tool_use_id and content blocks" do
      test_pid = self()

      messages = [
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "tc-1",
              type: "function",
              function: %{name: "read_file", arguments: "{\"path\":\"a.ex\"}"}
            }
          ]
        },
        %{role: "tool", content: "file contents", tool_call_id: "tc-1"}
      ]

      capture_body(test_pid, "/messages", &ok_fixture/0)

      Anthropic.chat(messages, [], @opts)

      assert_received {:request_body, body}
      # Tool result should use content block format
      tool_msg = Enum.find(body["messages"], &(&1["role"] == "tool"))

      assert is_list(tool_msg["content"]),
             "Expected tool_result as content blocks list, got: #{inspect(tool_msg["content"])}"

      [block] = tool_msg["content"]
      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "tc-1"
    end

    test "required body fields present: model, max_tokens, messages, stream" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_fixture/0)

      Anthropic.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_body, body}
      assert body["model"] == "claude-sonnet-4-20250514"
      assert is_integer(body["max_tokens"])
      assert is_list(body["messages"])
      assert body["stream"] == false
    end

    test "optional temperature and max_tokens pass-through" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_fixture/0)

      opts = @opts ++ [temperature: 0.7, max_tokens: 2048]
      Anthropic.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert body["temperature"] == 0.7
      assert body["max_tokens"] == 2048
    end

    test "auth header is x-api-key not Authorization Bearer" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_fixture/0)

      Anthropic.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_headers, headers}
      assert List.keyfind(headers, "x-api-key", 0) == {"x-api-key", "sk-ant-test"}
      assert List.keyfind(headers, "authorization", 0) == nil
    end

    test "anthropic-version header present" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_fixture/0)

      Anthropic.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_headers, headers}
      assert List.keyfind(headers, "anthropic-version", 0) != nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # OPENAI
  # ══════════════════════════════════════════════════════════════════════════

  describe "OpenAI outbound body" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @opts [api_key: "sk-oai-test", model: "gpt-4o", http_client: MockLLMHTTP]

    test "system prompt from opts prepended to messages" do
      test_pid = self()

      messages = [%{role: "user", content: "Hi"}]

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "Be helpful")
      OpenAI.chat(messages, [], opts)

      assert_received {:request_body, body}
      # System message should be first
      assert hd(body["messages"])["role"] == "system"
      assert hd(body["messages"])["content"] == "Be helpful"
    end

    test "system prompt opt not duplicated when system messages already present" do
      test_pid = self()

      messages = [
        %{role: "system", content: "Existing"},
        %{role: "user", content: "Hi"}
      ]

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "Should not duplicate")
      OpenAI.chat(messages, [], opts)

      assert_received {:request_body, body}
      system_msgs = Enum.filter(body["messages"], &(&1["role"] == "system"))
      assert length(system_msgs) == 1
      assert hd(system_msgs)["content"] == "Existing"
    end

    test "tool definitions use function.parameters shape" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      OpenAI.chat([%{role: "user", content: "Hi"}], [@sample_tool], @opts)

      assert_received {:request_body, body}
      assert is_list(body["tools"])
      [tool] = body["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read_file"
      assert tool["function"]["description"] == "Read a file from disk"
      # OpenAI uses parameters, not input_schema
      assert Map.has_key?(tool["function"], "parameters")
      refute Map.has_key?(tool["function"], "input_schema")
    end

    test "assistant tool_calls formatted with id/type/function" do
      test_pid = self()

      messages = [
        %{role: "user", content: "Hi"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "call_1",
              type: "function",
              function: %{name: "read_file", arguments: "{\"path\":\"a.ex\"}"}
            }
          ]
        }
      ]

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      OpenAI.chat(messages, [], @opts)

      assert_received {:request_body, body}
      asst_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert is_list(asst_msg["tool_calls"])
      [tc] = asst_msg["tool_calls"]
      assert tc["id"] == "call_1"
      assert tc["type"] == "function"
      assert tc["function"]["name"] == "read_file"
    end

    test "tool messages include tool_call_id" do
      test_pid = self()

      messages = [
        %{role: "tool", content: "file contents", tool_call_id: "call_1"}
      ]

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      OpenAI.chat(messages, [], @opts)

      assert_received {:request_body, body}
      [tool_msg] = body["messages"]
      assert tool_msg["role"] == "tool"
      assert tool_msg["tool_call_id"] == "call_1"
    end

    test "optional temperature and max_tokens pass-through" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = @opts ++ [temperature: 0.5, max_tokens: 1024]
      OpenAI.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert body["temperature"] == 0.5
      assert body["max_tokens"] == 1024
    end

    test "no temperature or max_tokens when opts not provided" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      OpenAI.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "max_tokens")
    end

    test "auth header is Authorization Bearer" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      OpenAI.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_headers, headers}
      assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer sk-oai-test"}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GOOGLE GEMINI
  # ══════════════════════════════════════════════════════════════════════════

  describe "Google outbound body" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @opts [api_key: "google-test-key", model: "gemini-1.5-flash", http_client: MockLLMHTTP]

    test "body uses contents array, not messages" do
      test_pid = self()

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_body, body}
      assert Map.has_key?(body, "contents")
      refute Map.has_key?(body, "messages"), "Google should use 'contents', not 'messages'"
    end

    test "system prompt placed in top-level systemInstruction" do
      test_pid = self()

      messages = [
        %{role: "system", content: "Be helpful."},
        %{role: "user", content: "Hi"}
      ]

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat(messages, [], @opts)

      assert_received {:request_body, body}
      assert body["systemInstruction"] == %{"parts" => [%{"text" => "Be helpful."}]}
      # System messages removed from contents
      refute Enum.any?(body["contents"], &(&1["role"] == "system"))
    end

    test "system prompt from opts merges with messages" do
      test_pid = self()

      messages = [
        %{role: "system", content: "From messages."},
        %{role: "user", content: "Hi"}
      ]

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "From opts.")
      Google.chat(messages, [], opts)

      assert_received {:request_body, body}
      # Merged: opts first, then messages
      expected_text = "From opts.\n\nFrom messages."
      assert body["systemInstruction"] == %{"parts" => [%{"text" => expected_text}]}
    end

    test "assistant role mapped to model in contents" do
      test_pid = self()

      messages = [
        %{role: "user", content: "Hi"},
        %{role: "assistant", content: "Hello!"}
      ]

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat(messages, [], @opts)

      assert_received {:request_body, body}
      roles = Enum.map(body["contents"], & &1["role"])
      assert roles == ["user", "model"], "assistant should map to model, got: #{inspect(roles)}"
    end

    test "tool role mapped to user in contents" do
      test_pid = self()

      messages = [
        %{role: "tool", content: "result", tool_call_id: "tc-1"}
      ]

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat(messages, [], @opts)

      assert_received {:request_body, body}

      assert hd(body["contents"])["role"] == "user",
             "tool role should map to user in Google API"
    end

    test "tool definitions use functionDeclarations inside tools array" do
      test_pid = self()

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat([%{role: "user", content: "Hi"}], [@sample_tool], @opts)

      assert_received {:request_body, body}
      assert is_list(body["tools"])
      [tool_set] = body["tools"]
      assert Map.has_key?(tool_set, "functionDeclarations")
      [decl] = tool_set["functionDeclarations"]
      assert decl["name"] == "read_file"
      assert decl["description"] == "Read a file from disk"
      assert Map.has_key?(decl, "parameters")
    end

    test "generationConfig includes temperature and maxOutputTokens" do
      test_pid = self()

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      opts = @opts ++ [temperature: 0.3, max_tokens: 512]
      Google.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert body["generationConfig"]["temperature"] == 0.3
      assert body["generationConfig"]["maxOutputTokens"] == 512
    end

    test "no generationConfig when no optional params" do
      test_pid = self()

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_body, body}

      refute Map.has_key?(body, "generationConfig"),
             "generationConfig should be absent when no temp/max_tokens opts"
    end

    test "API key passed as query parameter, not in headers" do
      test_pid = self()

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_url, url}
      assert url =~ "key=google-test-key"

      assert_received {:request_headers, headers}
      # No Authorization header for Google
      assert List.keyfind(headers, "authorization", 0) == nil
    end

    test "contents use parts array for content" do
      test_pid = self()

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat([%{role: "user", content: "Hello world"}], [], @opts)

      assert_received {:request_body, body}
      [content] = body["contents"]
      assert is_list(content["parts"])
      assert Enum.any?(content["parts"], &(&1["text"] == "Hello world"))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GROQ
  # ══════════════════════════════════════════════════════════════════════════

  describe "Groq outbound body" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @opts [api_key: "gsk-test", model: "llama-3.3-70b-versatile", http_client: MockLLMHTTP]

    test "URL path uses /openai/v1/chat/completions" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Groq.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_url, url}
      assert url =~ "/openai/v1/chat/completions"
    end

    test "system prompt prepended to messages" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "Be helpful")
      Groq.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert hd(body["messages"])["role"] == "system"
      assert hd(body["messages"])["content"] == "Be helpful"
    end

    test "tool definitions use OpenAI-compatible shape" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Groq.chat([%{role: "user", content: "Hi"}], [@sample_tool], @opts)

      assert_received {:request_body, body}
      [tool] = body["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read_file"
      assert Map.has_key?(tool["function"], "parameters")
    end

    test "assistant tool_calls formatted correctly" do
      test_pid = self()

      messages = [
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "call_g1",
              type: "function",
              function: %{name: "read_file", arguments: "{\"path\":\"x\"}"}
            }
          ]
        }
      ]

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Groq.chat(messages, [], @opts)

      assert_received {:request_body, body}
      [asst] = body["messages"]
      assert is_list(asst["tool_calls"])
      [tc] = asst["tool_calls"]
      assert tc["id"] == "call_g1"
      assert tc["function"]["name"] == "read_file"
    end

    test "tool messages include tool_call_id" do
      test_pid = self()

      messages = [%{role: "tool", content: "result", tool_call_id: "call_g1"}]

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Groq.chat(messages, [], @opts)

      assert_received {:request_body, body}
      [msg] = body["messages"]
      assert msg["role"] == "tool"
      assert msg["tool_call_id"] == "call_g1"
    end

    test "auth header is Authorization Bearer" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Groq.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_headers, headers}
      assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer gsk-test"}
    end

    test "optional temperature and max_tokens pass-through" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = @opts ++ [temperature: 0.2, max_tokens: 256]
      Groq.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert body["temperature"] == 0.2
      assert body["max_tokens"] == 256
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AZURE OPENAI
  # ══════════════════════════════════════════════════════════════════════════

  describe "Azure outbound body" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @opts [
      api_key: "azure-test-key",
      base_url: "https://myresource.openai.azure.com",
      deployment: "gpt-4o-deploy",
      http_client: MockLLMHTTP
    ]

    test "URL includes deployment and api-version" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Azure.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_url, url}
      assert url =~ "/openai/deployments/gpt-4o-deploy/chat/completions"
      assert url =~ "api-version="
    end

    test "auth header is api-key, not Authorization Bearer" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Azure.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_headers, headers}
      # Azure uses api-key header
      assert List.keyfind(headers, "api-key", 0) == {"api-key", "azure-test-key"}
      # Should NOT use Authorization Bearer
      assert List.keyfind(headers, "authorization", 0) == nil
    end

    test "system prompt prepended to messages" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "Azure system prompt")
      Azure.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert hd(body["messages"])["role"] == "system"
      assert hd(body["messages"])["content"] == "Azure system prompt"
    end

    test "tool definitions use OpenAI-compatible shape" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Azure.chat([%{role: "user", content: "Hi"}], [@sample_tool], @opts)

      assert_received {:request_body, body}
      [tool] = body["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read_file"
    end

    test "assistant tool_calls and tool messages formatted correctly" do
      test_pid = self()

      messages = [
        %{role: "user", content: "Hi"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{id: "call_az1", type: "function", function: %{name: "search", arguments: "{}"}}
          ]
        },
        %{role: "tool", content: "found", tool_call_id: "call_az1"}
      ]

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Azure.chat(messages, [], @opts)

      assert_received {:request_body, body}
      asst = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert is_list(asst["tool_calls"])
      tool_msg = Enum.find(body["messages"], &(&1["role"] == "tool"))
      assert tool_msg["tool_call_id"] == "call_az1"
    end

    test "model field defaults to deployment name" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Azure.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_body, body}
      assert body["model"] == "gpt-4o-deploy"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # TOGETHER AI
  # ══════════════════════════════════════════════════════════════════════════

  describe "Together outbound body" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @opts [
      api_key: "together-test",
      model: "meta-llama/Llama-3-70b-chat-hf",
      http_client: MockLLMHTTP
    ]

    test "URL path uses /v1/chat/completions" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Together.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_url, url}
      assert url =~ "/v1/chat/completions"
    end

    test "system prompt prepended to messages" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "Together system")
      Together.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert hd(body["messages"])["role"] == "system"
    end

    test "tool definitions use OpenAI-compatible shape" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Together.chat([%{role: "user", content: "Hi"}], [@sample_tool], @opts)

      assert_received {:request_body, body}
      [tool] = body["tools"]
      assert tool["function"]["name"] == "read_file"
      assert Map.has_key?(tool["function"], "parameters")
    end

    test "auth header is Authorization Bearer" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      Together.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_headers, headers}

      assert List.keyfind(headers, "authorization", 0) ==
               {"authorization", "Bearer together-test"}
    end

    test "optional temperature and max_tokens pass-through" do
      test_pid = self()

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = @opts ++ [temperature: 0.8, max_tokens: 4096]
      Together.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert body["temperature"] == 0.8
      assert body["max_tokens"] == 4096
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # CHATGPT CODEX (Responses-style)
  # ══════════════════════════════════════════════════════════════════════════

  describe "ChatGPT Codex outbound body" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @opts [
      api_key: "oauth-test-token",
      model: "gpt-5.4",
      base_url: "https://chatgpt.com/backend-api/codex",
      http_client: MockLLMHTTP
    ]

    @stream_fixture MockLLMHTTP.chatgpt_codex_stream_fixture()

    test "body uses input not messages" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert Map.has_key?(body, "input")
      refute Map.has_key?(body, "messages"), "Codex should use 'input', not 'messages'"
    end

    test "stream: true and store: false are always present" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["stream"] == true
      assert body["store"] == false
    end

    test "system prompt from opts placed in instructions field" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      opts = Keyword.put(@opts, :system_prompt, "Codex system")
      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["instructions"] == "Codex system"
    end

    test "system prompt from messages also placed in instructions" do
      test_pid = self()

      messages = [
        %{role: "system", content: "From messages."},
        %{role: "user", content: "Hi"}
      ]

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["instructions"] == "From messages."
    end

    test "system prompt opts and messages merged" do
      test_pid = self()

      messages = [
        %{role: "system", content: "From messages."},
        %{role: "user", content: "Hi"}
      ]

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      opts = Keyword.put(@opts, :system_prompt, "From opts.")
      ChatGPTCodex.stream_chat(messages, [], opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["instructions"] == "From opts.\n\nFrom messages."
    end

    test "no instructions field when no system prompt from any source" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "instructions")
    end

    test "tools use Responses-style flat format" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [@sample_tool], @opts, fn _ ->
        :ok
      end)

      assert_received {:request_body, body}
      [tool] = body["tools"]
      assert tool["type"] == "function"
      assert tool["name"] == "read_file"
      assert tool["description"] == "Read a file from disk"
      assert Map.has_key?(tool, "parameters")
      # Should NOT have nested "function" key
      refute Map.has_key?(tool, "function")
    end

    test "assistant tool_calls become separate function_call input items" do
      test_pid = self()

      messages = [
        %{role: "user", content: "Hi"},
        %{
          role: "assistant",
          content: "Let me check",
          tool_calls: [
            %{
              id: "call_1",
              type: "function",
              function: %{name: "read_file", arguments: "{\"path\":\"a.ex\"}"}
            }
          ]
        }
      ]

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      # Should have function_call items in the flat input array
      fc_items = Enum.filter(input, &(&1["type"] == "function_call"))
      assert length(fc_items) >= 1

      fc = hd(fc_items)
      assert fc["name"] == "read_file"
      assert fc["call_id"] != nil
      assert fc["id"] != nil
      # fc item id must start with "fc"
      assert String.starts_with?(fc["id"], "fc_")
    end

    test "tool messages become function_call_output input items" do
      test_pid = self()

      messages = [
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "call_1",
              type: "function",
              function: %{name: "read_file", arguments: "{\"path\":\"a.ex\"}"}
            }
          ]
        },
        %{role: "tool", content: "file contents here", tool_call_id: "call_1"}
      ]

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      fco_items = Enum.filter(input, &(&1["type"] == "function_call_output"))
      assert length(fco_items) >= 1

      fco = hd(fco_items)
      assert fco["output"] == "file contents here"
      assert fco["call_id"] != nil
    end

    test "reasoning defaults injected for gpt-5 model" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["reasoning"]["effort"] == "medium"
      assert body["reasoning"]["summary"] == "auto"
    end

    test "reasoning not injected for non-reasoning models" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      opts = Keyword.put(@opts, :model, "gpt-4o-mini")
      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "reasoning")
    end

    test "no max_tokens or max_output_tokens in body" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_output_tokens")
    end

    test "URL ends with /responses" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_url, url}
      assert url =~ "/responses"
      refute url =~ "/v1/chat/completions"
    end

    test "auth header is Authorization Bearer" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", @stream_fixture)

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_headers, headers}

      assert List.keyfind(headers, "authorization", 0) ==
               {"authorization", "Bearer oauth-test-token"}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # CROSS-PROVIDER PARITY: Tool payload key names
  # ══════════════════════════════════════════════════════════════════════════

  describe "cross-provider tool payload key parity" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    test "Anthropic uses input_schema; OpenAI/Groq/Azure/Together use parameters" do
      test_pid = self()

      # Capture Anthropic
      MockLLMHTTP.register(fn :post, url, opts ->
        cond do
          url =~ "/messages" ->
            body = Jason.decode!(opts[:body])
            send(test_pid, {:anthropic_body, body})
            {:ok, %{status: 200, body: MockLLMHTTP.anthropic_chat_fixture(), headers: []}}

          url =~ "/chat/completions" or url =~ "generateContent" ->
            body = Jason.decode!(opts[:body])
            send(test_pid, {:other_body, body, url})
            ok = {:ok, %{status: 200, body: MockLLMHTTP.openai_chat_fixture(), headers: []}}

            g_ok = {:ok, %{status: 200, body: MockLLMHTTP.google_chat_fixture(), headers: []}}

            if url =~ "generateContent", do: g_ok, else: ok

          true ->
            {:passthrough}
        end
      end)

      anthropic_opts = [api_key: "k", model: "claude-sonnet-4-20250514", http_client: MockLLMHTTP]
      Anthropic.chat([%{role: "user", content: "Hi"}], [@sample_tool], anthropic_opts)

      assert_received {:anthropic_body, body}
      [anthropic_tool] = body["tools"]
      assert Map.has_key?(anthropic_tool, "input_schema")
      refute Map.has_key?(anthropic_tool, "parameters")

      MockLLMHTTP.reset()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/chat/completions" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:openai_body, body})
          {:ok, %{status: 200, body: MockLLMHTTP.openai_chat_fixture(), headers: []}}
        else
          {:passthrough}
        end
      end)

      openai_opts = [api_key: "k", model: "gpt-4o", http_client: MockLLMHTTP]
      OpenAI.chat([%{role: "user", content: "Hi"}], [@sample_tool], openai_opts)

      assert_received {:openai_body, body}
      [openai_tool] = body["tools"]
      assert Map.has_key?(openai_tool["function"], "parameters")
      refute Map.has_key?(openai_tool["function"], "input_schema")
    end

    test "Google uses functionDeclarations; others use flat tools array" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "generateContent" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:google_body, body})
          {:ok, %{status: 200, body: MockLLMHTTP.google_chat_fixture(), headers: []}}
        else
          {:passthrough}
        end
      end)

      google_opts = [api_key: "k", model: "gemini-1.5-flash", http_client: MockLLMHTTP]
      Google.chat([%{role: "user", content: "Hi"}], [@sample_tool], google_opts)

      assert_received {:google_body, body}
      # Google wraps in functionDeclarations
      assert is_list(body["tools"])
      [tool_set] = body["tools"]
      assert Map.has_key?(tool_set, "functionDeclarations")
    end

    test "Codex uses flat tool shape without nested function key" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/responses" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:codex_body, body})

          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.chatgpt_codex_stream_fixture(),
             headers: [{"content-type", "text/event-stream"}]
           }}
        else
          {:passthrough}
        end
      end)

      codex_opts = [
        api_key: "k",
        model: "gpt-5.4",
        http_client: MockLLMHTTP,
        base_url: "https://chatgpt.com/backend-api/codex"
      ]

      ChatGPTCodex.stream_chat(
        [%{role: "user", content: "Hi"}],
        [@sample_tool],
        codex_opts,
        fn _ -> :ok end
      )

      assert_received {:codex_body, body}
      [tool] = body["tools"]
      # Codex: flat shape with type, name, description, parameters at top level
      assert tool["type"] == "function"
      assert tool["name"] == "read_file"
      refute Map.has_key?(tool, "function")
      refute Map.has_key?(tool, "input_schema")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # CROSS-PROVIDER PARITY: System prompt placement
  # ══════════════════════════════════════════════════════════════════════════

  describe "cross-provider system prompt placement" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @sys_prompt "You are a helpful coding assistant."
    @messages [%{role: "user", content: "Write a function"}]

    test "OpenAI-compat providers (OpenAI, Groq, Azure, Together) keep system in messages" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/chat/completions" do
          body = Jason.decode!(opts[:body])
          send(test_pid, {:body, body, url})
          {:ok, %{status: 200, body: MockLLMHTTP.openai_chat_fixture(), headers: []}}
        else
          {:passthrough}
        end
      end)

      base_opts = [api_key: "k", http_client: MockLLMHTTP]

      for {provider, opts} <- [
            {"openai", Keyword.put(base_opts, :model, "gpt-4o")},
            {"groq", Keyword.put(base_opts, :model, "llama-3.3-70b-versatile")},
            {"azure",
             Keyword.merge(base_opts,
               base_url: "https://x.openai.azure.com",
               deployment: "gpt-4o"
             )},
            {"together", Keyword.put(base_opts, :model, "meta-llama/Llama-3-70b-chat-hf")}
          ] do
        MockLLMHTTP.reset()

        MockLLMHTTP.register(fn :post, url, opts_inner ->
          if url =~ "/chat/completions" do
            body = Jason.decode!(opts_inner[:body])
            send(test_pid, {:body, body, provider})
            {:ok, %{status: 200, body: MockLLMHTTP.openai_chat_fixture(), headers: []}}
          else
            {:passthrough}
          end
        end)

        opts_with_sys = Keyword.put(opts, :system_prompt, @sys_prompt)

        case provider do
          "openai" -> OpenAI.chat(@messages, [], opts_with_sys)
          "groq" -> Groq.chat(@messages, [], opts_with_sys)
          "azure" -> Azure.chat(@messages, [], opts_with_sys)
          "together" -> Together.chat(@messages, [], opts_with_sys)
        end

        assert_received {:body, body, ^provider}

        # All OpenAI-compat: system message should be in messages array
        system_msgs = Enum.filter(body["messages"], &(&1["role"] == "system"))

        assert length(system_msgs) >= 1,
               "#{provider}: expected system message in messages array"

        # None should have top-level system/instructions/systemInstruction
        refute Map.has_key?(body, "system"),
               "#{provider}: should not have top-level 'system' field"

        refute Map.has_key?(body, "instructions"),
               "#{provider}: should not have 'instructions' field"

        refute Map.has_key?(body, "systemInstruction"),
               "#{provider}: should not have 'systemInstruction' field"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # STRING-KEYED INPUT PARITY
  # ══════════════════════════════════════════════════════════════════════════

  describe "string-keyed message input" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    test "Anthropic handles string-keyed messages and tool_calls" do
      test_pid = self()

      messages = [
        %{"role" => "user", "content" => "Hi"},
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "tc-str",
              "type" => "function",
              "function" => %{"name" => "run", "arguments" => "{}"}
            }
          ]
        }
      ]

      capture_body(test_pid, "/messages", &ok_fixture/0)

      opts = [api_key: "k", model: "claude-sonnet-4-20250514", http_client: MockLLMHTTP]
      Anthropic.chat(messages, [], opts)

      assert_received {:request_body, body}
      asst = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert is_list(asst["content"])
      [block] = asst["content"]
      assert block["type"] == "tool_use"
      assert block["name"] == "run"
    end

    test "OpenAI handles string-keyed messages and tool_calls" do
      test_pid = self()

      messages = [
        %{"role" => "user", "content" => "Hi"},
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call_str",
              "type" => "function",
              "function" => %{"name" => "run", "arguments" => "{}"}
            }
          ]
        }
      ]

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = [api_key: "k", model: "gpt-4o", http_client: MockLLMHTTP]
      OpenAI.chat(messages, [], opts)

      assert_received {:request_body, body}
      asst = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert is_list(asst["tool_calls"])
      [tc] = asst["tool_calls"]
      assert tc["function"]["name"] == "run"
    end

    test "Google handles string-keyed messages" do
      test_pid = self()

      messages = [
        %{"role" => "system", "content" => "Be helpful"},
        %{"role" => "user", "content" => "Hi"},
        %{"role" => "assistant", "content" => "Hello"}
      ]

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      opts = [api_key: "k", model: "gemini-1.5-flash", http_client: MockLLMHTTP]
      Google.chat(messages, [], opts)

      assert_received {:request_body, body}
      assert body["systemInstruction"]["parts"] != nil
      roles = Enum.map(body["contents"], & &1["role"])
      assert "model" in roles, "assistant should map to model"
    end
  end
end
