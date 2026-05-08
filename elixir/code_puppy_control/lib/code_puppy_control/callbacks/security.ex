defmodule CodePuppyControl.Callbacks.Security do
  @moduledoc """
  Fail-closed security trigger wrappers for callback hooks.

  These functions mirror the Python `on_file_permission`, `on_file_permission_async`,
  `on_run_shell_command`, and `on_pre_tool_call` trigger functions that enforce
  fail-closed semantics: if a security callback crashes, the operation is **denied**.

  ## Fail-Closed Semantics

  When a security callback raises an exception or returns `:callback_failed`,
  the operation is unconditionally denied. This prevents security failures from
  being silently swallowed by merge semantics or nil filtering.

  ## Relationship to Full Security Pipeline

  These functions are the **trigger layer** — they fire callbacks and enforce
  fail-closed on results. The full security pipeline (PolicyEngine + callbacks)
  is in `Callbacks.FilePermission` and `Callbacks.RunShellCommand`.

  ## Hook Signatures

  - `:file_permission` — arity 6: `fn context, file_path, operation, preview, message_group, operation_data -> bool | nil`
  - `:run_shell_command` — arity 3: `fn context, command, cwd -> %{blocked: bool} | nil`
  - `:pre_tool_call` — arity 3: `fn tool_name, tool_args, context -> any | nil`

  Refs: code_puppy-154.6 (Phase F port)
  """

  require Logger

  alias CodePuppyControl.Callbacks

  # ── File Permission ──────────────────────────────────────────────

  @doc """
  Triggers `:file_permission` callbacks with fail-closed semantics.

  Uses `trigger_raw/2` to preserve `:callback_failed` sentinels.
  Any crashed callback (returning `:callback_failed`) is treated as
  a denial (returns `false`), matching Python's behavior.

  Returns a list of security results where each element is:
  - `true` / `false` — explicit allow/deny
  - `nil` — abstain (no opinion)
  - `%Allow{}` / `%Deny{}` — typed decision

  ## Fail-Closed

  If a callback raises, `:callback_failed` appears in raw results
  and is replaced with `false` (deny). This matches the Python
  `on_file_permission` behavior.
  """
  @spec on_file_permission(
          context :: term(),
          file_path :: String.t(),
          operation :: String.t(),
          preview :: String.t() | nil,
          message_group :: String.t() | nil,
          operation_data :: term()
        ) :: [term()]
  def on_file_permission(
        context,
        file_path,
        operation,
        preview \\ nil,
        message_group \\ nil,
        operation_data \\ nil
      ) do
    # Backward compat: if operation_data provided, prefer it over preview
    effective_preview = if operation_data != nil, do: nil, else: preview

    results =
      Callbacks.trigger_raw(
        :file_permission,
        [context, file_path, operation, effective_preview, message_group, operation_data]
      )

    # Replace :callback_failed with false for fail-closed
    Enum.map(results, fn
      :callback_failed ->
        Logger.warning(
          "Security callback for file_permission failed with exception; " <>
            "denying #{operation} on #{file_path} (fail-closed)"
        )

        false

      {:callback_failed, reason} ->
        Logger.warning(
          "Security callback for file_permission failed: #{inspect(reason)}; " <>
            "denying #{operation} on #{file_path} (fail-closed)"
        )

        false

      other ->
        other
    end)
  end

  @doc """
  Async variant of `on_file_permission/6` with fail-closed semantics.

  Fires callbacks via `trigger_raw_async/2` and then applies the same
  fail-closed replacement: `:callback_failed` → `false`.
  Uses `trigger_raw_async` (not `trigger_async`) to preserve
  `:callback_failed` sentinels that merge semantics would filter out.
  """
  @spec on_file_permission_async(
          context :: term(),
          file_path :: String.t(),
          operation :: String.t(),
          preview :: String.t() | nil,
          message_group :: String.t() | nil,
          operation_data :: term()
        ) :: {:ok, [term()]} | {:error, :not_async}
  def on_file_permission_async(
        context,
        file_path,
        operation,
        preview \\ nil,
        message_group \\ nil,
        operation_data \\ nil
      ) do
    effective_preview = if operation_data != nil, do: nil, else: preview

    case Callbacks.trigger_raw_async(
           :file_permission,
           [context, file_path, operation, effective_preview, message_group, operation_data]
         ) do
      {:ok, results} when is_list(results) ->
        {:ok, apply_file_permission_fail_closed(results, operation, file_path)}

      {:error, _} = err ->
        err
    end
  end

  defp apply_file_permission_fail_closed(results, operation, file_path) do
    Enum.map(results, fn
      :callback_failed ->
        Logger.warning(
          "Security callback for file_permission failed with exception; " <>
            "denying #{operation} on #{file_path} (fail-closed)"
        )

        false

      {:callback_failed, reason} ->
        Logger.warning(
          "Security callback for file_permission failed: #{inspect(reason)}; " <>
            "denying #{operation} on #{file_path} (fail-closed)"
        )

        false

      other ->
        other
    end)
  end

  # ── Run Shell Command ───────────────────────────────────────────

  @doc """
  Triggers `:run_shell_command` callbacks with fail-closed semantics.

  Uses `trigger_raw/2` to preserve `:callback_failed` sentinels.
  Any crashed callback is treated as a denial (returns `%{blocked: true}`),
  matching Python's behavior.

  Returns a list of security results where each element is:
  - `%{blocked: true}` — block the command
  - `%{blocked: false}` / `nil` — no objection
  - `%Deny{}` — block with reason

  ## Fail-Closed

  If a callback raises, `:callback_failed` appears in raw results
  and is replaced with `%{blocked: true}`. This matches Python's
  `on_run_shell_command` behavior.
  """
  @spec on_run_shell_command(context :: term(), command :: String.t(), cwd :: String.t() | nil) ::
          [term()]
  def on_run_shell_command(context, command, cwd \\ nil) do
    results = Callbacks.trigger_raw(:run_shell_command, [context, command, cwd])

    Enum.map(results, fn
      :callback_failed ->
        Logger.warning(
          "Security callback for run_shell_command failed with exception; " <>
            "denying command (fail-closed)"
        )

        %{blocked: true}

      {:callback_failed, reason} ->
        Logger.warning(
          "Security callback for run_shell_command failed: #{inspect(reason)}; " <>
            "denying command (fail-closed)"
        )

        %{blocked: true}

      other ->
        other
    end)
  end

  # ── Pre Tool Call ────────────────────────────────────────────────

  @doc """
  Triggers `:pre_tool_call` callbacks with fail-closed semantics.

  Uses `trigger_raw/2` to preserve `:callback_failed` sentinels.
  Any crashed callback is treated as a denial, matching Python's behavior.

  Returns a list of security results. If a callback raises,
  `:callback_failed` is replaced with `%{blocked: true, reason: "Security check failed"}`.

  ## Fail-Closed

  If a security callback crashes, the tool call is blocked.
  """
  @spec on_pre_tool_call(tool_name :: String.t(), tool_args :: map(), context :: term()) :: [
          term()
        ]
  def on_pre_tool_call(tool_name, tool_args, context \\ nil) do
    results = Callbacks.trigger_raw(:pre_tool_call, [tool_name, tool_args, context])

    Enum.map(results, fn
      :callback_failed ->
        Logger.warning(
          "Security callback for pre_tool_call failed with exception; " <>
            "denying tool #{tool_name} (fail-closed)"
        )

        %{blocked: true, reason: "Security check failed"}

      {:callback_failed, reason} ->
        Logger.warning(
          "Security callback for pre_tool_call failed: #{inspect(reason)}; " <>
            "denying tool #{tool_name} (fail-closed)"
        )

        %{blocked: true, reason: "Security check failed: #{inspect(reason)}"}

      other ->
        other
    end)
  end

  # ── Post Tool Call ──────────────────────────────────────────────

  @doc """
  Triggers `:post_tool_call` callbacks.

  Post-tool callbacks are NOT security-critical — they observe results
  after execution. No fail-closed replacement is needed. Uses
  `trigger_raw/2` for consistency but `:callback_failed` is simply
  preserved in results (not treated as denial).
  """
  @spec on_post_tool_call(
          tool_name :: String.t(),
          tool_args :: map(),
          result :: term(),
          duration_ms :: number(),
          context :: term()
        ) :: [term()]
  def on_post_tool_call(tool_name, tool_args, result, duration_ms, context \\ nil) do
    Callbacks.trigger_raw(:post_tool_call, [tool_name, tool_args, result, duration_ms, context])
  end

  # ── Utility ──────────────────────────────────────────────────────

  @doc """
  Checks if any result in a list indicates a blocked/denied operation.

  Useful after calling `on_file_permission/6` or `on_run_shell_command/3`
  to determine the overall security decision.
  """
  @spec any_denied?([term()]) :: boolean()
  def any_denied?(results) when is_list(results) do
    Enum.any?(results, fn
      false -> true
      :callback_failed -> true
      {:callback_failed, _} -> true
      %{blocked: true} -> true
      %CodePuppyControl.PolicyEngine.PolicyRule.Deny{} -> true
      _ -> false
    end)
  end
end
