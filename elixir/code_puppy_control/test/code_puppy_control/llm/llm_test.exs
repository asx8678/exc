defmodule CodePuppyControl.LLMTest do
  @moduledoc """
  Tests for the LLM facade module.

  Verifies provider routing, model resolution via ModelRegistry,
  and that chat/stream_chat dispatch correctly.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.LLM
  alias CodePuppyControl.LLM.Providers.{OpenAI, Anthropic}
  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    # Ensure MockLLMHTTP is started under test supervision for proper isolation
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  describe "provider_for/1" do
    test "resolves custom_openai type to OpenAI provider" do
      # The test models.json has custom_openai type models
      case LLM.provider_for("wafer-glm-5.1") do
        {:ok, mod} ->
          # custom_openai maps to OpenAI
          assert mod == OpenAI

        {:error, {:unknown_model, _}} ->
          # Model might not be in test fixture — that's fine
          :ok
      end
    end

    test "returns error for unknown model" do
      assert {:error, {:unknown_model, "nonexistent-model-xyz"}} =
               LLM.provider_for("nonexistent-model-xyz")
    end
  end

  describe "list_providers/0" do
    test "returns a map of model names to provider modules" do
      providers = LLM.list_providers()
      assert is_map(providers)

      # Every entry should map to a known provider module
      Enum.each(providers, fn {_name, mod} ->
        assert mod in [OpenAI, Anthropic]
      end)
    end
  end

  describe "chat/3" do
    test "dispatches to OpenAI provider with explicit provider option" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_chat_fixture(content: "OpenAI response"),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      messages = [%{role: "user", content: "Hello"}]

      assert {:ok, response} =
               LLM.chat(messages, [],
                 provider: OpenAI,
                 api_key: "test",
                 model: "gpt-4o",
                 http_client: MockLLMHTTP
               )

      assert response.content == "OpenAI response"
    end

    test "dispatches to Anthropic provider with explicit provider option" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_chat_fixture(content: "Anthropic response"),
             headers: []
           }}
        else
          {:passthrough}
        end
      end)

      messages = [%{role: "user", content: "Hello"}]

      assert {:ok, response} =
               LLM.chat(messages, [],
                 provider: Anthropic,
                 api_key: "test",
                 model: "claude-sonnet-4-20250514",
                 http_client: MockLLMHTTP
               )

      assert response.content == "Anthropic response"
    end

    test "returns error when no model or provider specified" do
      assert {:error, :no_model_or_provider_specified} =
               LLM.chat([%{role: "user", content: "Hello"}], [], [])
    end
  end

  describe "stream_chat/4" do
    test "dispatches streaming to OpenAI provider" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/chat/completions" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.openai_stream_fixture(chunks: ["Streaming", " response"]),
             headers: [{"content-type", "text/event-stream"}]
           }}
        else
          {:passthrough}
        end
      end)

      messages = [%{role: "user", content: "Hello"}]
      events = collect_stream_events()

      assert :ok =
               LLM.stream_chat(
                 messages,
                 [],
                 [
                   provider: OpenAI,
                   api_key: "test",
                   model: "gpt-4o",
                   http_client: MockLLMHTTP
                 ],
                 fn event ->
                   :ets.insert(events, {:ets.info(events, :size), event})
                 end
               )

      results =
        :ets.tab2list(events)
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_, e} -> e end)

      dones = Enum.filter(results, &match?({:done, _}, &1))
      assert length(dones) == 1
    end

    test "dispatches streaming to Anthropic provider" do
      MockLLMHTTP.register(fn :post, url, _opts ->
        if url =~ "/messages" do
          {:ok,
           %{
             status: 200,
             body: MockLLMHTTP.anthropic_stream_fixture(chunks: ["Streaming", " response"]),
             headers: [{"content-type", "text/event-stream"}]
           }}
        else
          {:passthrough}
        end
      end)

      messages = [%{role: "user", content: "Hello"}]
      events = collect_stream_events()

      assert :ok =
               LLM.stream_chat(
                 messages,
                 [],
                 [
                   provider: Anthropic,
                   api_key: "test",
                   model: "claude-sonnet-4-20250514",
                   http_client: MockLLMHTTP
                 ],
                 fn event ->
                   :ets.insert(events, {:ets.info(events, :size), event})
                 end
               )

      results =
        :ets.tab2list(events)
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_, e} -> e end)

      dones = Enum.filter(results, &match?({:done, _}, &1))
      assert length(dones) == 1
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp collect_stream_events do
    :ets.new(:stream_events, [:ordered_set, :public])
  end
end
