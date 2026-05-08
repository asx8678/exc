defmodule CodePuppyControl.LLM.Providers.AzureTest do
  @moduledoc """
  Tests for the Azure OpenAI provider implementation.

  Uses MockLLMHTTP to return fixture responses without hitting real APIs.
  Covers: non-streaming chat, SSE streaming, URL construction, error handling.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.Azure
  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  @messages [%{role: "user", content: "Hello"}]
  @opts [
    api_key: "test-key",
    base_url: "https://myresource.openai.azure.com",
    deployment: "gpt-4o-deployment",
    http_client: MockLLMHTTP
  ]

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

      assert {:ok, response} = Azure.chat(@messages, [], @opts)
      assert response.content == "Hi there!"
      assert response.finish_reason == "stop"
      assert response.tool_calls == []
    end

    test "constructs correct Azure URL with deployment and api-version" do
      captured_url = :atom

      MockLLMHTTP.register(fn :post, url, _opts ->
        captured_url = url
        send(self(), {:captured_url, captured_url})

        {:ok,
         %{
           status: 200,
           body: MockLLMHTTP.openai_chat_fixture(),
           headers: []
         }}
      end)

      Azure.chat(@messages, [], @opts)

      assert_received {:captured_url, url}
      assert url =~ "/openai/deployments/gpt-4o-deployment/chat/completions"
      assert url =~ "api-version="
    end

    test "handles HTTP error status" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 401,
             body:
               Jason.encode!(%{
                 "error" => %{"message" => "Access denied", "type" => "auth_error"}
               }),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:error, %{status: 401}} = Azure.chat(@messages, [], @opts)
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

      assert :ok = Azure.stream_chat(@messages, [], @opts, callback_fn)

      received = receive_all_events()
      assert Enum.any?(received, &match?({:part_start, _}, &1))
      assert Enum.any?(received, &match?({:part_delta, _}, &1))
      assert Enum.any?(received, &match?({:done, _}, &1))
    end
  end

  describe "provider capabilities" do
    test "supports tools" do
      assert Azure.supports_tools?() == true
    end

    test "supports vision" do
      assert Azure.supports_vision?() == true
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
