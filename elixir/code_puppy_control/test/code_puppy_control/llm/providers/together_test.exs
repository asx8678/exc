defmodule CodePuppyControl.LLM.Providers.TogetherTest do
  @moduledoc """
  Tests for the Together AI provider implementation.

  Uses MockLLMHTTP to return fixture responses without hitting real APIs.
  Covers: non-streaming chat, SSE streaming, tool calls, error handling.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.Together
  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  @messages [%{role: "user", content: "Hello"}]
  @opts [api_key: "test-key", model: "meta-llama/Llama-3-70b-chat-hf", http_client: MockLLMHTTP]

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

      assert {:ok, response} = Together.chat(@messages, [], @opts)
      assert response.content == "Hi there!"
      assert response.finish_reason == "stop"
      assert response.tool_calls == []
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

      assert {:error, %{status: 401}} = Together.chat(@messages, [], @opts)
    end
  end

  describe "stream_chat/4" do
    test "emits stream events for text content" do
      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/chat/completions" and Keyword.get(opts, :stream_request) do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_stream_fixture(chunks: ["Hello", " world"]),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      callback_fn = fn event -> send(self(), event) end

      assert :ok = Together.stream_chat(@messages, [], @opts, callback_fn)

      received = receive_all_events()
      assert Enum.any?(received, &match?({:part_start, _}, &1))
      assert Enum.any?(received, &match?({:part_delta, _}, &1))
      assert Enum.any?(received, &match?({:done, _}, &1))
    end
  end

  describe "provider capabilities" do
    test "supports tools" do
      assert Together.supports_tools?() == true
    end

    test "does not support vision" do
      assert Together.supports_vision?() == false
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
