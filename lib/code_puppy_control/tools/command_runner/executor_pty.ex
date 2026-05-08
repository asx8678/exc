defmodule CodePuppyControl.Tools.CommandRunner.ExecutorPty do
  @moduledoc """
  PTY (pseudo-terminal) execution logic for shell commands.

  Delegates to `PtyManager` for true PTY allocation, providing:
  - Proper terminal semantics (readline, colors, $LINES/$COLUMNS)
  - Signal handling (SIGINT propagates to child)
  - Window resize support

  When PTY creation fails, falls back to standard execution via
  `Executor` and reports `pty: false` in the result.

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  require Logger

  alias CodePuppyControl.Tools.CommandRunner.{Executor, OutputProcessor, ProcessManager}
  alias CodePuppyControl.Concurrency.Limiter
  alias CodePuppyControl.PtyManager

  # Default timeout for commands (seconds)
  @default_timeout 60
  @env Mix.env()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Executes a shell command in a PTY session.

  If PTY creation fails, falls back to standard execution.

  ## Options

  - `:timeout` - Timeout in seconds (default: 60, max: 270)
  - `:cwd` - Working directory
  - `:env` - Additional environment variables
  - `:silent` - Suppress streaming output (default: false)
  """
  @spec execute(String.t(), keyword()) ::
          {:ok, Executor.execution_result()} | {:error, String.t()}
  def execute(command, opts \\ []) when is_binary(command) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, [])
    silent = Keyword.get(opts, :silent, false)

    # Acquire concurrency slot
    case Limiter.acquire(:tool_calls) do
      :ok ->
        try do
          do_execute_pty(command, timeout, cwd, env, silent)
        after
          Limiter.release(:tool_calls)
        end

      {:error, :timeout} ->
        {:error, "Concurrency limit reached for tool calls"}
    end
  end

  # ---------------------------------------------------------------------------
  # PTY Execution
  # ---------------------------------------------------------------------------

  defp do_execute_pty(command, timeout, cwd, env, silent) do
    start_time = System.monotonic_time(:millisecond)

    # Build env string for PTY
    env_prefix = build_env_prefix(env, cwd)

    # Build the actual command to run in PTY (with env + cd)
    full_command =
      cond do
        cwd && env_prefix != "" -> "cd #{shlex_escape(cwd)} && #{env_prefix}#{command}"
        cwd -> "cd #{shlex_escape(cwd)} && #{command}"
        env_prefix != "" -> "#{env_prefix}#{command}"
        true -> command
      end

    # Create a unique session ID
    session_id = "cmd-#{:erlang.unique_integer([:positive])}"

    # Register with ProcessManager
    {:ok, tracking_id} = ProcessManager.register_command(command, mode: :pty)

    # Collect output from PTY
    parent = self()
    output_collector = spawn_link(fn -> collect_pty_output(parent, session_id, silent) end)

    try do
      case PtyManager.create_session(session_id,
             cols: 120,
             rows: 40,
             subscriber: output_collector
           ) do
        {:ok, session} ->
          # Update ProcessManager with OS PID
          if session.os_pid do
            ProcessManager.update_os_pid(tracking_id, session.os_pid)
          end

          # Send the command to the PTY
          PtyManager.write(session_id, full_command <> "\n")

          # Send exit command to close the shell after the command finishes
          PtyManager.write(session_id, "exit $?\n")

          # Wait for completion with timeout
          result =
            receive do
              {:pty_done, ^session_id, exit_code, chunks} ->
                execution_time = System.monotonic_time(:millisecond) - start_time
                # Output comes directly from the done message — no race
                # with collector lifecycle (code_puppy-mmk.6 fix).
                output = Enum.join(chunks, "")

                clean_output = OutputProcessor.strip_ansi(output)
                processed = OutputProcessor.process_output(clean_output)

                Executor.build_success_result(
                  command,
                  processed.text,
                  "",
                  exit_code,
                  execution_time,
                  false
                )
                |> Map.put(:pty, true)

              {:pty_timeout, ^session_id} ->
                execution_time = System.monotonic_time(:millisecond) - start_time
                output = get_pty_output(output_collector)

                clean_output = OutputProcessor.strip_ansi(output)
                processed = OutputProcessor.process_output(clean_output)

                Executor.build_timeout_result_with_output(
                  command,
                  processed.text,
                  execution_time
                )
                |> Map.put(:pty, true)
            after
              timeout * 1000 ->
                execution_time = System.monotonic_time(:millisecond) - start_time
                output = get_pty_output(output_collector)

                clean_output = OutputProcessor.strip_ansi(output)
                processed = OutputProcessor.process_output(clean_output)

                PtyManager.close_session(session_id)

                Executor.build_timeout_result_with_output(
                  command,
                  processed.text,
                  execution_time
                )
                |> Map.put(:pty, true)
            end

          {:ok, result}

        {:error, reason} ->
          # PTY creation failed — fall back to standard execution
          Logger.warning(
            "PTY creation failed (#{inspect(reason)}), falling back to standard execution"
          )

          send(output_collector, :stop)
          ProcessManager.unregister_command(tracking_id)

          # Fallback returns pty: false (the default)
          Executor.execute_standard(command,
            timeout: timeout,
            cwd: cwd,
            env: env,
            silent: silent
          )
      end
    rescue
      e ->
        send(output_collector, :stop)
        PtyManager.close_session(session_id)
        {:error, "PTY execution failed: #{Exception.message(e)}"}
    catch
      :exit, reason ->
        send(output_collector, :stop)
        PtyManager.close_session(session_id)
        {:error, "PTY execution crashed: #{inspect(reason)}"}
    after
      # Best-effort stop: harmless if collector already exited on pty_exit.
      send(output_collector, :stop)
      ProcessManager.unregister_command(tracking_id)
      PtyManager.close_session(session_id)
    end
  end

  # ---------------------------------------------------------------------------
  # PTY Output Collection
  # ---------------------------------------------------------------------------

  # Spawns a linked process that collects PTY output chunks and forwards
  # pty_exit notifications to the parent. Supports {:get_output, requester}
  # for retrieving collected output while preserving chunk arrival order.

  defp collect_pty_output(parent, session_id, silent) do
    collect_pty_loop(parent, session_id, [], silent)
  end

  defp collect_pty_loop(parent, session_id, chunks, silent) do
    receive do
      {:pty_output, ^session_id, data} ->
        unless silent, do: emit_shell_output(data)
        # Prepend for O(1) insertion; reversed on retrieval
        collect_pty_loop(parent, session_id, [data | chunks], silent)

      {:pty_exit, ^session_id, status} ->
        # Include collected output in the done message so the parent never
        # races with a dead collector.  This is the primary fix for
        # code_puppy-mmk.6: the old code sent only the exit code, then
        # exited — the parent's subsequent get_pty_output/1 call found a
        # dead process and returned "".
        ordered_chunks = Enum.reverse(chunks)
        send(parent, {:pty_done, session_id, parse_exit_status(status), ordered_chunks})

      # Process exits naturally — output already delivered.

      {:get_output, requester} ->
        # Return chunks in arrival order (reverse the prepended list)
        ordered = Enum.reverse(chunks)
        send(requester, {:output, ordered})
        collect_pty_loop(parent, session_id, chunks, silent)

      :stop ->
        :ok
    after
      100 -> collect_pty_loop(parent, session_id, chunks, silent)
    end
  end

  defp parse_exit_status(:normal), do: 0
  defp parse_exit_status(:closed), do: 0
  defp parse_exit_status({:status, code}) when is_integer(code), do: code
  defp parse_exit_status(_), do: -1

  defp get_pty_output(collector_pid) do
    send(collector_pid, {:get_output, self()})

    receive do
      {:output, chunks} -> Enum.join(chunks, "")
    after
      1000 -> ""
    end
  end

  defp emit_shell_output(data) do
    # (code_puppy-i1n) Guard against PubSub being unavailable (e.g. during
    # test suite shutdown or supervision tree restart).  A missing PubSub
    # registry raises ArgumentError; we log and continue rather than
    # crashing the collect_pty_loop process and cascading via EXIT signals.
    try do
      Phoenix.PubSub.broadcast(
        CodePuppyControl.PubSub,
        "shell:output",
        {:shell_output, data}
      )
    rescue
      e in ArgumentError ->
        unless @env == :test do
          Logger.warning("Shell output PubSub broadcast failed: #{Exception.message(e)}")
        end

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_env_prefix([], _cwd), do: ""

  defp build_env_prefix(env, _cwd) do
    env
    |> Enum.map(fn {k, v} -> "#{k}=#{shlex_escape(v)}" end)
    |> Enum.join(" ")
    |> then(&(&1 <> " "))
  end

  defp shlex_escape(str) when is_binary(str) do
    str |> String.replace("'", "'\\''") |> then(&"'#{&1}'")
  end
end
