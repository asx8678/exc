defmodule CodePuppyControl.Tools.CommandRunner.Security do
  @moduledoc """
  Security boundary integration for shell command execution.

  Provides defense-in-depth security by combining:
  1. **Validator** - Low-level command validation (length, forbidden chars, patterns)
  2. **Callbacks.RunShellCommand** - PolicyEngine + callback hook chain
     (policy rules → plugin callbacks, fail-closed)

  This mirrors the Python `SecurityBoundary.check_shell_command()` pattern
  where security decisions flow from validator → policy → callbacks.

  ## Fail-closed semantics

  If the PolicyEngine is unavailable or callbacks raise, the command is
  **denied** by default (fail-closed). This prevents accidental execution
  of unsafe commands when security infrastructure is degraded.

  ## Environment variables

  - `PUP_SKIP_SHELL_SAFETY` - Set to "1" to bypass policy/callback checks
    (validator still runs). Only for development/testing.
  - `PUP_YOLO_MODE` - Set to "1" to skip user confirmation prompts
    (policy checks still run).

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  require Logger

  alias CodePuppyControl.Callbacks.RunShellCommand
  alias CodePuppyControl.Tools.CommandRunner.Validator

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @typedoc """
  Security decision for a shell command.

  - `:allowed` - Command is permitted
  - `{:denied, reason}` - Command is blocked
  - `{:ask_user, prompt}` - Decision deferred to user
  """
  @type decision ::
          :allowed
          | {:denied, String.t()}
          | {:ask_user, String.t()}

  @typedoc """
  Full security check result.
  """
  @type check_result :: %{
          allowed: boolean(),
          reason: String.t() | nil,
          decision: decision()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Performs the full security check pipeline for a shell command.

  Pipeline order:
  1. Check `PUP_SKIP_SHELL_SAFETY` env var (dev bypass)
  2. Run PolicyEngine `check_shell_command/2`
  3. Trigger `run_shell_command` callback hook
  4. Run Validator validation (always runs, even in skip mode)

  ## Parameters

  - `command` - Shell command string
  - `opts` - Options:
    - `:cwd` - Working directory (for policy context)
    - `:context` - Additional context map for callbacks

  ## Returns

  `%{allowed: bool, reason: string | nil, decision: decision}`
  """
  @spec check(String.t(), keyword()) :: check_result()
  def check(command, opts \\ []) when is_binary(command) do
    cwd = Keyword.get(opts, :cwd)
    context = Keyword.get(opts, :context, %{})

    # Step 1: Always run validator (even in skip mode)
    case Validator.validate(command) do
      {:error, reason} ->
        denied("Command validation failed: #{reason}")

      {:ok, _validated} ->
        # Step 2: Check skip-safety env var (dev/testing only)
        if skip_shell_safety?() do
          Logger.debug("Security: PUP_SKIP_SHELL_SAFETY=1, skipping policy/callbacks")
          allowed()
        else
          # Step 3: PolicyEngine + callback hook chain (via RunShellCommand)
          RunShellCommand.check(command, cwd: cwd, context: context)
        end
    end
  end

  @doc """
  Checks if yolo mode is enabled (skip user confirmation).

  Controlled by `PUP_YOLO_MODE` environment variable.
  """
  @spec yolo_mode?() :: boolean()
  def yolo_mode? do
    System.get_env("PUP_YOLO_MODE") == "1"
  end

  @doc """
  Checks if shell safety checks should be skipped.

  Controlled by `PUP_SKIP_SHELL_SAFETY` environment variable.
  """
  @spec skip_shell_safety?() :: boolean()
  def skip_shell_safety? do
    System.get_env("PUP_SKIP_SHELL_SAFETY") == "1"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp allowed, do: %{allowed: true, reason: nil, decision: :allowed}
  defp denied(reason), do: %{allowed: false, reason: reason, decision: {:denied, reason}}
end
