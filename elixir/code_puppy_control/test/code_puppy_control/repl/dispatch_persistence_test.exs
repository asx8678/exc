defmodule CodePuppyControl.REPL.DispatchPersistenceTest do
  @moduledoc """
  Regression tests for: compaction-safe persistence after send_to_agent.

  The old code used `Enum.drop(final_messages, pre_count)` to extract new
  messages from the Agent.Loop, which assumes final_messages is prefix-aligned
  with the pre-run history. When Agent.Loop compacts or rewrites history,
  the prefix can change and Enum.drop silently drops replies.

  The fix replaces the Enum.drop + append_message loop with
  State.set_messages(..., normalized_final_messages), which is compaction-safe
  because it sets the authoritative state from the loop regardless of
  prefix alignment.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.REPL.Loop
  alias CodePuppyControl.Tools.AgentCatalogue

  # ---------------------------------------------------------------------------
  # Mock LLM — separate module to avoid BEAM name collisions with sibling
  # test files' mocks.
  # ---------------------------------------------------------------------------

  defmodule DispatchPersistenceMockLLM do
    @moduledoc """
    Mock LLM for dispatch persistence dispatch persistence tests.

    Implements `CodePuppyControl.Agent.LLM` behaviour with controllable
    responses via an Elixir Agent process.
    """
    @behaviour CodePuppyControl.Agent.LLM

    def ensure_started do
      case Elixir.Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def set_response(response) when is_map(response) do
      ensure_started()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :response, response))
    end

    def reset do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        _ -> Elixir.Agent.update(__MODULE__, fn _ -> %{} end)
      end
    end

    def stop do
      try do
        Elixir.Agent.stop(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end

    @impl true
    def stream_chat(_messages, _tools, _opts, callback_fn) do
      ensure_started()

      state = Elixir.Agent.get(__MODULE__, & &1)

      if resp = state[:response] do
        if resp[:text] do
          callback_fn.({:text, resp.text})
        end

        callback_fn.({:done, :complete})
        {:ok, resp}
      else
        {:error, :no_mock_configured}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shared setup
  # ---------------------------------------------------------------------------

  defp setup_mock_llm_and_session(_context) do
    # (code_puppy-i1n) Ensure Agent.State.Supervisor is alive —
    # Loop.handle_input calls ensure_agent_state_for which needs
    # the DynamicSupervisor to start child processes.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Agent.State.Supervisor
    )

    session_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    prev_llm = Application.get_env(:code_puppy_control, :repl_llm_module)
    Application.put_env(:code_puppy_control, :repl_llm_module, DispatchPersistenceMockLLM)
    DispatchPersistenceMockLLM.reset()

    try do
      AgentCatalogue.discover_agent_modules()
    catch
      _, _ -> :ok
    end

    ExUnit.Callbacks.on_exit(fn ->
      if prev_llm do
        Application.put_env(:code_puppy_control, :repl_llm_module, prev_llm)
      else
        Application.delete_env(:code_puppy_control, :repl_llm_module)
      end

      Application.delete_env(:code_puppy_control, :test_compaction_opts)

      DispatchPersistenceMockLLM.stop()

      try do
        State.clear_messages(session_id, "code_puppy")
      catch
        _, _ -> :ok
      end

      case Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id) do
        [] ->
          :ok

        [{pid, _}] ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, 1_000)
            catch
              :exit, _ -> :ok
            end
          end
      end
    end)

    state = %Loop{
      session_id: session_id,
      agent: "code_puppy",
      model: "claude-sonnet-4-20250514",
      running: true
    }

    {:ok, state: state, session_id: session_id}
  end

  # ===========================================================================
  # Success-path persistence via set_messages (dispatch persistence)
  # ===========================================================================

  describe "dispatch_after_append — compaction-safe persistence (dispatch persistence)" do
    setup :setup_mock_llm_and_session

    test "assistant reply persisted after successful dispatch", %{
      state: state,
      session_id: session_id
    } do
      DispatchPersistenceMockLLM.set_response(%{
        text: "I am a helpful assistant!",
        tool_calls: []
      })

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("Hello", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")

      # Both the user message and the assistant reply should be persisted
      assert length(messages) == 2

      assert [
               %{"role" => "user", "parts" => [%{"type" => "text", "text" => "Hello"}]},
               %{
                 "role" => "assistant",
                 "parts" => [%{"type" => "text", "text" => "I am a helpful assistant!"}]
               }
             ] = messages
    end

    test "multi-turn with existing messages preserves full history", %{
      state: state,
      session_id: session_id
    } do
      # Pre-populate with existing conversation
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "first question"}]
      })

      State.append_message(session_id, "code_puppy", %{
        "role" => "assistant",
        "parts" => [%{"type" => "text", "text" => "first answer"}]
      })

      assert length(State.get_messages(session_id, "code_puppy")) == 2

      DispatchPersistenceMockLLM.set_response(%{text: "second answer", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("second question", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 4

      roles = Enum.map(messages, &Map.get(&1, "role"))
      assert roles == ["user", "assistant", "user", "assistant"]

      texts =
        Enum.map(messages, fn msg ->
          msg |> Map.get("parts") |> hd() |> Map.get("text")
        end)

      assert texts == ["first question", "first answer", "second question", "second answer"]
    end

    test "dispatch with compaction opts enabled still persists assistant reply", %{
      state: state,
      session_id: session_id
    } do
      # Set a very low compaction trigger so the loop's compaction logic
      # is exercised. With simple text messages, compaction may not
      # actually drop messages (the split algorithm's min_keep*100 floor
      # protects tiny messages), but this test ensures the set_messages
      # code path works correctly when compaction opts are present.
      Application.put_env(
        :code_puppy_control,
        :test_compaction_opts,
        trigger_messages: 3,
        min_keep: 2
      )

      # Pre-populate enough messages to exceed the low trigger threshold
      for i <- 1..5 do
        State.append_message(session_id, "code_puppy", %{
          "role" => "user",
          "parts" => [%{"type" => "text", "text" => "prior message #{i}"}]
        })
      end

      assert length(State.get_messages(session_id, "code_puppy")) == 5

      DispatchPersistenceMockLLM.set_response(%{text: "compaction-safe reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("trigger compaction", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")

      # The assistant reply MUST be present regardless of compaction
      assistant_texts =
        messages
        |> Enum.filter(&(&1["role"] == "assistant"))
        |> Enum.map(fn msg ->
          msg |> Map.get("parts") |> hd() |> Map.get("text")
        end)

      assert "compaction-safe reply" in assistant_texts,
             "Assistant reply must survive compaction. Got messages: #{inspect(messages)}"
    end

    test "actual compaction shrinks history and set_messages preserves result", %{
      state: state,
      session_id: session_id
    } do
      # WATCHDOG REGRESSION TEST (dispatch persistence critic feedback):
      # This test forces ACTUAL compaction that shrinks the message count,
      # proving that the old Enum.drop(final_messages, pre_count) logic
      # would silently return [] and drop the assistant reply.
      #
      # The key scenario: pre_count (messages before the loop ran) exceeds
      # the length of final_messages (after compaction). With the old code:
      #   Enum.drop([a, b, c], 10) => []  ← ALL replies lost!
      # With the new State.set_messages fix, the compacted output is
      # persisted atomically regardless of prefix alignment.

      # Use part_kind/content format so the token estimator assigns
      # realistic token counts — without this, each message gets ~1 token
      # and the split algorithm's min_keep*100 floor protects everything.
      long_content =
        String.duplicate(
          "This is a substantial message with enough text for token estimation. ",
          20
        )

      # Pre-populate 30 messages — well above any reasonable trigger
      for i <- 1..30 do
        State.append_message(session_id, "code_puppy", %{
          "role" => "user",
          "parts" => [
            %{
              "part_kind" => "text",
              "content" => "Message #{i}: #{long_content}"
            }
          ]
        })
      end

      pre_count = length(State.get_messages(session_id, "code_puppy"))
      assert pre_count == 30

      # Aggressive compaction: trigger at 5 messages, keep only 2
      Application.put_env(
        :code_puppy_control,
        :test_compaction_opts,
        trigger_messages: 5,
        min_keep: 2,
        keep_fraction: 0.05
      )

      DispatchPersistenceMockLLM.set_response(%{text: "post-compaction reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("new question", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      final_count = length(messages)

      # COMPACTION MUST ACTUALLY FIRE: final_count < pre_count + 2
      # (pre_count + 2 = 32 = 30 original + 1 user + 1 assistant without
      # compaction). If compaction ran, we should see significantly fewer.
      assert final_count < pre_count + 2,
             "Compaction did not shrink history: got #{final_count} messages, " <>
               "expected < #{pre_count + 2}. Compaction opts may not be working."

      # PROOF: the old Enum.drop logic would fail here.
      # If pre_count was 31 (30 + 1 new user msg) and final_count is < 31,
      # then Enum.drop(final_messages, pre_count) would return [].
      # Simulate the old logic to demonstrate the bug:
      simulated_drop = Enum.drop(messages, pre_count)

      assert simulated_drop == [],
             "Old Enum.drop logic should return [] when final_count < pre_count, " <>
               "but got: #{inspect(simulated_drop)}. This means the test " <>
               "setup doesn't trigger the bug scenario."

      # The assistant reply MUST be present — proving set_messages works
      # even when Enum.drop would have returned [].
      assistant_texts =
        messages
        |> Enum.filter(&(&1["role"] == "assistant"))
        |> Enum.map(fn msg ->
          msg
          |> Map.get("parts")
          |> Enum.find(&Map.has_key?(&1, "text"))
          |> Map.get("text")
        end)

      assert "post-compaction reply" in assistant_texts,
             "Assistant reply must survive actual compaction. " <>
               "Got #{final_count} messages (down from #{pre_count} pre-loop). " <>
               "Messages: #{inspect(messages)}"
    end

    test "set_messages replaces state atomically, not incrementally", %{
      session_id: session_id
    } do
      # This is the core property that makes the fix compaction-safe:
      # State.set_messages replaces the entire message list, so even if
      # the loop returns a completely different set of messages (due to
      # compaction), the state is set correctly.
      #
      # The old Enum.drop + append_message approach would fail here:
      # if final_messages had fewer entries than pre_count, Enum.drop
      # would return [] and silently drop all new replies.

      # Set up initial state with some messages
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "old question"}]
      })

      State.append_message(session_id, "code_puppy", %{
        "role" => "assistant",
        "parts" => [%{"type" => "text", "text" => "old answer"}]
      })

      assert length(State.get_messages(session_id, "code_puppy")) == 2

      # Simulate what set_messages does after compaction:
      # the loop returns a DIFFERENT set of messages (e.g., a compacted
      # summary replacing the old history, plus a new assistant reply)
      State.set_messages(session_id, "code_puppy", [
        %{"role" => "user", "parts" => [%{"type" => "text", "text" => "compacted summary"}]},
        %{"role" => "user", "parts" => [%{"type" => "text", "text" => "new question"}]},
        %{"role" => "assistant", "parts" => [%{"type" => "text", "text" => "new answer"}]}
      ])

      messages = State.get_messages(session_id, "code_puppy")

      # State should be EXACTLY what set_messages was called with,
      # not a merge of old + new
      assert length(messages) == 3

      texts =
        Enum.map(messages, fn msg ->
          msg |> Map.get("parts") |> hd() |> Map.get("text")
        end)

      assert texts == ["compacted summary", "new question", "new answer"]

      # The old messages should be GONE — set_messages replaces, not appends
      refute Enum.any?(texts, &(&1 == "old question"))
      refute Enum.any?(texts, &(&1 == "old answer"))
    end

    test "rollback on error still restores messages_before", %{
      state: state,
      session_id: session_id
    } do
      # Verify that the dispatch rollback rollback semantics are preserved:
      # on error, messages_before should be restored even though
      # the success path now uses set_messages.

      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "pre-existing message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      DispatchPersistenceMockLLM.set_response(%{text: "should not persist", tool_calls: []})

      # Inject a success-path fault to trigger rollback
      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        "dispatch persistence rollback test"
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("will be rolled back", state)
      end)

      # After rollback, only the pre-existing message should remain
      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 1
      assert hd(messages)["parts"] |> hd() |> Map.get("text") == "pre-existing message"
    after
      Application.delete_env(:code_puppy_control, :test_dispatch_success_fault)
    end
  end
end
