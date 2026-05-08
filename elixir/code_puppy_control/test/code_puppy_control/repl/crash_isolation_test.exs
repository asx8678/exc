defmodule CodePuppyControl.REPL.CrashIsolationTest do
  @moduledoc """
  Regression tests for : REPL.Loop crash isolation when
  Agent.Loop GenServer dies mid-call.

  The core vulnerability: `Loop.start_link` creates a bi-directional
  link between the REPL process and Agent.Loop. If Agent.Loop crashes
  during `run_until_done/2`, `GenServer.call` throws an `:exit`
  exception that was NOT caught, propagating up and killing the REPL.

  The fix adds `catch :exit` on the inner `try` block in
  `dispatch_after_append`. When Agent.Loop dies mid-call,
  `GenServer.call` throws an `:exit` exception; the catch clause
  rolls back the user message and reports the error instead of
  propagating the crash to the REPL.

  The surrounding `trap_exit` critical section already neutralises
  exit signals from the linked Agent.Loop, so no `Process.unlink`
  is needed.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.REPL.Loop
  alias CodePuppyControl.Tools.AgentCatalogue

  # ---------------------------------------------------------------------------
  # Mock LLM that kills the Agent.Loop process from within stream_chat/4.
  #
  # When stream_chat runs inside Agent.Loop, calling exit/1 terminates
  # that process. GenServer.call in the REPL process then throws an
  # :exit exception — exactly the path hardens.
  # ---------------------------------------------------------------------------

  defmodule CrashMidCallMockLLM do
    @moduledoc """
    Mock LLM that crashes the Agent.Loop process during stream_chat.

    Uses an Elixir.Agent to control crash/no-crash mode per test.
    """
    @behaviour CodePuppyControl.Agent.LLM

    def ensure_started do
      case Elixir.Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def set_crash(reason) do
      ensure_started()
      Elixir.Agent.update(__MODULE__, &Map.put(&1, :crash_reason, reason))
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
    def stream_chat(_messages, _tools, opts, callback_fn) do
      ensure_started()
      state = Elixir.Agent.get(__MODULE__, & &1)

      cond do
        state[:crash_reason] ->
          # Kill the Agent.Loop process from within. This causes
          # GenServer.call in the REPL to throw an :exit exception.
          exit(state[:crash_reason])

        state[:response] ->
          resp = state[:response]

          if resp[:text] do
            callback_fn.({:text, resp.text})
          end

          callback_fn.({:done, :complete})
          {:ok, resp}

        true ->
          {:error, :no_mock_configured}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shared setup
  # ---------------------------------------------------------------------------

  defp setup_crash_llm_and_session(_context) do
    # (code_puppy-i1n) Ensure Agent.State.Supervisor is alive —
    # Loop.handle_input calls ensure_agent_state_for which needs
    # the DynamicSupervisor to start child processes.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Agent.State.Supervisor
    )

    session_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    prev_llm = Application.get_env(:code_puppy_control, :repl_llm_module)
    Application.put_env(:code_puppy_control, :repl_llm_module, CrashMidCallMockLLM)
    CrashMidCallMockLLM.reset()

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

      CrashMidCallMockLLM.stop()

      try do
        State.clear_messages(session_id, "code_puppy")
      catch
        _, _ -> :ok
      end

      # Clean up any renderer process started for this session.
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
  # regression: Agent.Loop crash mid-call
  # ===========================================================================

  describe "send_to_agent/2 — Agent.Loop crashes during run_until_done" do
    setup :setup_crash_llm_and_session

    test "REPL survives and rolls back user message when Agent.Loop exits mid-call", %{
      state: state,
      session_id: session_id
    } do
      # Pre-seed a message to prove rollback is surgical, not a blanket clear.
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "earlier message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      # Configure the mock LLM to crash the Agent.Loop process during stream_chat.
      CrashMidCallMockLLM.set_crash(:mid_call_boom)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          # The REPL must survive — handle_input returns {:continue, state}.
          assert {:continue, ^state} = Loop.handle_input("This should be rolled back", state)
        end)

      # Error indicator should appear in output
      assert output =~ "⚠" or output =~ "\e[31m" or output =~ "crashed"

      # The user message must have been rolled back — only the pre-seed remains.
      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 1
      assert hd(messages)["parts"] |> hd() |> Map.get("text") == "earlier message"
    end

    test "REPL survives Agent.Loop crash with :noproc-style exit reason", %{
      state: state,
      session_id: session_id
    } do
      # Use :kill to simulate a brutal process kill (equivalent to :noproc path)
      CrashMidCallMockLLM.set_crash(:kill)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("prompt", state)
        end)

      assert output =~ "⚠" or output =~ "\e[31m" or output =~ "crashed"

      # No messages should remain — rolled back to empty.
      messages = State.get_messages(session_id, "code_puppy")
      assert messages == []
    end

    test "REPL survives and subsequent call works after Agent.Loop crash", %{
      state: state,
      session_id: session_id
    } do
      # First call: crash
      CrashMidCallMockLLM.set_crash(:first_crash)

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("crash me", state)
      end)

      # Second call: succeed (reset mock to normal response)
      CrashMidCallMockLLM.reset()
      CrashMidCallMockLLM.set_response(%{text: "recovered reply", tool_calls: []})

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("try again", state)
      end)

      # The second call should persist both messages
      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2

      assert [
               %{"role" => "user", "parts" => [%{"type" => "text", "text" => "try again"}]},
               %{
                 "role" => "assistant",
                 "parts" => [%{"type" => "text", "text" => "recovered reply"}]
               }
             ] = messages
    end
  end
end
