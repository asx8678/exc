defmodule CodePuppyControl.LLM.Providers.GroqTest do
  @moduledoc """
  Tests for the Groq provider implementation.

  Uses MockLLMHTTP to return fixture responses without hitting real APIs.
  Covers: non-streaming chat, SSE streaming, tool calls, error handling.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM.Providers.Groq
  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  @messages [%{role: "user", content: "Hello"}]
  @opts [api_key: "test-key", model: "llama-3.3-70b-versatile", http_client: MockLLMHTTP]

  describe "chat/3" do
    test "parses a successful response" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 200,
             body:
               MockLLMHTTP.openai_chat_fixture(
                 content: "Hi there!",
                 model: "llama-3.3-70b-versatile"
               ),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      assert {:ok, response} = Groq.chat(@messages, [], @opts)
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

      assert {:ok, response} = Groq.chat(@messages, [], @opts)
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

      assert {:error, %{status: 401}} = Groq.chat(@messages, [], @opts)
    end
  end

  describe "stream_chat/4" do
    test "emits stream events for text content" do
      MockLLMHTTP.register(fn :post, url, opts ->
        if url =~ "/chat/completions" and Keyword.get(opts, :stream_request) do
          {:ok,
           %{
             status: 200,
             body:
               MockLLMHTTP.openai_stream_fixture(
                 chunks: ["Hello", " world"],
                 model: "llama-3.3-70b-versatile"
               ),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      events = []
      callback_fn = fn event -> send(self(), event) end

      assert :ok = Groq.stream_chat(@messages, [], @opts, callback_fn)

      # Should receive part_start, part_deltas, part_end, and done
      received = receive_all_events()
      assert Enum.any?(received, &match?({:part_start, _}, &1))
      assert Enum.any?(received, &match?({:part_delta, _}, &1))
      assert Enum.any?(received, &match?({:part_end, _}, &1))
      assert Enum.any?(received, &match?({:done, _}, &1))
    end
  end

  describe "provider capabilities" do
    test "supports tools" do
      assert Groq.supports_tools?() == true
    end

    test "does not support vision" do
      assert Groq.supports_vision?() == false
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
