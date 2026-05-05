defmodule CodePuppyControl.NativeParitySmokeTest do
  @moduledoc """
  Native agent→tool→model-provider parity smoke test (code-puppy-hwv).

  Exercises the full native Elixir runtime workflow with zero Python involvement:

    1. RuntimeSelector routes all capabilities to `:elixir` in default mode
    2. Agent.Loop completes turns via a fake LLM provider (no network / no API keys)
    3. Tool.Runner dispatches a registered tool through the Tool.Registry path
    4. PythonWorker.Supervisor has zero active children throughout

  This test is NOT tagged `:integration` — it uses in-process mocks and runs
  in the default fast suite.  CI may also run it as a named gate:

      mix test test/code_puppy_control/native_parity_smoke_test.exs

  Refs: code-puppy-hwv, code-puppy-v2o, code-puppy-db8 §6.6.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop
  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.PythonWorker.Supervisor, as: PythonWorkerSup
  alias CodePuppyControl.RuntimeSelector
  alias CodePuppyControl.Tool.Registry
  alias CodePuppyControl.Tool.Runner

  # ── Test Agent ──────────────────────────────────────────────────────────

  defmodule NativeSmokeAgent do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :native_smoke_agent

    @impl true
    def system_prompt(_ctx), do: "You are a native parity smoke agent."

    @impl true
    def allowed_tools, do: [:native_smoke_tool]

    @impl true
    def model_preference, do: "smoke-test-model"

    @impl true
    def on_tool_result(_name, _result, state), do: {:cont, state}
  end

  # ── Test Tool ───────────────────────────────────────────────────────────

  defmodule NativeSmokeTool do
    @moduledoc false
    use CodePuppyControl.Tool

    @invoked_key {__MODULE__, :invoked}

    @impl true
    def name, do: :native_smoke_tool

    @impl true
    def description, do: "Deterministic tool for native parity smoke"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "value" => %{"type" => "string", "description" => "Value to echo"}
        },
        "required" => ["value"]
      }
    end

    @impl true
    def invoke(args, _context) do
      :persistent_term.put(@invoked_key, true)
      {:ok, %{"echo" => args["value"]}}
    end

    @doc false
    def invoked?, do: :persistent_term.get(@invoked_key, false)

    @doc false
    def reset_invoked do
      :persistent_term.erase(@invoked_key)
      :ok
    end
  end

  # ── Fake LLM: text-only response ──────────────────────────────────────

  defmodule FakeTextLLM do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.LLM

    @impl true
    def stream_chat(_messages, _tools, _opts, callback_fn) do
      callback_fn.({:text, "Hello from native runtime!"})
      callback_fn.({:done, :complete})
      {:ok, %{text: "Hello from native runtime!", tool_calls: []}}
    end
  end

  # ── Fake LLM: tool-call then text response ────────────────────────────

  defmodule FakeToolCallLLM do
    @moduledoc false
    @behaviour CodePuppyControl.Agent.LLM

    @impl true
    def stream_chat(messages, _tools, _opts, callback_fn) do
      if Enum.any?(messages, fn m -> m[:role] == "tool" or m["role"] == "tool" end) do
        # After tool result: respond with text
        callback_fn.({:text, "Tool executed natively!"})
        callback_fn.({:done, :complete})
        {:ok, %{text: "Tool executed natively!", tool_calls: []}}
      else
        # First turn: request a tool call
        callback_fn.({:tool_call, :native_smoke_tool, %{"value" => "parity"}, "tc-smoke-1"})
        callback_fn.({:done, :complete})

        {:ok,
         %{
           text: nil,
           tool_calls: [
             %{id: "tc-smoke-1", name: :native_smoke_tool, arguments: %{"value" => "parity"}}
           ]
         }}
      end
    end
  end

  # ── Setup ───────────────────────────────────────────────────────────────

  setup do
    # Ensure Tool.Registry is alive
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(Registry)

    # Ensure PubSub for EventBus
    CodePuppyControl.TestSupport.Reset.ensure_pubsub_started()

    # Ensure Callbacks.Registry is alive
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Callbacks.Registry
    )

    # Clear state to prevent test pollution
    Registry.clear()
    Callbacks.clear()
    NativeSmokeTool.reset_invoked()

    # Register our smoke tool
    :ok = Registry.register(NativeSmokeTool)

    on_exit(fn ->
      Registry.clear()
      Callbacks.clear()
      NativeSmokeTool.reset_invoked()
    end)

    :ok
  end

  # ── RuntimeSelector parity ─────────────────────────────────────────────

  describe "native runtime selector parity" do
    test "default/auto mode routes to :elixir for core capabilities" do
      saved = System.get_env("PUP_RUNTIME")

      try do
        System.delete_env("PUP_RUNTIME")

        # Default (unset) → :auto
        assert RuntimeSelector.mode() == :auto

        # Core capabilities must route to :elixir, never :python
        for cap <- ["agent", "tool", "model_provider", "parse", "file_ops"] do
          assert RuntimeSelector.select(cap) == :elixir,
                 "Expected :elixir for #{inspect(cap)}, got #{inspect(RuntimeSelector.select(cap))}"
        end
      after
        restore_env("PUP_RUNTIME", saved)
      end
    end

    test "PUP_RUNTIME=elixir forces :elixir for all capabilities" do
      saved = System.get_env("PUP_RUNTIME")

      try do
        System.put_env("PUP_RUNTIME", "elixir")

        assert RuntimeSelector.mode() == :elixir
        assert RuntimeSelector.select("agent") == :elixir
        assert RuntimeSelector.select("tool") == :elixir
        assert RuntimeSelector.select("model_provider") == :elixir
      after
        restore_env("PUP_RUNTIME", saved)
      end
    end
  end

  # ── PythonWorker.Supervisor zero-children guarantee ────────────────────

  describe "PythonWorker.Supervisor has zero workers in native mode" do
    test "worker_count is zero" do
      assert PythonWorkerSup.worker_count() == 0,
             "PythonWorker.Supervisor should have zero workers in native Elixir runtime"
    end

    test "list_workers is empty" do
      assert PythonWorkerSup.list_workers() == [],
             "PythonWorker.Supervisor should list zero workers in native Elixir runtime"
    end
  end

  # ── Agent → fake LLM path (text-only) ──────────────────────────────────

  describe "native agent→LLM path (text-only turn)" do
    test "agent loop completes a text-only turn via fake provider" do
      {:ok, pid} =
        Loop.start_link(NativeSmokeAgent, [],
          llm_module: FakeTextLLM,
          run_id: "native-smoke-text-1"
        )

      assert :ok = Loop.run_turn(pid)

      state = Loop.get_state(pid)
      assert state.turn_number == 1
      assert state.completed == true

      GenServer.stop(pid)
    end
  end

  # ── Agent → tool → result path ─────────────────────────────────────────

  describe "native agent→tool→result path" do
    test "agent loop dispatches tool via Tool.Runner and receives result" do
      {:ok, pid} =
        Loop.start_link(
          NativeSmokeAgent,
          [%{role: "user", content: "Run the smoke tool"}],
          llm_module: FakeToolCallLLM,
          run_id: "native-smoke-tool-1"
        )

      assert :ok = Loop.run_until_done(pid, 10_000)

      state = Loop.get_state(pid)
      # Two turns: (1) tool call + (2) text response
      assert state.turn_number == 2
      assert state.completed == true

      # Tool was actually invoked through the registered path
      # (proves Tool.Runner → Registry → NativeSmokeTool.invoke/2)
      assert NativeSmokeTool.invoked?(),
             "NativeSmokeTool should have been invoked through Tool.Runner → Registry path"

      # Loop completed a full tool-call cycle: 2 turns (tool dispatch + text reply)
      state_view = Loop.get_state(pid)

      assert state_view.turn_number == 2,
             "Expected 2 turns (tool + text), got #{state_view.turn_number}"

      assert state_view.completed == true,
             "Expected loop completed, got completed=#{state_view.completed}"

      # Final messages include at least user + assistant response
      messages = Loop.get_messages(pid)

      assert length(messages) >= 2,
             "Expected >=2 messages, got #{length(messages)}"

      GenServer.stop(pid)
    end
  end

  # ── Tool.Runner direct dispatch parity ─────────────────────────────────

  describe "native Tool.Runner dispatch parity" do
    test "Runner.invoke dispatches registered tool via Tool.Registry" do
      context = Runner.build_context(run_id: "native-smoke-runner-1")

      assert {:ok, %{"echo" => "parity"}} =
               Runner.invoke(:native_smoke_tool, %{"value" => "parity"}, context)
    end

    test "Runner.invoke returns error for unregistered tool" do
      context = Runner.build_context(run_id: "native-smoke-runner-2")

      assert {:error, msg} = Runner.invoke(:nonexistent_tool_xyzzy, %{}, context)
      assert is_binary(msg)
      assert msg =~ "not found"
    end
  end

  # ── Full native parity: no PythonWorker children after agent run ───────

  describe "full native parity: no PythonWorker children after agent→tool cycle" do
    test "after agent→tool→LLM cycle, PythonWorker still at zero" do
      # Verify clean slate
      assert PythonWorkerSup.worker_count() == 0

      {:ok, pid} =
        Loop.start_link(
          NativeSmokeAgent,
          [%{role: "user", content: "Run the smoke tool"}],
          llm_module: FakeToolCallLLM,
          run_id: "native-smoke-zero-workers"
        )

      :ok = Loop.run_until_done(pid, 10_000)

      GenServer.stop(pid)

      # Assert: no PythonWorker children were started during the full cycle
      assert PythonWorkerSup.worker_count() == 0,
             "PythonWorker.Supervisor should have zero workers after native agent→tool cycle"

      assert PythonWorkerSup.list_workers() == [],
             "PythonWorker.Supervisor list should be empty after native agent→tool cycle"
    end
  end

  # ── Model provider seam ────────────────────────────────────────────────

  describe "model provider fake seam" do
    test "fake LLM provider returns deterministic response without network" do
      # Directly call the fake LLM to prove the seam works
      {:ok, response} = FakeTextLLM.stream_chat([], [], [], fn _event -> :ok end)
      assert response.text == "Hello from native runtime!"
      assert response.tool_calls == []
    end

    test "fake tool-call LLM produces correct two-turn protocol" do
      # Turn 1: tool call
      {:ok, r1} = FakeToolCallLLM.stream_chat([], [], [], fn _event -> :ok end)
      assert r1.text == nil
      assert length(r1.tool_calls) == 1
      [tc] = r1.tool_calls
      assert tc.name == :native_smoke_tool
      assert tc.arguments == %{"value" => "parity"}

      # Turn 2: text response (simulates after tool result message)
      messages_with_tool = [%{role: "tool", content: "echo: parity"}]

      {:ok, r2} = FakeToolCallLLM.stream_chat(messages_with_tool, [], [], fn _event -> :ok end)
      assert r2.text == "Tool executed natively!"
      assert r2.tool_calls == []
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, val), do: System.put_env(var, val)
end
