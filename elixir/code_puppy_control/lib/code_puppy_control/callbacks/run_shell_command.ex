defmodule CodePuppyControl.Callbacks.RunShellCommand do
  @moduledoc """
  Shell command permission callback chain with fail-closed semantics.

  Combines PolicyEngine rules and the `:run_shell_command` callback hook
  to make permission decisions for shell command execution.

  ## Pipeline

  1. **PolicyEngine** — `check_shell_command/2` for the command. Handles
     compound commands (`&&`, `||`, `;`) by splitting and checking each
     sub-command, returning the most restrictive decision.
  2. **Callback hook** — `Callbacks.trigger_raw(:run_shell_command, ...)`
     fires all registered plugin callbacks. Results are inspected for
     blocks or crashes.
  3. **Fail-closed** — Any callback that crashes, returns `%{blocked: true}`,
     `:callback_failed`, or a `%Deny{}` is treated as a denial.

  ## Hook Signature

  The `:run_shell_command` callback hook expects arity 3:

      fn context, command, cwd ->
        %{blocked: true} | %{blocked: false} | nil | %Deny{}
      end

  - `%{blocked: true}` — Block the command
  - `%{blocked: false}` / `nil` — No objection
  - `%Deny{}` — Block with reason

  Any callback returning `:callback_failed` (crash sentinel) is treated
  as a denial per fail-closed semantics.

  ## Security

  If the PolicyEngine is unavailable, the command is **denied**
  (fail-closed). This prevents accidental execution of unsafe commands
  when security infrastructure is degraded.

  ## Relationship to CommandRunner.Security

  This module provides the policy + callback portion of the security
  pipeline. `CommandRunner.Security` wraps it with additional layers
  (validator, env-var bypass, etc.).

  Refs: code_puppy-mmk.3 (Phase E port)
  """

  require Logger

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule.{Allow, Deny, AskUser}

  @typedoc """
  Full security check result map.

  Matches the shape returned by `CommandRunner.Security.check/2`.
  """
  @type check_result :: %{
          allowed: boolean(),
          reason: String.t() | nil,
          decision: :allowed | {:denied, String.t()} | {:ask_user, String.t()}
        }

  @doc """
  Performs the policy + callback security check for a shell command.

  This covers steps 2–3 of the full security pipeline (PolicyEngine
  and callback hooks). Command validation and env-var bypass are
  handled by the caller (typically `CommandRunner.Security`).

  ## Parameters

    - `command` — Shell command string (may contain `&&`, `||`, `;`)
    - `opts`    — Options:
      - `:cwd`     — Working directory (for policy context)
      - `:context` — Additional context map for callbacks

  ## Returns

  A result map matching `CommandRunner.Security.check/2` output:

      %{allowed: true, reason: nil, decision: :allowed}
      %{allowed: false, reason: "...", decision: {:denied, "..."}}
      %{allowed: false, reason: "...", decision: {:ask_user, "..."}}

  ## Examples

      iex> RunShellCommand.check("echo hello", cwd: "/tmp")
      %{allowed: true, reason: nil, decision: :allowed}

      iex> RunShellCommand.check("rm -rf /", cwd: "/tmp")
      %{allowed: false, reason: "Denied by policy", decision: {:denied, "Denied by policy"}}
  """
  @spec check(String.t(), keyword()) :: check_result()
  def check(command, opts \\ []) when is_binary(command) do
    cwd = Keyword.get(opts, :cwd)
    context = Keyword.get(opts, :context, %{})

    # Step 1: PolicyEngine check (handles compound commands)
    case policy_check(command, cwd) do
      {:denied, reason} ->
        denied(reason)

      {:ask_user, prompt} ->
        # Policy says ask — run callbacks; they can override to deny
        case callback_check(command, cwd, context) do
          {:denied, reason} -> denied(reason)
          _ -> %{allowed: false, reason: prompt, decision: {:ask_user, prompt}}
        end

      :allowed ->
        # Policy allows — run callbacks; they can still deny
        case callback_check(command, cwd, context) do
          {:denied, reason} -> denied(reason)
          :allowed -> allowed()
        end
    end
  end

  # ── PolicyEngine Integration ──────────────────────────────────────────────

  @spec policy_check(String.t(), String.t() | nil) ::
          :allowed | {:denied, String.t()} | {:ask_user, String.t()}
  defp policy_check(command, cwd) do
    try do
      case PolicyEngine.check_shell_command(command, cwd) do
        %Allow{} -> :allowed
        %Deny{reason: reason} -> {:denied, reason || "Denied by policy"}
        %AskUser{prompt: prompt} -> {:ask_user, prompt || "Confirm command execution"}
      end
    rescue
      e ->
        Logger.error("RunShellCommand: PolicyEngine check failed: #{Exception.message(e)}")
        # Fail-closed: deny on error
        {:denied, "Security check failed (fail-closed)"}
    catch
      :exit, reason ->
        Logger.error("RunShellCommand: PolicyEngine unavailable: #{inspect(reason)}")
        {:denied, "Security check unavailable (fail-closed)"}
    end
  end

  # ── Callback Hook Integration ─────────────────────────────────────────────

  @spec callback_check(String.t(), String.t() | nil, map()) ::
          :allowed | {:denied, String.t()}
  defp callback_check(command, cwd, context) do
    try do
      # Use trigger_raw to get unmerged results list.
      # This is critical for fail-closed: the :noop merge used by trigger/2
      # can silently discard :callback_failed sentinels when mixed
      # with nil or %{blocked: false} results (code_puppy-mmk.6 regression).
      results = Callbacks.trigger_raw(:run_shell_command, [context, command, cwd])

      # Fail-closed: any callback returning :callback_failed or
      # {:callback_failed, _} is treated as a denial — we cannot
      # determine the callback's intent, so we deny to be safe.
      blocked =
        Enum.any?(results, fn
          %{blocked: true} -> true
          :callback_failed -> true
          {:callback_failed, _} -> true
          %Deny{} -> true
          false -> true
          _ -> false
        end)

      if blocked do
        {:denied, "Command blocked by security plugin"}
      else
        :allowed
      end
    rescue
      e ->
        Logger.warning("RunShellCommand: callback check raised: #{Exception.message(e)}")
        # Fail-closed: callback errors deny execution
        {:denied, "Security callback failed (fail-closed)"}
    catch
      :exit, reason ->
        Logger.warning("RunShellCommand: callback check crashed: #{inspect(reason)}")
        # Fail-closed: callback crashes deny execution
        {:denied, "Security callback crashed (fail-closed)"}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp allowed, do: %{allowed: true, reason: nil, decision: :allowed}

  defp denied(reason),
    do: %{allowed: false, reason: reason, decision: {:denied, reason}}
end
