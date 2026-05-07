defmodule CodePuppyControl.Test.OutboundBodyHelpers do
  @moduledoc """
  Shared helpers for outbound request body tests.

  Provides MockLLMHTTP capture helpers and common fixtures used across
  the outbound body test files for all LLM providers.
  """

  alias CodePuppyControl.Test.MockLLMHTTP

  def setup_mock, do: ExUnit.Callbacks.start_supervised!(MockLLMHTTP)

  def capture_body(test_pid, url_pattern, fixture_fn) do
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

  def capture_body_stream(test_pid, url_pattern, stream_fixture) do
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

  def ok_anthropic_fixture,
    do: {:ok, %{status: 200, body: MockLLMHTTP.anthropic_chat_fixture(), headers: []}}

  def ok_openai_fixture,
    do: {:ok, %{status: 200, body: MockLLMHTTP.openai_chat_fixture(), headers: []}}

  def ok_google_fixture,
    do: {:ok, %{status: 200, body: MockLLMHTTP.google_chat_fixture(), headers: []}}

  @doc "Sample tool definition used across provider body tests."
  def sample_tool do
    %{
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
  end

  @doc "Sample tool with string keys (for string-keyed input parity tests)."
  def sample_tool_string do
    %{
      "type" => "function",
      "function" => %{
        "name" => "read_file",
        "description" => "Read a file from disk",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        }
      }
    }
  end

  @doc "Default stream fixture for ChatGPT Codex tests."
  def codex_stream_fixture, do: MockLLMHTTP.chatgpt_codex_stream_fixture()
end
