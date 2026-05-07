defmodule CodePuppyControl.LLM.Providers.OutboundBodyGroqAzureTogetherTest do
  @moduledoc """
  Outbound request body tests for Groq, Azure, and Together providers.

  These OpenAI-compatible providers share a common messages/tools shape
  but differ in URL paths, auth headers, and other quirks.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.{Groq, Azure, Together}
  alias CodePuppyControl.Test.MockLLMHTTP
  alias CodePuppyControl.Test.OutboundBodyHelpers

  import OutboundBodyHelpers,
    only: [setup_mock: 0, capture_body: 3, ok_openai_fixture: 0, sample_tool: 0]

  # ══════════════════════════════════════════════════════════════════════════
  # GROQ
  # ══════════════════════════════════════════════════════════════════════════

  describe "Groq outbound body" do
    setup do
      setup_mock()
      MockLLMHTTP.reset()
      :ok
    end

    @opts [
      api_key: "gsk-test",
      model: "llama-3.3-70b-versatile",
      http_client: MockLLMHTTP
    ]

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

      Groq.chat([%{role: "user", content: "Hi"}], [sample_tool()], @opts)

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
      assert List.keyfind(headers, "api-key", 0) == {"api-key", "azure-test-key"}
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

      Azure.chat([%{role: "user", content: "Hi"}], [sample_tool()], @opts)

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

      Together.chat([%{role: "user", content: "Hi"}], [sample_tool()], @opts)

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
end
