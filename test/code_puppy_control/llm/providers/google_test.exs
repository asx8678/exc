defmodule CodePuppyControl.LLM.Providers.GoogleTest do
  @moduledoc """
  Tests for the Google Gemini provider implementation.

  Uses MockLLMHTTP to return fixture responses without hitting real APIs.
  Covers: non-streaming chat, SSE streaming, message format conversion,
  system instruction extraction, tool calls, error handling.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.Google
  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  @messages [%{role: "user", content: "Hello"}]
  @opts [api_key: "test-key", model: "gemini-1.5-flash", http_client: MockLLMHTTP]

  describe "chat/3" do
    test "parses a successful response" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "generateContent" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.google_chat_fixture(content: "Hi there!"),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = Google.chat(@messages, [], @opts)
      assert response.content == "Hi there!"
      assert response.finish_reason == "STOP"
      assert response.tool_calls == []
      assert response.usage.prompt_tokens == 10
      assert response.usage.completion_tokens == 20
      assert response.usage.total_tokens == 30
    end

    test "parses function call from response" do
      function_call = %{
        "functionCall" => %{
          "name" => "get_weather",
          "args" => %{"location" => "NYC"}
        },
        "functionCallId" => "call_abc"
      }

      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "generateContent" do
          {:ok,
           %{
             status: 200,
             body:
               MockLLMHTTP.google_chat_fixture(
                 content: nil,
                 function_call: function_call,
                 finish_reason: "STOP"
               ),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = Google.chat(@messages, [], @opts)
      assert response.content == nil
      assert length(response.tool_calls) == 1

      [tc] = response.tool_calls
      assert tc.id == "call_abc"
      assert tc.name == "get_weather"
      assert tc.arguments == %{"location" => "NYC"}
    end

    test "constructs URL with API key as query param" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        send(self(), {:captured_url, url})

        {:ok,
         %{
           status: 200,
           body: MockLLMHTTP.google_chat_fixture(),
           headers: []
         }}
      end)

      Google.chat(@messages, [], @opts)

      assert_received {:captured_url, url}
      assert url =~ "generateContent"
      assert url =~ "key=test-key"
    end

    test "handles HTTP error status" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "generateContent" do
          {:ok,
           %{
             status: 403,
             body:
               Jason.encode!(%{
                 "error" => %{"message" => "API key not valid", "status" => "PERMISSION_DENIED"}
               }),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 403}} = Google.chat(@messages, [], @opts)
    end
  end

  describe "stream_chat/4" do
    test "emits stream events for text content" do
      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "streamGenerateContent" and Keyword.get(opts, :stream_request) do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.google_stream_fixture(chunks: ["Hello", " world"]),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      callback_fn = fn event -> send(self(), event) end

      assert :ok = Google.stream_chat(@messages, [], @opts, callback_fn)

      received = receive_all_events()
      assert Enum.any?(received, &match?({:part_start, _}, &1))
      assert Enum.any?(received, &match?({:part_delta, _}, &1))
      assert Enum.any?(received, &match?({:done, _}, &1))
    end
  end

  describe "provider capabilities" do
    test "supports tools" do
      assert Google.supports_tools?() == true
    end

    test "supports vision" do
      assert Google.supports_vision?() == true
    end
  end

  defp receive_all_events(acc \\ []) do
    receive do
      event -> receive_all_events([event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
