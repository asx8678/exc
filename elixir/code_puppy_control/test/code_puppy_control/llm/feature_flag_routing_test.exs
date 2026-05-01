defmodule CodePuppyControl.LLM.FeatureFlagRoutingTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.{FeatureFlags, LLM, RuntimeSelector}
  alias CodePuppyControl.ModelFactory.Handle

  @event [:code_puppy, :llm, :route_decision]

  setup do
    # Start from a deterministic state — always false.
    # Tests that need :llm_client enabled MUST set it explicitly in the test body.
    :ok = FeatureFlags.set(:llm_client, false, source: :test)

    test_pid = self()
    handler_id = "ff-route-test-#{System.unique_integer([:positive])}"

    # Ensure RuntimeSelector is running so select_runtime works in the gate.
    # Start it in :auto mode so FeatureFlags.set() still controls routing.
    # Also reset the mode to :auto in case another test left it in :python/:elixir.
    case Process.whereis(RuntimeSelector) do
      nil ->
        start_supervised!({RuntimeSelector, name: RuntimeSelector})

      pid ->
        GenServer.call(pid, {:set_mode, :auto})
    end

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      :ok = FeatureFlags.set(:llm_client, false, source: :test)

      # Reset RuntimeSelector mode so subsequent tests aren't affected
      if pid = Process.whereis(RuntimeSelector) do
        GenServer.call(pid, {:set_mode, :auto})
      end
    end)

    %{handler_id: handler_id}
  end

  describe "chat/3 (opts variant) flag gating" do
    test "ENABLED → emits path=:elixir and proceeds (mock provider)" do
      :ok = FeatureFlags.set(:llm_client, true, source: :test)

      result =
        LLM.chat([%{role: "user", content: "hi"}], [],
          provider: __MODULE__.MockProvider,
          model: "test-model"
        )

      assert {:ok, %{content: "ok"}} = result

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :elixir, model: "test-model", variant: :chat_opts}}

      refute_receive {:telemetry, @event, _, _}, 50
    end

    test "DISABLED → returns {:error, :elixir_llm_disabled}, never calls provider" do
      :ok = FeatureFlags.set(:llm_client, false, source: :test)

      result =
        LLM.chat([%{role: "user", content: "hi"}], [],
          provider: __MODULE__.ExplodingProvider,
          model: "test-model"
        )

      assert result == {:error, :elixir_llm_disabled}

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :python_fallback, model: "test-model", variant: :chat_opts}}

      refute_receive {:telemetry, @event, _, _}, 50
    end
  end

  describe "stream_chat/4 (opts variant) flag gating" do
    test "ENABLED → emits path=:elixir and proceeds" do
      :ok = FeatureFlags.set(:llm_client, true, source: :test)
      test_pid = self()

      result =
        LLM.stream_chat(
          [%{role: "user", content: "hi"}],
          [],
          [provider: __MODULE__.MockProvider, model: "test-model"],
          fn event -> send(test_pid, {:stream_event, event}) end
        )

      assert result == :ok
      assert_receive {:stream_event, {:done, %{content: "ok"}}}

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :elixir, model: "test-model", variant: :stream_chat_opts}}

      refute_receive {:telemetry, @event, _, _}, 50
    end

    test "DISABLED → returns {:error, :elixir_llm_disabled}, never calls provider" do
      :ok = FeatureFlags.set(:llm_client, false, source: :test)
      test_pid = self()

      result =
        LLM.stream_chat(
          [%{role: "user", content: "hi"}],
          [],
          [provider: __MODULE__.ExplodingProvider, model: "test-model"],
          fn event -> send(test_pid, {:stream_event, event}) end
        )

      assert result == {:error, :elixir_llm_disabled}
      refute_receive {:stream_event, _event}

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :python_fallback, model: "test-model", variant: :stream_chat_opts}}

      refute_receive {:telemetry, @event, _, _}, 50
    end
  end

  describe "gate ordering" do
    test "DISABLED chat opts arity short-circuits BEFORE provider resolution" do
      :ok = FeatureFlags.set(:llm_client, false, source: :test)

      assert LLM.chat([%{role: "user", content: "hi"}], [], []) ==
               {:error, :elixir_llm_disabled}

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :python_fallback, model: "", variant: :chat_opts}}

      refute_receive {:telemetry, @event, _, _}, 50
    end

    test "DISABLED stream_chat opts arity short-circuits BEFORE provider resolution" do
      :ok = FeatureFlags.set(:llm_client, false, source: :test)

      callback = fn event -> send(self(), {:stream_event, event}) end

      assert LLM.stream_chat([%{role: "user", content: "hi"}], [], [], callback) ==
               {:error, :elixir_llm_disabled}

      refute_receive {:stream_event, _event}

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :python_fallback, model: "", variant: :stream_chat_opts}}

      refute_receive {:telemetry, @event, _, _}, 50
    end
  end

  describe "handle variants" do
    test "chat/3 with %Handle{} respects flag" do
      :ok = FeatureFlags.set(:llm_client, true, source: :test)

      assert {:ok, %{content: "ok"}} =
               LLM.chat(
                 handle(__MODULE__.MockProvider, "h"),
                 [%{role: "user", content: "hi"}],
                 []
               )

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :elixir, model: "h", variant: :chat_handle}}

      refute_receive {:telemetry, @event, _, _}, 50

      :ok = FeatureFlags.set(:llm_client, false, source: :test)

      assert {:error, :elixir_llm_disabled} =
               LLM.chat(
                 handle(__MODULE__.ExplodingProvider, "h"),
                 [%{role: "user", content: "hi"}],
                 []
               )

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :python_fallback, model: "h", variant: :chat_handle}}

      refute_receive {:telemetry, @event, _, _}, 50
    end

    test "stream_chat/4 with %Handle{} respects flag" do
      :ok = FeatureFlags.set(:llm_client, true, source: :test)
      test_pid = self()

      assert :ok =
               LLM.stream_chat(
                 handle(__MODULE__.MockProvider, "h"),
                 [%{role: "user", content: "hi"}],
                 [],
                 fn event -> send(test_pid, {:stream_event, event}) end
               )

      assert_receive {:stream_event, {:done, %{content: "ok"}}}

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :elixir, model: "h", variant: :stream_chat_handle}}

      refute_receive {:telemetry, @event, _, _}, 50

      :ok = FeatureFlags.set(:llm_client, false, source: :test)

      assert {:error, :elixir_llm_disabled} =
               LLM.stream_chat(
                 handle(__MODULE__.ExplodingProvider, "h"),
                 [%{role: "user", content: "hi"}],
                 [],
                 fn event -> send(test_pid, {:stream_event, event}) end
               )

      refute_receive {:stream_event, _event}

      assert_receive {:telemetry, @event, %{count: 1},
                      %{path: :python_fallback, model: "h", variant: :stream_chat_handle}}

      refute_receive {:telemetry, @event, _, _}, 50
    end
  end

  defp handle(provider_module, model_name) do
    %Handle{
      model_name: model_name,
      provider_module: provider_module,
      provider_config: %{},
      model_opts: [model: model_name]
    }
  end

  # ── Mock providers ────────────────────────────────────────────────────────

  defmodule MockProvider do
    @behaviour CodePuppyControl.LLM.Provider

    @impl true
    def chat(_messages, _tools, _opts) do
      {:ok,
       %{
         id: "mock-test-id",
         model: "test-model",
         content: "ok",
         tool_calls: [],
         finish_reason: "stop",
         usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
       }}
    end

    @impl true
    def stream_chat(_messages, _tools, _opts, callback_fn) do
      callback_fn.(
        {:done,
         %{
           id: "mock-test-id",
           model: "test-model",
           content: "ok",
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
         }}
      )

      :ok
    end

    @impl true
    def supports_tools?, do: true

    @impl true
    def supports_vision?, do: false
  end

  defmodule ExplodingProvider do
    @behaviour CodePuppyControl.LLM.Provider

    @impl true
    def chat(_messages, _tools, _opts), do: raise("provider should not have been called")

    @impl true
    def stream_chat(_messages, _tools, _opts, _callback_fn),
      do: raise("provider should not have been called")

    @impl true
    def supports_tools?, do: true

    @impl true
    def supports_vision?, do: false
  end
end
