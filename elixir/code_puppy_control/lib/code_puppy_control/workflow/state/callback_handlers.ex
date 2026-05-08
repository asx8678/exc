defmodule CodePuppyControl.Workflow.State.CallbackHandlers do
  @moduledoc """
  Callback handlers that auto-set workflow flags based on tool calls,
  agent lifecycle, and shell commands.

  ## Async-Safe Design (code-puppy-ctj.3)

  All callback handlers derive their run key explicitly from callback
  arguments (session_id, context map) rather than relying on the
  process dictionary. This is critical because `Callbacks.trigger_async/2`
  spawns Tasks that do NOT inherit the caller's process dictionary.

  Run key derivation strategy per callback:

  | Callback | Run Key Source |
  |----------|---------------|
  | `agent_run_start` | `session_id` (or generated unique key) |
  | `agent_run_end` | `session_id` (looked up from session index) |
  | `pre_tool_call` | `context[:session_id]` or `"default"` |
  | `run_shell_command` | `context[:session_id]` or `"default"` |
  | `delete_file` | `context[:session_id]` or `"default"` |
  """

  require Logger

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Workflow.State.RunKey
  alias CodePuppyControl.Workflow.State.Store

  # ── Callback Handler Functions ──────────────────────────────────────

  @doc false
  def on_delete_file(context) do
    run_key = RunKey.derive_run_key(context: context)
    Store.set_flag(:did_delete_file, run_key: run_key)
  end

  @doc false
  def on_run_shell_command(context, command, _cwd) do
    run_key = RunKey.derive_run_key(context: context)

    Store.set_flag(:did_execute_shell, run_key: run_key)

    cmd_lower = if is_binary(command), do: String.downcase(command), else: ""

    # Track specific tool usage
    if String.contains?(cmd_lower, "test") or String.contains?(cmd_lower, "pytest") do
      Store.set_flag(:did_run_tests, run_key: run_key)
    end

    if String.contains?(cmd_lower, "lint") or
         String.contains?(cmd_lower, "flake8") or
         String.contains?(cmd_lower, "pylint") or
         String.contains?(cmd_lower, "ruff") do
      Store.set_flag(:did_check_lint, run_key: run_key)
    end
  end

  @doc false
  def on_agent_run_start(agent_name, model_name, session_id) do
    # Derive run key from session_id (or generate a unique one).
    # This is safe for async callbacks — no process dictionary needed.
    run_key =
      case session_id do
        nil -> "run_#{:erlang.unique_integer([:positive])}"
        sid -> to_string(sid)
      end

    # Register in the session index so agent_run_end can look it up
    if is_binary(session_id) and session_id != "" do
      RunKey.register_session(session_id, run_key)
    end

    # Initialize the run state under this key
    Store.reset(run_key: run_key)
    Store.put_metadata("agent_name", agent_name, run_key: run_key)
    Store.put_metadata("model_name", model_name, run_key: run_key)
  end

  @doc false
  def on_agent_run_end(
        agent_name,
        model_name,
        session_id,
        success,
        error,
        _response_text,
        _metadata
      ) do
    _ = {agent_name, model_name, error}

    # Look up run key from session index (set by on_agent_run_start)
    run_key =
      case session_id do
        nil ->
          RunKey.default_run_key()

        sid when is_binary(sid) ->
          case RunKey.lookup_session(sid) do
            {:ok, key} -> key
            :error -> sid
          end

        _ ->
          RunKey.default_run_key()
      end

    if not success do
      Store.set_flag(:did_encounter_error, run_key: run_key)
    end

    Store.put_metadata("end_time", System.system_time(:second), run_key: run_key)
    Store.put_metadata("success", success, run_key: run_key)

    # Clean up session index
    if is_binary(session_id) and session_id != "" do
      RunKey.unregister_session(session_id)
    end
  end

  @doc false
  def on_pre_tool_call(tool_name, _tool_args, context) do
    # Derive run key from context (which should contain session_id from
    # the agent runner). Falls back to "default" for legacy callers.
    run_key = RunKey.derive_run_key(context: context)
    tool_name_str = if is_atom(tool_name), do: Atom.to_string(tool_name), else: tool_name

    # Track context loading
    if tool_name_str in ["read_file", "list_files", "grep", "search_files"] do
      Store.set_flag(:did_load_context, run_key: run_key)
    end

    # Track shell execution
    if tool_name_str == "agent_run_shell_command" do
      Store.set_flag(:did_execute_shell, run_key: run_key)
    end

    # Track file creation
    if tool_name_str == "create_file" do
      Store.set_flag(:did_create_file, run_key: run_key)
      Store.set_flag(:did_generate_code, run_key: run_key)
    end

    # Track file editing
    if tool_name_str in ["replace_in_file", "delete_snippet", "edit_file"] do
      Store.set_flag(:did_edit_file, run_key: run_key)
      Store.set_flag(:did_generate_code, run_key: run_key)
    end

    # Track API calls
    if tool_name_str in ["invoke_agent"] do
      Store.set_flag(:did_make_api_call, run_key: run_key)
    end
  end

  # ── Registration ────────────────────────────────────────────────────

  @doc """
  Register handlers for existing callbacks to auto-set workflow flags.

  This wires the workflow state into the callback system so that
  flags are set automatically based on tool calls, agent lifecycle,
  and shell commands. Call this during application startup or plugin init.
  """
  @spec register_callback_handlers() :: :ok
  def register_callback_handlers do
    Callbacks.register(:delete_file, &on_delete_file/1)
    Callbacks.register(:run_shell_command, &on_run_shell_command/3)
    Callbacks.register(:agent_run_start, &on_agent_run_start/3)
    Callbacks.register(:agent_run_end, &on_agent_run_end/7)
    Callbacks.register(:pre_tool_call, &on_pre_tool_call/3)

    Logger.debug("Workflow.State callback handlers registered")
    :ok
  end

  @doc """
  Unregister all workflow state callback handlers.

  Useful for test teardown or clean shutdown.
  """
  @spec unregister_callback_handlers() :: :ok
  def unregister_callback_handlers do
    Callbacks.unregister(:delete_file, &on_delete_file/1)
    Callbacks.unregister(:run_shell_command, &on_run_shell_command/3)
    Callbacks.unregister(:agent_run_start, &on_agent_run_start/3)
    Callbacks.unregister(:agent_run_end, &on_agent_run_end/7)
    Callbacks.unregister(:pre_tool_call, &on_pre_tool_call/3)

    Logger.debug("Workflow.State callback handlers unregistered")
    :ok
  end
end
