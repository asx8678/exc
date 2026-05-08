defmodule CodePuppyControl.REPL.Dispatch do
  @moduledoc """
  Renderer management and agent dispatch helpers for the REPL loop.

  Extracted from `REPL.Loop` to keep the main loop module under
  the 600-line cap.

  ## Responsibilities

    * **Renderer lifecycle** — `ensure_renderer/1`, `start_renderer_idempotent/3`,
      and crash-recovery logic for the `RendererRegistry`.
    * **Agent dispatch** — `dispatch_after_append/4` orchestrates the
      renderer → Agent.Loop → message-persistence pipeline with rollback
      semantics on any failure.
    * **Agent loop management** — `start_agent_loop/4`, `stop_agent_loop/1`.
    * **Message normalization** — `normalize_for_state/1` converts atom-keyed
      Agent.Loop messages to the string-keyed, parts-based format expected
      by `Agent.State`.

  All functions are public so they can be called from `REPL.Loop`, but they
  are **not** part of the public API and may change without notice.
  """

  require Logger

  alias CodePuppyControl.Agent.{Loop, State}
  alias CodePuppyControl.SessionStorage
  alias CodePuppyControl.TUI.Renderer

  @renderer_registry CodePuppyControl.REPL.RendererRegistry

  # ── Dispatch After Append ────────────────────────────────────────────────

  # Runs after the user message has been appended to Agent.State.
  # `messages_before` is the snapshot taken *before* the append; on any
  # failure we roll back to it so no orphaned user message remains.
  #
  # the catch clauses wrap the ENTIRE critical section (not just
  # the inner loop block), so raises/throws/exits from ensure_renderer/1,
  # Loop.generate_run_id/0, start_agent_loop/4, and the success path all
  # restore messages_before.
  @doc false
  def dispatch_after_append(state, agent_key, agent_module, messages_before) do
    messages = State.get_messages(state.session_id, agent_key)
    pre_count = length(messages)

    # Trap exits for the entire critical section so that a linked process
    # crash (e.g., Agent.Loop) never kills the REPL. The renderer is
    # unlinked from the caller (see start_renderer_idempotent), but we
    # still trap for defensive safety across the full lifecycle.
    prev_trap = Process.flag(:trap_exit, true)

    try do
      with {:ok, renderer_pid} <- ensure_renderer(state),
           run_id <- Loop.generate_run_id(),
           {:ok, loop_pid} <- start_agent_loop(agent_module, messages, state, run_id) do
        try do
          case Loop.run_until_done(loop_pid, :infinity) do
            :ok ->
              # Test injection: fault in the success path to exercise
              # rollback on raises/throws/exits.
              inject_success_fault()

              # Use set_messages instead of Enum.drop + append_message.
              # The old code assumed final_messages was prefix-aligned with the
              # pre-run history, but Agent.Loop compaction can rewrite or drop
              # messages before returning. Enum.drop(final_messages, pre_count)
              # would silently drop replies after compaction. Setting the full
              # list atomically is compaction-safe and preserves rollback
              # semantics (on error, messages_before is still restored).
              final_messages = Loop.get_messages(loop_pid)
              normalized = Enum.map(final_messages, &normalize_for_state/1)

              Logger.debug(
                "REPL: send_to_agent pre_count=#{pre_count} final_count=#{length(final_messages)} " <>
                  "persisted=#{length(normalized)}"
              )

              State.set_messages(state.session_id, agent_key, normalized)

              # Fire-and-forget autosave
              SessionStorage.save_session_async(
                state.session_id,
                State.get_messages(state.session_id, agent_key),
                []
              )

              # Best-effort finalize — a Renderer crash (e.g., IO device
              # terminated during test) must not prevent message persistence
              # or crash the REPL.
              try do
                Renderer.finalize(renderer_pid)
              rescue
                _ -> :ok
              catch
                :exit, _ -> :ok
              end

              :ok

            {:error, reason} ->
              # Roll back to the snapshot taken before appending the user message
              State.set_messages(state.session_id, agent_key, messages_before)
              print_agent_error(reason)
              :error
          end
        after
          stop_agent_loop(loop_pid)
        end
      else
        {:error, reason} ->
          # ensure_renderer or start_agent_loop failed after the user message
          # was already appended — roll back to the pre-append snapshot.
          State.set_messages(state.session_id, agent_key, messages_before)
          print_agent_error("Agent dispatch failed: #{inspect(reason)}")
          :error
      end
    catch
      :exit, reason ->
        # Agent.Loop GenServer died mid-call (e.g. crashed during
        # run_until_done or get_messages). Roll back the user message
        # so it is not orphaned in Agent.State.
        State.set_messages(state.session_id, agent_key, messages_before)
        print_agent_error("Agent loop crashed: #{inspect(reason)}")
        :error

      # broaden rollback to cover raises and throws across the
      # ENTIRE post-append critical section — not just the inner loop block.
      # Previously only :exit was caught, and only inside the inner try, so
      # any raise from ensure_renderer, generate_run_id, start_agent_loop,
      # or the success path would propagate uncaught and crash the REPL
      # — leaving the appended user message orphaned in Agent.State.
      :error, reason ->
        State.set_messages(state.session_id, agent_key, messages_before)
        print_agent_error("Unexpected error after append: #{inspect(reason)}")
        :error

      :throw, value ->
        State.set_messages(state.session_id, agent_key, messages_before)
        print_agent_error("Unexpected throw after append: #{inspect(value)}")
        :error
    after
      Process.flag(:trap_exit, prev_trap)
      # Drain any :EXIT messages that arrived during the critical section
      receive do
        {:EXIT, _, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  # Test injection helper: reads :test_dispatch_success_fault from app env
  # and raises/throws/exits accordingly. Supports:
  # - binary → raise(message)
  # - exception struct → raise(exception)
  # - {:throw, value} → throw(value)
  # - {:exit, reason} → exit(reason)
  # Returns :ok when no fault is configured (production path).
  defp inject_success_fault do
    case Application.get_env(:code_puppy_control, :test_dispatch_success_fault) do
      nil -> :ok
      {:throw, value} -> throw(value)
      {:exit, reason} -> exit(reason)
      exception when is_exception(exception) -> raise(exception)
      message when is_binary(message) -> raise(message)
    end
  end

  # ── Renderer Management ──────────────────────────────────────────────────

  @doc false
  def ensure_renderer(state) do
    cond do
      # Test injection: raise instead of returning {:error, ...} to exercise
      # the outer catch :error clause in dispatch_after_append.
      msg = Application.get_env(:code_puppy_control, :test_ensure_renderer_raise) ->
        raise msg

      # Test injection: return a synthetic error to exercise the rollback path
      # in dispatch_after_append's else clause. Mirrors the :repl_llm_module
      # pattern already used for LLM mock injection.
      reason = Application.get_env(:code_puppy_control, :test_ensure_renderer_error) ->
        {:error, reason}

      true ->
        ensure_renderer_impl(state)
    end
  end

  defp ensure_renderer_impl(state) do
    renderer_name = renderer_name(state.session_id)

    case Registry.lookup(@renderer_registry, state.session_id) do
      [] ->
        start_renderer_idempotent(renderer_name, state.session_id)

      [{pid, _value}] ->
        # The renderer pid from the registry may have exited between the
        # lookup and the reset call (e.g. IO device terminated during test).
        # Catch the exit and spawn a fresh renderer instead of crashing.
        try do
          Renderer.reset(pid)
          {:ok, pid}
        catch
          :exit, _ ->
            # Renderer died between lookup and reset. Start fresh,
            # idempotently handling any registration races (concurrent
            # start, stale Registry entry, etc.).
            start_renderer_idempotent(renderer_name, state.session_id)
        end
    end
  end

  # Starts a renderer, handling the race where another process already
  # started one for the same session. This can happen when:
  # - A concurrent REPL call won the start race
  # - The Registry hasn't cleaned up a dead process's entry yet
  #
  # INVARIANT: never returns {:ok, dead_pid}. If the existing renderer
  # died during reset or the Registry entry is stale, we retry; after
  # exhaustion we return an explicit error so the caller can fail cleanly.
  @doc false
  def start_renderer_idempotent(renderer_name, session_id, attempts \\ 0) do
    case Renderer.start_link(name: renderer_name, session_id: session_id) do
      {:ok, pid} ->
        # Unlink the renderer from the caller (REPL process) so that a
        # renderer crash between prompts cannot kill the REPL. The Registry
        # tracks the renderer; ensure_renderer handles recovery on next call.
        Process.unlink(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        cond do
          not Process.alive?(pid) ->
            # Stale Registry entry (process died but entry not yet removed).
            # Yield briefly to let the Registry partition process the DOWN
            # message, then retry. Cap retries to avoid infinite loops.
            if attempts < 5 do
              Process.sleep(1)
              start_renderer_idempotent(renderer_name, session_id, attempts + 1)
            else
              {:error, {:renderer_not_alive, pid}}
            end

          reset_failed?(pid) ->
            # Renderer.reset raised or exited — the process likely died.
            # Re-lookup via retry instead of returning a dying pid.
            if attempts < 5 do
              Process.sleep(1)
              start_renderer_idempotent(renderer_name, session_id, attempts + 1)
            else
              {:error, {:renderer_reset_failed, pid}}
            end

          true ->
            # Reset succeeded and pid is still alive.
            {:ok, pid}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reset_failed?(pid) do
    try do
      Renderer.reset(pid)
      # Reset returned — but the process may have died right after.
      # The caller already checked Process.alive? so a false positive
      # here is harmless (we just do an unnecessary retry).
      not Process.alive?(pid)
    catch
      :exit, _ -> true
    end
  end

  @doc false
  def renderer_name(session_id) do
    # Uses {:via, Registry, ...} so renderer processes are registered
    # without creating atoms from unbounded session IDs.
    {:via, Registry, {@renderer_registry, session_id}}
  end

  # ── Agent Loop Management ─────────────────────────────────────────────────

  @doc false
  def start_agent_loop(agent_module, messages, state, run_id) do
    # Test injection: raise instead of returning {:error, ...} to exercise
    # the outer catch :error clause in dispatch_after_append.
    if msg = Application.get_env(:code_puppy_control, :test_start_agent_loop_raise) do
      raise msg
    end

    # test injection for compaction options so regression tests
    # can trigger compaction with a low message threshold.
    compaction_opts =
      Application.get_env(:code_puppy_control, :test_compaction_opts, [])

    opts = [
      run_id: run_id,
      session_id: state.session_id,
      model: state.model,
      llm_module:
        Application.get_env(
          :code_puppy_control,
          :repl_llm_module,
          CodePuppyControl.Agent.LLMAdapter
        ),
      compaction_opts: compaction_opts,
      metadata: %{interactive_approval: true}
    ]

    case Loop.start_link(agent_module, messages, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Shouldn't happen with unique run_id, but be defensive
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def stop_agent_loop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── Error Formatting ─────────────────────────────────────────────────────

  @doc false
  def print_agent_error(message) when is_binary(message) do
    IO.puts(IO.ANSI.red() <> "⚠ " <> message <> IO.ANSI.reset())
  end

  def print_agent_error(:not_authenticated) do
    IO.puts(
      IO.ANSI.red() <>
        "⚠ Model is not authenticated. " <>
        "For ChatGPT OAuth run /chatgpt-auth; " <>
        "for Claude Code OAuth run /claude-code-auth, then retry." <>
        IO.ANSI.reset()
    )
  end

  def print_agent_error(:missing_account_id) do
    IO.puts(
      IO.ANSI.red() <>
        "⚠ ChatGPT OAuth token is missing account_id. " <>
        "Run /chatgpt-auth to re-authenticate, then retry." <>
        IO.ANSI.reset()
    )
  end

  def print_agent_error(other) do
    IO.puts(IO.ANSI.red() <> "\u26A0 " <> inspect(other) <> IO.ANSI.reset())
  end

  # ── Message Normalization ─────────────────────────────────────────────────

  # Converts atom-keyed message maps to the string-keyed, parts-based
  # format expected by Agent.State.message_hash/1.
  #
  # Agent.State hashes messages using the "role" and "parts" keys (Python
  # convention). Messages from Agent.Loop use atom-keyed :role/:content
  # instead. Without this conversion, all messages with the same role hash
  # identically and are silently dropped by the dedup logic.
  @doc false
  def normalize_for_state(map) when is_map(map) do
    map
    |> stringify_keys()
    |> content_to_parts()
  end

  def normalize_for_state(list) when is_list(list) do
    Enum.map(list, &normalize_for_state/1)
  end

  def normalize_for_state(value), do: value

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_for_state(v)}
      {k, v} when is_binary(k) -> {k, normalize_for_state(v)}
    end)
  end

  defp stringify_keys(value), do: normalize_for_state(value)

  # Convert "content" field to "parts" list for Agent.State hash compatibility.
  # Python messages use: %{"role" => ..., "parts" => [%{"type" => "text", "text" => ...}]}
  # Elixir Agent.Loop uses: %{role: ..., content: ...}
  defp content_to_parts(%{"content" => _content, "parts" => _parts} = msg) do
    # Already has parts — leave as is
    msg
  end

  defp content_to_parts(%{"content" => content} = msg) when is_binary(content) do
    msg
    |> Map.delete("content")
    |> Map.put("parts", [%{"type" => "text", "text" => content}])
  end

  defp content_to_parts(%{"content" => content} = msg) when is_list(content) do
    # Multi-part content (e.g., tool result blocks)
    parts = Enum.map(content, &part_for_content/1)
    msg |> Map.delete("content") |> Map.put("parts", parts)
  end

  defp content_to_parts(msg), do: msg

  defp part_for_content(%{} = part), do: part
  defp part_for_content(text) when is_binary(text), do: %{"type" => "text", "text" => text}
end
