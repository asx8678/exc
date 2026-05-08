defmodule CodePuppyControl.Test.LLMAdapterTestHelper do
  @moduledoc """
  Shared test infrastructure for LLMAdapter tests.

  Provides:
  - `ProviderMock` — configurable mock for the LLM provider layer
  - `StubTool` — minimal tool module for Registry lookup tests
  - `setup_mock_provider/0` — setup helper that swaps in ProviderMock and cleans up
  """

  # ---------------------------------------------------------------------------
  # Mock provider — CodePuppyControl.LLM contract (atom keys, schema-map
  # tools, raw events, returns :ok)
  # ---------------------------------------------------------------------------

  defmodule ProviderMock do
    @moduledoc "Configurable mock for the LLM provider layer."

    def start_if_needed do
      case Process.whereis(__MODULE__) do
        nil ->
          {:ok, _pid} = Elixir.Agent.start_link(fn -> %{} end, name: __MODULE__)

        _ ->
          :ok
      end
    end

    def set_response(response) do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :response, response))
    end

    def set_silent_ok do
      # Provider returns :ok but never fires {:done, response} — exercises adapter timeout
      start_if_needed()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :silent_ok, true))
    end

    def set_error(reason) do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :error, reason))
    end

    def captured_messages do
      start_if_needed()
      Elixir.Agent.get(__MODULE__, & &1)[:messages] || []
    end

    def captured_tools do
      start_if_needed()
      Elixir.Agent.get(__MODULE__, & &1)[:tools] || []
    end

    def reset do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, fn _ -> %{} end)
    end

    def stop do
      try do
        Elixir.Agent.stop(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end

    # Provider contract: atom-keyed msgs, schema-map tools, raw events, :ok return
    @doc false
    def stream_chat(messages, tools, _opts, callback_fn) do
      start_if_needed()
      Elixir.Agent.update(__MODULE__, &Map.merge(&1, %{messages: messages, tools: tools}))

      state = Elixir.Agent.get(__MODULE__, & &1)

      cond do
        state[:error] ->
          {:error, state[:error]}

        state[:silent_ok] ->
          # Returns :ok without ever firing {:done, response} — exercises adapter timeout
          :ok

        state[:response] ->
          resp = state[:response]

          # Fire text streaming events if content present
          if resp[:content] do
            callback_fn.({:part_start, %{type: :text, index: 0, id: nil}})

            callback_fn.(
              {:part_delta,
               %{type: :text, index: 0, text: resp.content, name: nil, arguments: nil}}
            )

            callback_fn.({:part_end, %{type: :text, index: 0, id: nil}})
          end

          # Fire tool call events if present
          if resp[:tool_calls] do
            for tc <- resp[:tool_calls] do
              callback_fn.({:part_start, %{type: :tool_call, index: 1, id: tc[:id]}})

              callback_fn.(
                {:part_delta,
                 %{
                   type: :tool_call,
                   index: 1,
                   text: nil,
                   name: tc[:name],
                   arguments: tc[:arguments]
                 }}
              )

              callback_fn.({:part_end, %{type: :tool_call, index: 1, id: tc[:id]}})
            end
          end

          # Fire terminal {:done, response} event — this is what LLMAdapter intercepts
          callback_fn.({:done, resp})
          :ok

        true ->
          # Default: minimal text response
          callback_fn.(
            {:done,
             %{
               id: "r1",
               model: "test",
               content: "ok",
               tool_calls: [],
               finish_reason: "stop",
               usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
             }}
          )

          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Stub tool for Registry-based tool resolution tests
  # ---------------------------------------------------------------------------

  defmodule StubTool do
    @moduledoc "Minimal tool module for Registry lookup tests."
    use CodePuppyControl.Tool

    @impl true
    def name, do: :stub_tool

    @impl true
    def description, do: "A stub tool for testing"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "A query string"}
        },
        "required" => ["query"]
      }
    end

    @impl true
    def invoke(_args, _context), do: {:ok, "stubbed"}
  end

  # ---------------------------------------------------------------------------
  # Setup helper
  # ---------------------------------------------------------------------------

  @doc """
  Swaps in ProviderMock as the LLM adapter provider and resets its state.

  Restores the original provider config on test exit.
  Must be called from within an ExUnit test process (setup block).
  """
  def setup_mock_provider do
    prev = Application.get_env(:code_puppy_control, :llm_adapter_provider)
    Application.put_env(:code_puppy_control, :llm_adapter_provider, ProviderMock)
    ProviderMock.reset()

    ExUnit.Callbacks.on_exit(fn ->
      if prev do
        Application.put_env(:code_puppy_control, :llm_adapter_provider, prev)
      else
        Application.delete_env(:code_puppy_control, :llm_adapter_provider)
      end

      ProviderMock.stop()
    end)

    :ok
  end
end
