defmodule CodePuppyControl.REPL.DispatchRollbackTestHelper do
  @moduledoc """
  Shared helper for dispatch rollback regression tests.

  Provides the mock LLM module and common setup callback used by the
  split test files:
    - dispatch_rollback_success_test.exs
    - dispatch_rollback_with_clause_test.exs

  Extracted from dispatch_rollback_test.exs to keep each file
  under the 600-line cap.
  """

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.REPL.Loop
  alias CodePuppyControl.Tools.AgentCatalogue

  # ---------------------------------------------------------------------------
  # Mock LLM (standalone module to avoid BEAM name collisions with
  # RollbackTestMockLLM and CrashMidCallMockLLM in sibling test files.)
  # ---------------------------------------------------------------------------

  defmodule DispatchRollbackMockLLM do
    @moduledoc """
    Mock LLM module for dispatch rollback regression tests.

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
  # Shared setup callback
  # ---------------------------------------------------------------------------

  @doc """
  Setup callback for dispatch rollback tests.

  Creates a fresh session, configures DispatchRollbackMockLLM as the REPL LLM, and
  registers an `on_exit` callback that restores all mutated application
  environment and cleans up the renderer process.
  """
  def setup_mock_llm_and_session(_context) do
    session_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    prev_llm = Application.get_env(:code_puppy_control, :repl_llm_module)
    Application.put_env(:code_puppy_control, :repl_llm_module, DispatchRollbackMockLLM)
    DispatchRollbackMockLLM.reset()

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

      Application.delete_env(:code_puppy_control, :test_dispatch_success_fault)
      Application.delete_env(:code_puppy_control, :test_ensure_renderer_raise)
      Application.delete_env(:code_puppy_control, :test_start_agent_loop_raise)
      Application.delete_env(:code_puppy_control, :test_ensure_renderer_error)
      Application.delete_env(:code_puppy_control, :test_compaction_opts)

      DispatchRollbackMockLLM.stop()

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
end
