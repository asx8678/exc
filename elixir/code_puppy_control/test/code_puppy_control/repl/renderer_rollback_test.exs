defmodule CodePuppyControl.REPL.RendererRollbackTest do
  @moduledoc """
  Renderer crash recovery and user-message rollback regression tests.

  These tests verify that ensure_renderer/1 and test cleanup are safe
  when a registered renderer process dies between Registry.lookup and
  the subsequent GenServer call (reset/stop).

  Also covers the rollback fix: ensure_renderer failure and
  run_until_done error both roll back the appended user message.

  Extracted from loop_test.exs (Watchdog QA).
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.REPL.Loop
  alias CodePuppyControl.Tools.AgentCatalogue

  # ---------------------------------------------------------------------------
  # Mock LLM (duplicated from send_to_agent_test.exs to keep this file
  # self-contained — these are nested modules under different parents, so
  # they don't collide in the BEAM global registry.)
  # ---------------------------------------------------------------------------

  defmodule RollbackTestMockLLM do
    @moduledoc """
    Mock LLM module for renderer/rollback regression tests.

    Implements `CodePuppyControl.Agent.LLM` behaviour with controllable
    responses and error injection via an Elixir Agent process.
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

    def set_error(reason) do
      ensure_started()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :error, reason))
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
    def stream_chat(_messages, _tools, opts, callback_fn) do
      ensure_started()

      Elixir.Agent.update(__MODULE__, &Map.put(&1, :last_opts, opts))

      state = Elixir.Agent.get(__MODULE__, & &1)

      cond do
        state[:error] ->
          {:error, state[:error]}

        state[:response] ->
          resp = state[:response]

          if resp[:text] do
            callback_fn.({:text, resp.text})
          end

          if resp[:tool_calls] do
            for tc <- resp[:tool_calls] do
              callback_fn.({:tool_call, tc.name, tc.arguments, tc.id})
            end
          end

          callback_fn.({:done, :complete})
          {:ok, resp}

        true ->
          {:error, :no_mock_configured}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shared setup for renderer crash recovery describe blocks
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
    Application.put_env(:code_puppy_control, :repl_llm_module, RollbackTestMockLLM)
    RollbackTestMockLLM.reset()

    try do
      AgentCatalogue.discover_agent_modules()
    catch
      _, _ -> :ok
    end

    on_exit(fn ->
      if prev_llm do
        Application.put_env(:code_puppy_control, :repl_llm_module, prev_llm)
      else
        Application.delete_env(:code_puppy_control, :repl_llm_module)
      end

      RollbackTestMockLLM.stop()

      try do
        State.clear_messages(session_id, "code_puppy")
      catch
        _, _ -> :ok
      end

      # Safe renderer cleanup (same pattern as other describe blocks)
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
  # Renderer crash recovery regression tests (Watchdog QA)
  # ===========================================================================

  describe "send_to_agent/2 via handle_input/2 — renderer crash recovery" do
    setup :setup_mock_llm_and_session

    test "recovers when renderer dies before reuse", %{state: state, session_id: session_id} do
      # First call: starts a renderer normally
      RollbackTestMockLLM.set_response(%{text: "first reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("Hello", state)
      end)

      # The renderer should now be registered
      [{renderer_pid, _}] = Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id)
      assert Process.alive?(renderer_pid)

      # Kill the renderer to simulate a crash (e.g., IO device terminated).
      # Unlink first so the exit doesn't propagate to the test process.
      Process.unlink(renderer_pid)
      Process.exit(renderer_pid, :kill)

      # Wait for the registry to notice the exit
      Process.sleep(50)

      # Second call: ensure_renderer should recover by spawning a new renderer
      RollbackTestMockLLM.set_response(%{text: "second reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("Hello again", state)
      end)

      # A new renderer should be registered for this session
      case Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id) do
        [] ->
          # Registry may have been cleaned up already — the important
          # thing is the call didn't crash.
          :ok

        [{new_pid, _}] ->
          # New renderer should be a different pid
          refute new_pid == renderer_pid
          assert Process.alive?(new_pid)
      end

      # Messages should still be persisted despite the renderer crash
      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 4
    end

    test "cleanup is safe when renderer dies before on_exit", %{session_id: session_id} do
      # Start a renderer for this session
      {:ok, pid} =
        CodePuppyControl.TUI.Renderer.start_link(
          name: {:via, Registry, {CodePuppyControl.REPL.RendererRegistry, session_id}},
          session_id: session_id
        )

      # Kill it before the on_exit cleanup runs.
      # Unlink first so the exit doesn't propagate to the test process.
      Process.unlink(pid)
      Process.exit(pid, :kill)
      Process.sleep(50)

      # The on_exit cleanup (registered in setup) should not crash
      # even though the renderer is dead. We verify by checking the
      # registry lookup returns empty (process already gone).
      assert Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id) == []
    end

    test "repeated renderer deaths don't accumulate stale registry entries", %{
      state: state,
      session_id: session_id
    } do
      # First call starts a renderer
      RollbackTestMockLLM.set_response(%{text: "reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        Loop.handle_input("prompt 1", state)
      end)

      [{pid1, _}] = Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id)

      # Kill it — unlink first so the exit doesn't kill the test process.
      Process.unlink(pid1)
      Process.exit(pid1, :kill)
      Process.sleep(50)

      # Second call should recover
      RollbackTestMockLLM.set_response(%{text: "reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        Loop.handle_input("prompt 2", state)
      end)

      # Registry should have exactly one entry (the new renderer)
      entries = Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id)
      assert length(entries) == 1
      [{pid2, _}] = entries
      refute pid2 == pid1
    end

    test "ensure_renderer failure rolls back user message (regression)", %{
      state: state,
      session_id: session_id
    } do
      # Pre-seed one message to prove rollback is surgical (not just clearing).
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "earlier message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      # Inject a synthetic ensure_renderer failure via app env.
      # This exercises the rollback path in dispatch_after_append's
      # else clause — the exact path the fix addresses.
      Application.put_env(:code_puppy_control, :test_ensure_renderer_error, :renderer_down)

      on_exit(fn ->
        Application.delete_env(:code_puppy_control, :test_ensure_renderer_error)
      end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("This should be rolled back", state)
        end)

      # Error indicator should appear in output
      assert output =~ "⚠" or output =~ "\e[31m" or output =~ "dispatch failed"

      # The user message must have been rolled back — only the pre-seed remains.
      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 1
      assert hd(messages)["parts"] |> hd() |> Map.get("text") == "earlier message"

      # Clean up injection point
      Application.delete_env(:code_puppy_control, :test_ensure_renderer_error)
    end

    test "run_until_done error still rolls back user message after refactor (regression)",
         %{
           state: state,
           session_id: session_id
         } do
      # Pre-seed one message to prove rollback is surgical.
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "earlier message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      # Verify the existing run_until_done error rollback still works
      # correctly after the send_to_agent → dispatch_after_append refactor.
      # This is a regression guard: the refactoring must not break the
      # error path that was already covered.
      RollbackTestMockLLM.set_error(:test_failure)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("This should be rolled back", state)
        end)

      assert output =~ "⚠" or output =~ "\e[31m"

      # The user message must have been rolled back — only the pre-seed remains.
      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 1
      assert hd(messages)["parts"] |> hd() |> Map.get("text") == "earlier message"
    end

    test "recovers when renderer crashes during reset (deterministic dead-after-lookup)", %{
      state: state,
      session_id: session_id
    } do
      # Plant a "zombie" process registered in the RendererRegistry that
      # will exit without replying when it receives a GenServer call.
      # This deterministically exercises the Registry.lookup → Renderer.reset
      # → crash → catch → start_renderer_idempotent path, without relying
      # on sleep-based timing to clear the registry entry first.
      zombie_pid =
        spawn(fn ->
          {:ok, _} = Registry.register(CodePuppyControl.REPL.RendererRegistry, session_id, nil)

          receive do
            {:"$gen_call", _from, _msg} ->
              # Simulate a renderer that crashes during reset — exit
              # without replying so the caller's GenServer.call detects
              # the crash via its monitor.
              exit(:crash)
          end
        end)

      # Yield to let the zombie's registration take effect
      Process.sleep(1)

      # Verify the zombie is registered and alive (lookup WILL find it)
      assert [{^zombie_pid, _}] =
               Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id)

      assert Process.alive?(zombie_pid)

      # Now call handle_input. ensure_renderer will:
      # 1. Registry.lookup → finds zombie_pid ✓
      # 2. Renderer.reset(zombie_pid) → GenServer.call → zombie exits ✓
      # 3. catch :exit → start_renderer_idempotent → fresh renderer ✓
      RollbackTestMockLLM.set_response(%{text: "recovered reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("Test prompt", state)
      end)

      # Messages should be persisted despite the renderer crash
      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2

      assert [
               %{"role" => "user", "parts" => [%{"type" => "text", "text" => "Test prompt"}]},
               %{
                 "role" => "assistant",
                 "parts" => [%{"type" => "text", "text" => "recovered reply"}]
               }
             ] =
               messages
    end

    test "REPL survives renderer death between prompts without Process.unlink masking (regression)",
         %{
           state: state,
           session_id: session_id
         } do
      # First call: starts a renderer via handle_input. With the fix,
      # start_renderer_idempotent unlinks the renderer from the caller
      # (REPL process), so renderer death does NOT propagate.
      RollbackTestMockLLM.set_response(%{text: "first reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("Hello", state)
      end)

      # The renderer should now be registered
      [{renderer_pid, _}] = Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id)
      assert Process.alive?(renderer_pid)

      # Kill the renderer WITHOUT calling Process.unlink first.
      #
      # Before the fix, the renderer was linked to the REPL
      # process (the test process here), so Process.exit would propagate
      # the exit signal and kill the REPL. After the fix, the renderer
      # is unlinked by start_renderer_idempotent, so the REPL survives.
      #
      # NOTE: We intentionally do NOT call Process.unlink(renderer_pid)
      # here — this test proves the production code unlink is sufficient.
      Process.exit(renderer_pid, :kill)

      # Wait for the registry to notice the exit
      Process.sleep(50)

      # The test process (acting as REPL) must still be alive.
      # If we reach this assertion, the REPL survived the renderer death
      # without test-side Process.unlink masking.
      assert Process.alive?(self())

      # Second call: ensure_renderer should recover by spawning a new renderer.
      RollbackTestMockLLM.set_response(%{text: "second reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("Hello again", state)
      end)

      # A new renderer should be registered for this session
      case Registry.lookup(CodePuppyControl.REPL.RendererRegistry, session_id) do
        [] ->
          # Registry may have been cleaned up already — the important
          # thing is the call didn't crash the REPL.
          :ok

        [{new_pid, _}] ->
          # New renderer should be a different pid
          refute new_pid == renderer_pid
          assert Process.alive?(new_pid)
      end

      # Messages should be persisted despite the renderer crash
      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 4
    end
  end
end
