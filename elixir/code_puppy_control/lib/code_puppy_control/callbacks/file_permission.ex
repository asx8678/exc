defmodule CodePuppyControl.Callbacks.FilePermission do
  @moduledoc """
  File permission callback chain with fail-closed semantics.

  Combines PolicyEngine rules and the `:file_permission` callback hook
  to make permission decisions for file operations.

  ## Pipeline

  1. **PolicyEngine** — `check/2` for the tool name (derived from
     `operation`). If a rule matches, its decision is returned
     immediately. If no rule matches, the default decision (typically
     `:ask_user`) is returned, ensuring fail-closed behavior.
  2. **Callback hook** — `Callbacks.trigger_raw(:file_permission, ...)`
     fires all registered plugin callbacks. Results are inspected for
     denials or crashes.
  3. **Fail-closed** — Any callback that crashes, returns `false`,
     `:callback_failed`, or a `%Deny{}` is treated as a denial.

  ## Hook Signature

  The `:file_permission` callback hook expects arity 6:

      fn context, file_path, operation, preview, message_group, operation_data ->
        true | false | nil | %Allow{} | %Deny{}
      end

  - `true`  — Explicitly allow (does NOT override other denials)
  - `false` — Explicitly deny
  - `nil`   — No opinion (abstain)
  - `%Deny{}` — Explicitly deny with reason
  - `%Allow{}` — Explicitly allow

  Any callback returning `:callback_failed` or `{:callback_failed, _}`
  (crash sentinels) is treated as a denial per fail-closed semantics.

  ## Security

  If the PolicyEngine is unavailable, the operation is **denied**
  (fail-closed). This prevents accidental execution of unsafe file
  operations when security infrastructure is degraded.

  Refs: code_puppy-mmk.3 (Phase E port)
  """

  require Logger

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule.{Allow, Deny, AskUser}

  @type permission_decision :: Allow.t() | Deny.t() | AskUser.t()

  @doc """
  Checks file operation permission through the full pipeline.

  Combines PolicyEngine rules and callback hooks with fail-closed
  semantics.

  ## Parameters

    - `context`        — Operation context map (e.g. run_id, agent_module)
    - `file_path`      — Path to the file being operated on
    - `operation`      — Operation verb (e.g. "create", "read", "write", "delete")
    - `preview`        — Optional preview of changes (deprecated; use operation_data)
    - `message_group`  — Optional message group identifier
    - `operation_data` — Operation-specific data for preview generation

  ## Options (via the final keyword list)

    - `:tool_name` — Override the tool name sent to PolicyEngine.
      Defaults to `"\#{operation}_file"` (e.g. "create_file").

  ## Returns

    - `%Allow{}`   — Operation is permitted
    - `%Deny{}`     — Operation is denied
    - `%AskUser{}` — Decision deferred to user

  ## Examples

      iex> FilePermission.check(%{}, "lib/foo.ex", "create")
      %AskUser{prompt: "Policy requires user approval"}

      iex> FilePermission.check(%{}, "/etc/passwd", "read")
      %Deny{reason: "Denied by policy (rule from user)"}
  """
  @spec check(
          context :: map(),
          file_path :: String.t(),
          operation :: String.t(),
          preview :: String.t() | nil,
          message_group :: String.t() | nil,
          operation_data :: term(),
          opts :: keyword()
        ) :: permission_decision()
  def check(
        context,
        file_path,
        operation,
        preview \\ nil,
        message_group \\ nil,
        operation_data \\ nil,
        opts \\ []
      )
      when is_binary(file_path) and is_binary(operation) do
    tool_name = Keyword.get(opts, :tool_name, "#{operation}_file")

    # Step 1: PolicyEngine explicit check
    case policy_check(tool_name, file_path, operation) do
      %Deny{} = deny ->
        deny

      %AskUser{} = ask ->
        # Policy says ask — run callbacks; they can override to deny
        case callback_check(context, file_path, operation, preview, message_group, operation_data) do
          {:denied, reason} -> %Deny{reason: reason}
          :allowed -> ask
        end

      %Allow{} ->
        # Policy allows — run callbacks; they can still deny
        case callback_check(context, file_path, operation, preview, message_group, operation_data) do
          {:denied, reason} -> %Deny{reason: reason}
          :allowed -> %Allow{}
        end
    end
  end

  # ── PolicyEngine Integration ──────────────────────────────────────────────

  @spec policy_check(String.t(), String.t(), String.t()) :: permission_decision()
  defp policy_check(tool_name, file_path, operation) do
    args = %{"file_path" => file_path, "operation" => operation}

    try do
      case PolicyEngine.check(tool_name, args) do
        %Allow{} = allow -> allow
        %Deny{reason: reason} -> %Deny{reason: reason || "Denied by policy"}
        %AskUser{prompt: prompt} -> %AskUser{prompt: prompt || "Confirm file operation"}
      end
    rescue
      e ->
        Logger.error("FilePermission: PolicyEngine check failed: #{Exception.message(e)}")
        # Fail-closed: deny on error
        %Deny{reason: "Security check failed (fail-closed)"}
    catch
      :exit, reason ->
        Logger.error("FilePermission: PolicyEngine unavailable: #{inspect(reason)}")
        %Deny{reason: "Security check unavailable (fail-closed)"}
    end
  end

  # ── Callback Hook Integration ─────────────────────────────────────────────

  @spec callback_check(
          map(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          term()
        ) :: {:denied, String.t()} | :allowed
  defp callback_check(context, file_path, operation, preview, message_group, operation_data) do
    # For backward compatibility: if operation_data is provided, prefer it over preview
    effective_preview = if operation_data != nil, do: nil, else: preview

    try do
      # Use trigger_raw to get unmerged results list.
      # This is critical for fail-closed: the :noop merge in trigger/2
      # can silently discard :callback_failed sentinels when mixed
      # with nil or true results.
      results =
        Callbacks.trigger_raw(
          :file_permission,
          [context, file_path, operation, effective_preview, message_group, operation_data]
        )

      # Fail-closed: any result indicating denial or failure blocks the operation.
      # Result types from callbacks:
      #   true / %Allow{} — allow
      #   false / %Deny{} — deny
      #   nil — no opinion (abstain)
      #   :callback_failed — crash sentinel → deny
      # Fail-closed: any callback returning :callback_failed or
      # {:callback_failed, _} is treated as a denial — we cannot
      # determine the callback's intent, so we deny to be safe.
      # This matches RunShellCommand's fail-closed handling.
      blocked =
        Enum.any?(results, fn
          false -> true
          :callback_failed -> true
          {:callback_failed, _} -> true
          %Deny{} -> true
          _ -> false
        end)

      if blocked do
        {:denied, "File operation blocked by security plugin"}
      else
        :allowed
      end
    rescue
      e ->
        Logger.warning("FilePermission: callback check raised: #{Exception.message(e)}")
        # Fail-closed: callback errors deny execution
        {:denied, "Security callback failed (fail-closed)"}
    catch
      :exit, reason ->
        Logger.warning("FilePermission: callback check crashed: #{inspect(reason)}")
        # Fail-closed: callback crashes deny execution
        {:denied, "Security callback crashed (fail-closed)"}
    end
  end
end
