defmodule CodePuppyControl.LLM.Providers.OutboundBodyAnthropicOpenAIGoogleTest do
  @moduledoc """
  Outbound request body tests for Anthropic, OpenAI, and Google providers.

  Tests intercept the HTTP request body via MockLLMHTTP and assert the
  exact outbound payload shape. Covers system prompt placement, tool
  payload shape, message formatting, auth headers, and provider quirks.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.{Anthropic, OpenAI, Google}
  alias CodePuppyControl.Test.MockLLMHTTP
  alias CodePuppyControl.Test.OutboundBodyHelpers

  import OutboundBodyHelpers,
    only: [
      setup_mock: 0,
      capture_body: 3,
      ok_anthropic_fixture: 0,
      ok_openai_fixture: 0,
      ok_google_fixture: 0,
      sample_tool: 0
    ]

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

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "From opts.")
      Anthropic.chat(messages, [], opts)

      assert_received {:request_body, body}
      assert body["system"] == "From opts.\n\nFrom messages."
      assert length(body["messages"]) == 1
      assert hd(body["messages"])["role"] == "user"
    end

    test "system prompt from opts only when no system messages" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "Be helpful")
      Anthropic.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert body["system"] == "Be helpful"
    end

    test "no system field when no system prompt from any source" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

      Anthropic.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "system")
    end

    test "tool definitions use input_schema not parameters" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

      Anthropic.chat([%{role: "user", content: "Hi"}], [sample_tool()], @opts)

      assert_received {:request_body, body}
      assert is_list(body["tools"])
      [tool] = body["tools"]
      assert tool["name"] == "read_file"
      assert tool["description"] == "Read a file from disk"
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

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

      Anthropic.chat(messages, [], @opts)

      assert_received {:request_body, body}
      tool_msg = Enum.find(body["messages"], &(&1["role"] == "tool"))

      assert is_list(tool_msg["content"]),
             "Expected tool_result as content blocks list, got: #{inspect(tool_msg["content"])}"

      [block] = tool_msg["content"]
      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "tc-1"
    end

    test "required body fields present: model, max_tokens, messages, stream" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

      Anthropic.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_body, body}
      assert body["model"] == "claude-sonnet-4-20250514"
      assert is_integer(body["max_tokens"])
      assert is_list(body["messages"])
      assert body["stream"] == false
    end

    test "optional temperature and max_tokens pass-through" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

      opts = @opts ++ [temperature: 0.7, max_tokens: 2048]
      Anthropic.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
      assert body["temperature"] == 0.7
      assert body["max_tokens"] == 2048
    end

    test "auth header is x-api-key not Authorization Bearer" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

      Anthropic.chat([%{role: "user", content: "Hi"}], [], @opts)

      assert_received {:request_headers, headers}
      assert List.keyfind(headers, "x-api-key", 0) == {"x-api-key", "sk-ant-test"}
      assert List.keyfind(headers, "authorization", 0) == nil
    end

    test "anthropic-version header present" do
      test_pid = self()

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

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

      capture_body(test_pid, "/chat/completions", &ok_openai_fixture/0)

      opts = Keyword.put(@opts, :system_prompt, "Be helpful")
      OpenAI.chat([%{role: "user", content: "Hi"}], [], opts)

      assert_received {:request_body, body}
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

      OpenAI.chat([%{role: "user", content: "Hi"}], [sample_tool()], @opts)

      assert_received {:request_body, body}
      [tool] = body["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read_file"
      assert tool["function"]["description"] == "Read a file from disk"
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

      messages = [%{role: "tool", content: "file contents", tool_call_id: "call_1"}]

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

      messages = [%{role: "tool", content: "result", tool_call_id: "tc-1"}]

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat(messages, [], @opts)

      assert_received {:request_body, body}

      assert hd(body["contents"])["role"] == "user",
             "tool role should map to user in Google API"
    end

    test "tool definitions use functionDeclarations inside tools array" do
      test_pid = self()

      capture_body(test_pid, "generateContent", &ok_google_fixture/0)

      Google.chat([%{role: "user", content: "Hi"}], [sample_tool()], @opts)

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
end
