defmodule CodePuppyControl.Tools.CommandRunner.Executor do
  @moduledoc """
  Core execution logic for shell commands.

  Supports three execution modes:
  1. **Standard** - `System.cmd/3` with shell interpretation (pipes, redirects)
  2. **PTY** - Via `PtyManager` for interactive terminal emulation (delegates to `ExecutorPty`)
  3. **Background** - Detached process with log file capture

  ## Standard Execution

  Uses `sh -c` (or `cmd /c` on Windows) for shell interpretation.
  Handles timeout via `Task.async/yield/shutdown` pattern with
  inactivity and absolute timeouts.

  ## PTY Execution

  Delegates to `ExecutorPty` which manages PTY sessions via `PtyManager`.
  When PTY creation fails, `ExecutorPty` falls back to `execute_standard/2`
  and reports `pty: false` in the result.

  ## Background Execution

  Spawns a detached process with stdout/stderr redirected to a temp
  log file. Returns immediately with log path. The `pid` field is `nil`
  because the OS PID of the child shell is not directly available
  from `System.cmd/3`; process lifecycle is tracked via the BEAM PID
  in `ProcessManager`.

  ## Concurrency

  Uses `Concurrency.Limiter` for `:tool_calls` to respect
  system-wide concurrency limits.

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  require Logger

  alias CodePuppyControl.Tools.CommandRunner.{ExecutorPty, OutputProcessor, ProcessManager}
  alias CodePuppyControl.Concurrency.Limiter

  # Default timeout for commands (seconds)
  @default_timeout 60
  # Absolute maximum timeout (seconds) — mirrors Python ABSOLUTE_TIMEOUT_SECONDS
  @absolute_timeout 270

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type execution_opts :: [
          timeout: non_neg_integer(),
          cwd: String.t() | nil,
          env: [{String.t(), String.t()}],
          pty: boolean(),
          background: boolean(),
          silent: boolean(),
          context: map()
        ]

  @type execution_result :: %{
          success: boolean(),
          command: String.t(),
          stdout: String.t(),
          stderr: String.t(),
          exit_code: integer() | nil,
          execution_time_ms: integer(),
          timeout: boolean(),
          error: String.t() | nil,
          user_interrupted: boolean(),
          background: boolean(),
          log_file: String.t() | nil,
          pid: integer() | nil,
          pty: boolean()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Executes a shell command.

  Dispatches to the appropriate execution mode based on options.

  ## Options

  - `:timeout` - Timeout in seconds (default: 60, max: 270)
  - `:cwd` - Working directory
  - `:env` - Additional environment variables
  - `:pty` - Use PTY execution (default: false)
  - `:background` - Run in background (default: false)
  - `:silent` - Suppress streaming output (default: false)
  - `:context` - Context map for callbacks
  """
  @spec execute(String.t(), execution_opts()) :: {:ok, execution_result()} | {:error, String.t()}
  def execute(command, opts \\ []) when is_binary(command) do
    timeout = min(Keyword.get(opts, :timeout, @default_timeout), @absolute_timeout)
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, [])
    pty = Keyword.get(opts, :pty, false)
    background = Keyword.get(opts, :background, false)
    silent = Keyword.get(opts, :silent, false)

    cond do
      background ->
        execute_background(command, cwd: cwd, env: env)

      pty ->
        ExecutorPty.execute(command,
          timeout: timeout,
          cwd: cwd,
          env: env,
          silent: silent
        )

      true ->
        execute_standard(command,
          timeout: timeout,
          cwd: cwd,
          env: env,
          silent: silent
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Standard Execution (System.cmd with shell)
  # ---------------------------------------------------------------------------

  @doc false
  @spec execute_standard(String.t(), keyword()) ::
          {:ok, execution_result()} | {:error, String.t()}
  def execute_standard(command, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, [])
    silent = Keyword.get(opts, :silent, false)

    # Acquire concurrency slot
    case Limiter.acquire(:tool_calls) do
      :ok ->
        try do
          do_execute_standard(command, timeout, cwd, env, silent)
        after
          Limiter.release(:tool_calls)
        end

      {:error, :timeout} ->
        {:error, "Concurrency limit reached for tool calls"}
    end
  end

  defp do_execute_standard(command, timeout, cwd, env, _silent) do
    start_time = System.monotonic_time(:millisecond)

    # Register with ProcessManager
    {:ok, tracking_id} = ProcessManager.register_command(command, mode: :standard)

    try do
      cmd_opts = build_cmd_opts(cwd, env)
      {shell, shell_flag} = shell_command()

      # Execute in a Task for timeout handling
      task =
        Task.async(fn ->
          try do
            System.cmd(shell, [shell_flag, command], cmd_opts)
          rescue
            e -> {:error, Exception.message(e)}
          end
        end)

      result =
        case Task.yield(task, timeout * 1000) || Task.shutdown(task, :brutal_kill) do
          nil ->
            # Timeout
            execution_time = System.monotonic_time(:millisecond) - start_time
            build_timeout_result(command, execution_time)

          {:ok, {:error, reason}} ->
            execution_time = System.monotonic_time(:millisecond) - start_time
            build_error_result(command, reason, execution_time)

          {:ok, {output, exit_code}} ->
            execution_time = System.monotonic_time(:millisecond) - start_time

            # Process output through OutputProcessor
            processed = OutputProcessor.process_output(output || "")

            # Check if user interrupted
            user_interrupted = check_user_interrupted(task)

            build_success_result(
              command,
              processed.text,
              "",
              exit_code,
              execution_time,
              user_interrupted
            )

          {:exit, reason} ->
            execution_time = System.monotonic_time(:millisecond) - start_time
            build_error_result(command, "Task exited: #{inspect(reason)}", execution_time)
        end

      {:ok, result}
    rescue
      e ->
        {:error, "Command execution failed: #{Exception.message(e)}"}
    catch
      :exit, reason ->
        {:error, "Command execution failed: #{inspect(reason)}"}
    after
      ProcessManager.unregister_command(tracking_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Background Execution
  # ---------------------------------------------------------------------------

  defp execute_background(command, opts) do
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, [])

    # Acquire concurrency slot (brief, just for spawning)
    case Limiter.acquire(:tool_calls) do
      :ok ->
        try do
          do_execute_background(command, cwd, env)
        after
          Limiter.release(:tool_calls)
        end

      {:error, :timeout} ->
        {:error, "Concurrency limit reached for tool calls"}
    end
  end

  defp do_execute_background(command, cwd, env) do
    # Create temp log file for output
    log_path = Path.join(System.tmp_dir!(), "shell_bg_#{:erlang.unique_integer([:positive])}.log")

    # Register with ProcessManager
    {:ok, tracking_id} = ProcessManager.register_command(command, mode: :background)

    try do
      cmd_opts = build_cmd_opts(cwd, env)

      {shell, shell_flag} = shell_command()

      # Spawn a detached process.
      # NOTE(code_puppy-mmk.6): The OS PID of the child shell is not available
      # from System.cmd/3. The BEAM PID is tracked internally for lifecycle
      # monitoring via ProcessManager, but `pid` in the result is nil because
      # we cannot retrieve the OS PID of the sh -c child process.
      _bg_pid =
        spawn(fn ->
          {output, _exit_code} =
            try do
              System.cmd(shell, [shell_flag, command], cmd_opts)
            rescue
              e -> {Exception.message(e), -1}
            catch
              :exit, reason -> {"Process exited: #{inspect(reason)}", -1}
            end

          # Write output to log file (best-effort)
          if is_binary(output) do
            try do
              File.write!(log_path, output, [:append])
            rescue
              _ -> :ok
            end
          end

          # Unregister when done
          ProcessManager.unregister_command(tracking_id)
        end)

      # Return immediately with background info.
      # `pid` is nil — OS PID is not retrievable from System.cmd.
      # ProcessManager tracks the command for kill escalation.
      {:ok,
       %{
         success: true,
         command: command,
         stdout: "",
         stderr: "",
         exit_code: nil,
         execution_time_ms: 0,
         timeout: false,
         error: nil,
         user_interrupted: false,
         background: true,
         log_file: log_path,
         pid: nil,
         pty: false
       }}
    rescue
      e ->
        # Clean up log file on error
        File.rm(log_path)
        {:error, "Failed to start background process: #{Exception.message(e)}"}
    catch
      :exit, reason ->
        File.rm(log_path)
        {:error, "Failed to start background process: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_cmd_opts(cwd, env) do
    opts = [stderr_to_stdout: true, parallelism: true]
    opts = if cwd, do: [{:cd, cwd} | opts], else: opts
    if env != [], do: [{:env, env} | opts], else: opts
  end

  defp shell_command do
    case :os.type() do
      {:win32, _} -> {"cmd", "/c"}
      _ -> {"sh", "-c"}
    end
  end

  defp check_user_interrupted(_task) do
    # TODO(code_puppy-mmk.6): Check ProcessManager.is_pid_killed? for task's OS PID
    false
  end

  # ---------------------------------------------------------------------------
  # Result Builders (shared with ExecutorPty)
  # ---------------------------------------------------------------------------

  @doc false
  @spec build_result(map()) :: execution_result()
  def build_result(overrides) do
    defaults = %{
      success: false,
      command: "",
      stdout: "",
      stderr: "",
      exit_code: -1,
      execution_time_ms: 0,
      timeout: false,
      error: nil,
      user_interrupted: false,
      background: false,
      log_file: nil,
      pid: nil,
      pty: false
    }

    Map.merge(defaults, overrides)
  end

  @doc false
  @spec build_timeout_result(String.t(), integer()) :: execution_result()
  def build_timeout_result(command, execution_time_ms) do
    build_result(%{
      command: command,
      exit_code: -9,
      execution_time_ms: execution_time_ms,
      timeout: true,
      error: "Command timed out"
    })
  end

  @doc false
  @spec build_timeout_result_with_output(String.t(), String.t(), integer()) :: execution_result()
  def build_timeout_result_with_output(command, stdout, execution_time_ms) do
    build_result(%{
      command: command,
      stdout: stdout,
      exit_code: -9,
      execution_time_ms: execution_time_ms,
      timeout: true,
      error: "Command timed out"
    })
  end

  @doc false
  @spec build_error_result(String.t(), String.t(), integer()) :: execution_result()
  def build_error_result(command, reason, execution_time_ms) do
    build_result(%{
      command: command,
      stderr: reason,
      execution_time_ms: execution_time_ms,
      error: reason
    })
  end

  @doc false
  @spec build_success_result(String.t(), String.t(), String.t(), integer(), integer(), boolean()) ::
          execution_result()
  def build_success_result(
        command,
        stdout,
        stderr,
        exit_code,
        execution_time_ms,
        user_interrupted
      ) do
    error =
      cond do
        user_interrupted -> "Command interrupted by user"
        exit_code != 0 -> "Command failed with exit code #{exit_code}"
        true -> nil
      end

    build_result(%{
      success: exit_code == 0 and not user_interrupted,
      command: command,
      stdout: stdout,
      stderr: stderr,
      exit_code: exit_code,
      execution_time_ms: execution_time_ms,
      error: error,
      user_interrupted: user_interrupted
    })
  end
end
