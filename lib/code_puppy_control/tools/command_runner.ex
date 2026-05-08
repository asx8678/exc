defmodule CodePuppyControl.Tools.CommandRunner do
  @moduledoc """
  Shell command execution for agent tool calls.

  SECURITY NOTE: Commands arrive as complete strings from the LLM (e.g.
  "cd /foo && make test" or "cat file | grep pattern") and REQUIRE shell
  interpretation for pipes, redirects, chains, and variable expansion.

  Security is enforced through a layered pipeline:
  1. `CommandRunner.Validator` — Defense-in-depth validation (length, chars, patterns)
  2. `CommandRunner.Security` — PolicyEngine + callback hook integration
  3. `CommandRunner.ProcessManager` — Process tracking and kill escalation
  4. `CommandRunner.Executor` — Core execution (standard, PTY, background)
  5. `CommandRunner.OutputProcessor` — Line truncation and output formatting

  ## Usage

      # Simple command with default timeout
      {:ok, result} = CommandRunner.run("echo hello", timeout: 30)

      # PTY-backed execution (interactive terminal)
      {:ok, result} = CommandRunner.run("python3 -i", pty: true)

      # Background execution (detached, returns immediately)
      {:ok, result} = CommandRunner.run("make build", background: true)

  ## Result Structure

      %{
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

  ## Architecture

  - `CommandRunner` — Main API module (this module, facade)
  - `CommandRunner.Validator` — Security validation
  - `CommandRunner.Security` — PolicyEngine + callback integration
  - `CommandRunner.ProcessManager` — Process tracking and lifecycle
  - `CommandRunner.Executor` — Core execution logic
  - `CommandRunner.OutputProcessor` — Output formatting

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  require Logger

  alias CodePuppyControl.Tools.CommandRunner.{
    Executor,
    OutputProcessor,
    ProcessManager,
    Security,
    Validator
  }

  # Default timeout for commands (seconds)
  @default_timeout 60
  # Absolute maximum timeout for any command (seconds)
  @absolute_timeout 270

  @typedoc """
  Result structure for command execution.
  """
  @type result :: %{
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

  @typedoc """
  Options for command execution.
  """
  @type opts :: [
          timeout: non_neg_integer(),
          cwd: String.t() | nil,
          env: [{String.t(), String.t()}],
          pty: boolean(),
          background: boolean(),
          silent: boolean(),
          skip_security: boolean(),
          context: map()
        ]

  @doc """
  Runs a shell command with the given options.

  Performs the full security pipeline before execution:
  1. Security check (PolicyEngine + callbacks + validation)
  2. Execution (standard / PTY / background)
  3. Output processing (truncation, formatting)

  ## Options

  - `:timeout` - Timeout in seconds (default: 60, max: 270)
  - `:cwd` - Working directory for the command
  - `:env` - Additional environment variables as key-value list
  - `:pty` - Use PTY execution (default: false)
  - `:background` - Run in background mode (default: false)
  - `:silent` - Suppress streaming output (default: false)
  - `:skip_security` - Skip PolicyEngine/callback checks (default: false, dev only)
  - `:context` - Context map for security callbacks

  ## Returns

  - `{:ok, result}` - Command executed (check `result.success` for exit code)
  - `{:error, reason}` - Security check failed or execution error

  ## Examples

      iex> CommandRunner.run("echo hello")
      {:ok, %{success: true, stdout: "hello", ...}}

      iex> CommandRunner.run("invalid_command_12345")
      {:ok, %{success: false, stdout: "", stderr: "...", exit_code: 127, ...}}
  """
  @spec run(String.t(), opts()) :: {:ok, result()} | {:error, String.t()}
  def run(command, opts \\ []) when is_binary(command) do
    timeout = min(Keyword.get(opts, :timeout, @default_timeout), @absolute_timeout)

    # Step 1: Security check pipeline
    if Keyword.get(opts, :skip_security, false) do
      # Skip security — only run validator
      case Validator.validate(command) do
        {:ok, _} ->
          do_run(command, Keyword.put(opts, :timeout, timeout))

        {:error, reason} ->
          {:error, "Command validation failed: #{reason}"}
      end
    else
      case Security.check(command,
             cwd: Keyword.get(opts, :cwd),
             timeout: timeout,
             context: Keyword.get(opts, :context, %{})
           ) do
        %{allowed: true} ->
          do_run(command, Keyword.put(opts, :timeout, timeout))

        %{allowed: false, decision: {:denied, reason}} ->
          {:error, reason}

        %{allowed: false, decision: {:ask_user, prompt}} ->
          # TODO(code_puppy-mmk.6): Integrate with user interaction system
          # For now, ask_user is treated as a denial
          {:error, "Command requires user approval: #{prompt}"}

        %{allowed: false, reason: reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Kills all running shell processes tracked by the ProcessManager.

  Returns the number of processes killed.
  """
  @spec kill_all() :: non_neg_integer()
  def kill_all do
    ProcessManager.kill_all()
  end

  @doc """
  Returns the count of currently running shell processes.
  """
  @spec running_count() :: non_neg_integer()
  def running_count do
    ProcessManager.count()
  end

  @doc """
  Kills a specific process by its OS PID.

  Returns `:ok` if the process was signaled, `{:error, reason}` otherwise.
  """
  @spec kill_process(integer()) :: :ok | {:error, String.t()}
  def kill_process(pid) when is_integer(pid) do
    ProcessManager.kill_process(pid)
  end

  @doc """
  Returns whether a PID was killed by user action (Ctrl-C/Ctrl-X).
  """
  @spec is_user_interrupted?(integer()) :: boolean()
  def is_user_interrupted?(pid) when is_integer(pid) do
    ProcessManager.is_pid_killed?(pid)
  end

  @doc """
  Truncates a line to the maximum allowed length.

  Delegates to `OutputProcessor.truncate_line/2`.
  """
  @spec truncate_line(String.t(), non_neg_integer()) :: String.t()
  def truncate_line(line, max_length \\ 256) do
    OutputProcessor.truncate_line(line, max_length)
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  defp do_run(command, opts) do
    Executor.execute(command, opts)
  end
end
