defmodule CodePuppyControl.LLM.Providers.OutboundBodyCodexParityTest do
  @moduledoc """
  Outbound request body tests for ChatGPT Codex provider and cross-provider
  parity assertions.

  ChatGPT Codex uses the Responses API wire format, which differs significantly
  from OpenAI Chat Completions. The cross-provider parity tests verify that
  system prompt placement and tool payload keys follow each provider's contract.
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
  alias CodePuppyControl.Test.OutboundBodyHelpers

  import OutboundBodyHelpers,
    only: [
      setup_mock: 0,
      capture_body: 3,
      capture_body_stream: 3,
      ok_anthropic_fixture: 0,
      ok_openai_fixture: 0,
      ok_google_fixture: 0,
      sample_tool: 0,
      codex_stream_fixture: 0
    ]

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

    test "body uses input not messages" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert Map.has_key?(body, "input")
      refute Map.has_key?(body, "messages"), "Codex should use 'input', not 'messages'"
    end

    test "stream: true and store: false are always present" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["stream"] == true
      assert body["store"] == false
    end

    test "system prompt from opts placed in instructions field" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

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

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

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

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      opts = Keyword.put(@opts, :system_prompt, "From opts.")
      ChatGPTCodex.stream_chat(messages, [], opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["instructions"] == "From opts.\n\nFrom messages."
    end

    test "no instructions field when no system prompt from any source" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "instructions")
    end

    test "tools use Responses-style flat format" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      ChatGPTCodex.stream_chat(
        [%{role: "user", content: "Hi"}],
        [sample_tool()],
        @opts,
        fn _ -> :ok end
      )

      assert_received {:request_body, body}
      [tool] = body["tools"]
      assert tool["type"] == "function"
      assert tool["name"] == "read_file"
      assert tool["description"] == "Read a file from disk"
      assert Map.has_key?(tool, "parameters")
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

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      ChatGPTCodex.stream_chat(messages, [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      input = body["input"]

      fc_items = Enum.filter(input, &(&1["type"] == "function_call"))
      assert length(fc_items) >= 1

      fc = hd(fc_items)
      assert fc["name"] == "read_file"
      assert fc["call_id"] != nil
      assert fc["id"] != nil
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

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

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

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      assert body["reasoning"]["effort"] == "medium"
      assert body["reasoning"]["summary"] == "auto"
    end

    test "reasoning not injected for non-reasoning models" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      opts = Keyword.put(@opts, :model, "gpt-4o-mini")
      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "reasoning")
    end

    test "no max_tokens or max_output_tokens in body" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_body, body}
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_output_tokens")
    end

    test "URL ends with /responses" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

      ChatGPTCodex.stream_chat([%{role: "user", content: "Hi"}], [], @opts, fn _ -> :ok end)

      assert_received {:request_url, url}
      assert url =~ "/responses"
      refute url =~ "/v1/chat/completions"
    end

    test "auth header is Authorization Bearer" do
      test_pid = self()

      capture_body_stream(test_pid, "/responses", codex_stream_fixture())

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

    test "Anthropic uses input_schema; OpenAI uses parameters" do
      test_pid = self()

      MockLLMHTTP.register(fn :post, url, opts ->
        cond do
          url =~ "/messages" ->
            body = Jason.decode!(opts[:body])
            send(test_pid, {:anthropic_body, body})
            {:ok, %{status: 200, body: MockLLMHTTP.anthropic_chat_fixture(), headers: []}}

          url =~ "/chat/completions" ->
            body = Jason.decode!(opts[:body])
            send(test_pid, {:openai_body, body})
            {:ok, %{status: 200, body: MockLLMHTTP.openai_chat_fixture(), headers: []}}

          true ->
            {:passthrough}
        end
      end)

      anthropic_opts = [api_key: "k", model: "claude-sonnet-4-20250514", http_client: MockLLMHTTP]
      Anthropic.chat([%{role: "user", content: "Hi"}], [sample_tool()], anthropic_opts)

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
      OpenAI.chat([%{role: "user", content: "Hi"}], [sample_tool()], openai_opts)

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
      Google.chat([%{role: "user", content: "Hi"}], [sample_tool()], google_opts)

      assert_received {:google_body, body}
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
        [sample_tool()],
        codex_opts,
        fn _ -> :ok end
      )

      assert_received {:codex_body, body}
      [tool] = body["tools"]
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

    test "OpenAI-compat providers keep system in messages" do
      test_pid = self()

      for {provider, opts} <- [
            {"openai", [api_key: "k", model: "gpt-4o", http_client: MockLLMHTTP]},
            {"groq", [api_key: "k", model: "llama-3.3-70b-versatile", http_client: MockLLMHTTP]},
            {"azure",
             [
               api_key: "k",
               base_url: "https://x.openai.azure.com",
               deployment: "gpt-4o",
               http_client: MockLLMHTTP
             ]},
            {"together",
             [api_key: "k", model: "meta-llama/Llama-3-70b-chat-hf", http_client: MockLLMHTTP]}
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

        system_msgs = Enum.filter(body["messages"], &(&1["role"] == "system"))

        assert length(system_msgs) >= 1,
               "#{provider}: expected system message in messages array"

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

      capture_body(test_pid, "/messages", &ok_anthropic_fixture/0)

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
