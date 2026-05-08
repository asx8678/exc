defmodule CodePuppyControl.Callbacks.Triggers do
  @moduledoc """
  Typed `on_*` trigger functions for every declared callback hook.

  Each function provides a Python-compatible API matching the
  `on_<hook>()` pattern from `code_puppy/callbacks.py`. They delegate
  to `Callbacks.trigger/2` or `Callbacks.trigger_async/2` based on
  the hook's declared `async` flag, and return the **merged** result
  according to the hook's declared merge strategy.

  ## Security Hooks

  For security-critical hooks (`file_permission`, `run_shell_command`,
  `pre_tool_call`), use `Callbacks.Security` instead — those wrappers
  enforce fail-closed semantics. The functions here are thin triggers
  that return merged results without security post-processing.

  ## Conventions

  - Sync hooks use `Callbacks.trigger/2`
  - Async hooks use `Callbacks.trigger_async/2`
  - All functions accept the same positional args as the hook signature
  - Return the merged result (or `nil` / `{:ok, nil}` when no callbacks)
  """

  require Logger

  alias CodePuppyControl.Callbacks

  # ── Lifecycle Hooks ──────────────────────────────────────────────

  @doc """
  Triggers `:startup` callbacks (sync, noop merge).

  Called once at application boot. Returns merged results or `nil`.
  """
  @spec on_startup() :: term()
  def on_startup, do: Callbacks.trigger(:startup)

  @doc """
  Triggers `:shutdown` callbacks with reentrancy protection.

  Uses the 3-state shutdown guard (idle → running → complete).
  Returns merged results or `nil` if already running/complete.
  """
  @spec on_shutdown() :: term()
  def on_shutdown, do: Callbacks.trigger_shutdown()

  @doc """
  Triggers `:agent_reload` callbacks (sync, noop merge).

  Called for agent hot-reload scenarios.
  """
  @spec on_agent_reload(agent_module :: term()) :: term()
  def on_agent_reload(agent_module) do
    Callbacks.trigger(:agent_reload, [agent_module])
  end

  # ── Agent Lifecycle Hooks ────────────────────────────────────────

  @doc """
  Triggers `:invoke_agent` callbacks (async, noop merge).

  Called when a sub-agent is invoked.
  """
  @spec on_invoke_agent(args :: term()) :: {:ok, term()} | {:error, :not_async}
  def on_invoke_agent(args) do
    Callbacks.trigger_async(:invoke_agent, [args])
  end

  @doc """
  Triggers `:agent_exception` callbacks (async, noop merge).

  Called on unhandled agent error.
  """
  @spec on_agent_exception(exception :: Exception.t(), args :: term()) ::
          {:ok, term()} | {:error, :not_async}
  def on_agent_exception(exception, args) do
    Callbacks.trigger_async(:agent_exception, [exception, args])
  end

  @doc """
  Triggers `:agent_run_start` callbacks (async, noop merge).

  Called when an agent run starts.
  """
  @spec on_agent_run_start(
          agent_name :: String.t(),
          model_name :: String.t(),
          session_id :: String.t() | nil
        ) ::
          {:ok, term()} | {:error, :not_async}
  def on_agent_run_start(agent_name, model_name, session_id \\ nil) do
    Callbacks.trigger_async(:agent_run_start, [agent_name, model_name, session_id])
  end

  @doc """
  Triggers `:agent_run_end` callbacks (async, noop merge).

  Called when an agent run ends. Arity matches Python's 7-arg contract:
  agent_name, model_name, session_id, success, error, response_text, metadata.
  """
  @spec on_agent_run_end(
          agent_name :: String.t(),
          model_name :: String.t(),
          session_id :: String.t() | nil,
          success :: boolean(),
          error :: Exception.t() | nil,
          response_text :: String.t() | nil,
          metadata :: map() | nil
        ) :: {:ok, term()} | {:error, :not_async}
  def on_agent_run_end(
        agent_name,
        model_name,
        session_id \\ nil,
        success \\ true,
        error \\ nil,
        response_text \\ nil,
        metadata \\ nil
      ) do
    Callbacks.trigger_async(:agent_run_end, [
      agent_name,
      model_name,
      session_id,
      success,
      error,
      response_text,
      metadata
    ])
  end

  # ── Prompt / Config Hooks ────────────────────────────────────────

  @doc """
  Triggers `:load_prompt` callbacks (sync, concat_str merge).

  Each callback returns a string (or nil). Results are concatenated
  with newlines.
  """
  @spec on_load_prompt() :: String.t() | nil
  def on_load_prompt, do: Callbacks.trigger(:load_prompt)

  @doc """
  Triggers `:load_model_config` callbacks (sync, update_map merge).

  Each callback returns a map. Results are deep-merged (later wins).
  """
  @spec on_load_model_config(arg1 :: term(), arg2 :: term()) :: map() | nil
  def on_load_model_config(arg1, arg2) do
    Callbacks.trigger(:load_model_config, [arg1, arg2])
  end

  @doc """
  Triggers `:load_models_config` callbacks (sync, update_map merge).

  Each callback returns a map of model configurations. Results are
  deep-merged (later wins on conflict), matching the Python contract
  where plugins return dicts to be merged with built-in models.
  """
  @spec on_load_models_config() :: map() | nil
  def on_load_models_config, do: Callbacks.trigger(:load_models_config)

  @doc """
  Triggers `:get_model_system_prompt` callbacks with chaining (sync, noop merge).

  Each callback receives the current effective prompt values updated
  from prior results. If a callback returns a map with `instructions`
  and/or `user_prompt`, those values feed into the next callback's args.
  This matches the Python chaining contract where callbacks cooperate
  instead of recomputing from the original prompt independently.

  Return a dict with `instructions`, `user_prompt`, `handled` or nil.
  """
  @spec on_get_model_system_prompt(
          model_name :: String.t(),
          default_prompt :: String.t(),
          user_prompt :: String.t()
        ) ::
          term()
  def on_get_model_system_prompt(model_name, default_prompt, user_prompt) do
    Callbacks.trigger_chained(
      :get_model_system_prompt,
      [model_name, default_prompt, user_prompt],
      instructions: 1,
      user_prompt: 2
    )
  end

  # ── File Mutation Observer Hooks ─────────────────────────────────

  @doc "Triggers `:edit_file` callbacks (sync, noop merge)."
  @spec on_edit_file(args :: term()) :: term()
  def on_edit_file(args), do: Callbacks.trigger(:edit_file, [args])

  @doc "Triggers `:create_file` callbacks (sync, noop merge)."
  @spec on_create_file(args :: term()) :: term()
  def on_create_file(args), do: Callbacks.trigger(:create_file, [args])

  @doc "Triggers `:replace_in_file` callbacks (sync, noop merge)."
  @spec on_replace_in_file(args :: term()) :: term()
  def on_replace_in_file(args), do: Callbacks.trigger(:replace_in_file, [args])

  @doc "Triggers `:delete_snippet` callbacks (sync, noop merge)."
  @spec on_delete_snippet(args :: term()) :: term()
  def on_delete_snippet(args), do: Callbacks.trigger(:delete_snippet, [args])

  @doc "Triggers `:delete_file` callbacks (sync, noop merge)."
  @spec on_delete_file(args :: term()) :: term()
  def on_delete_file(args), do: Callbacks.trigger(:delete_file, [args])

  # ── Custom Command Hooks ────────────────────────────────────────

  @doc """
  Triggers `:custom_command` callbacks (sync, noop merge).

  Implementations may return:
  - `true` — command was handled
  - A string — to be processed as user input
  - `nil` — not handled
  """
  @spec on_custom_command(command :: String.t(), name :: String.t()) :: term()
  def on_custom_command(command, name) do
    Callbacks.trigger(:custom_command, [command, name])
  end

  @doc """
  Triggers `:custom_command_help` callbacks (sync, extend_list merge).

  Each callback returns a list of `{name, description}` tuples.
  """
  @spec on_custom_command_help() :: list() | nil
  def on_custom_command_help, do: Callbacks.trigger(:custom_command_help)

  # ── Tool Call Hooks ──────────────────────────────────────────────

  @doc """
  Triggers `:pre_tool_call` callbacks (async, noop merge).

  For fail-closed behavior, use `Callbacks.Security.on_pre_tool_call/3`.
  """
  @spec on_pre_tool_call(tool_name :: String.t(), tool_args :: map(), context :: term()) ::
          {:ok, term()} | {:error, :not_async}
  def on_pre_tool_call(tool_name, tool_args, context \\ nil) do
    Callbacks.trigger_async(:pre_tool_call, [tool_name, tool_args, context])
  end

  @doc """
  Triggers `:post_tool_call` callbacks (async, noop merge).

  Called after a tool completes execution.
  """
  @spec on_post_tool_call(
          tool_name :: String.t(),
          tool_args :: map(),
          result :: term(),
          duration_ms :: number(),
          context :: term()
        ) :: {:ok, term()} | {:error, :not_async}
  def on_post_tool_call(tool_name, tool_args, result, duration_ms, context \\ nil) do
    Callbacks.trigger_async(:post_tool_call, [tool_name, tool_args, result, duration_ms, context])
  end

  # ── Stream / Event Hooks ────────────────────────────────────────

  @doc """
  Triggers `:stream_event` callbacks (async, noop merge).

  Reacts to streaming events in real-time.
  """
  @spec on_stream_event(
          event_type :: String.t(),
          event_data :: term(),
          agent_session_id :: String.t() | nil
        ) ::
          {:ok, term()} | {:error, :not_async}
  def on_stream_event(event_type, event_data, agent_session_id \\ nil) do
    Callbacks.trigger_async(:stream_event, [event_type, event_data, agent_session_id])
  end

  @doc """
  Triggers `:version_check` callbacks (async, noop merge).

  Checks for version updates.
  """
  @spec on_version_check(arg :: term()) :: {:ok, term()} | {:error, :not_async}
  def on_version_check(arg) do
    Callbacks.trigger_async(:version_check, [arg])
  end

  # ── Registration Hooks ──────────────────────────────────────────

  @doc """
  Triggers `:register_tools` callbacks (sync, extend_list merge).

  Each callback returns `[%{name: str, register_func: fun}]`.
  """
  @spec on_register_tools() :: list() | nil
  def on_register_tools, do: Callbacks.trigger(:register_tools)

  @doc """
  Triggers `:register_agents` callbacks (sync, extend_list merge).

  Each callback returns `[%{name: str, class: type}]`.
  """
  @spec on_register_agents() :: list() | nil
  def on_register_agents, do: Callbacks.trigger(:register_agents)

  @doc """
  Triggers `:register_model_type` callbacks (sync, extend_list merge).

  Each callback returns `[%{type: str, handler: fun}]`.
  """
  @spec on_register_model_type() :: list() | nil
  def on_register_model_type, do: Callbacks.trigger(:register_model_type)

  @doc """
  Python-compatible alias for `on_register_model_type/0`.

  The Python API uses `on_register_model_types()` (plural) while the
  hook name is `:register_model_type` (singular). This alias bridges
  the naming gap so Python-oriented plugins can use the familiar name.

  Each callback returns `[%{type: str, handler: fun}]`.
  """
  @spec on_register_model_types() :: list() | nil
  def on_register_model_types, do: on_register_model_type()

  @doc """
  Triggers `:register_mcp_catalog_servers` callbacks (sync, extend_list merge).

  Each callback returns a list of MCP server templates.
  """
  @spec on_register_mcp_catalog_servers() :: list() | nil
  def on_register_mcp_catalog_servers, do: Callbacks.trigger(:register_mcp_catalog_servers)

  @doc """
  Triggers `:register_browser_types` callbacks (sync, extend_list merge).

  Each callback returns a list of browser type provider registrations.
  """
  @spec on_register_browser_types() :: list() | nil
  def on_register_browser_types, do: Callbacks.trigger(:register_browser_types)

  @doc """
  Triggers `:register_model_providers` callbacks (sync, extend_list merge).

  Each callback returns a list of model provider registrations.
  """
  @spec on_register_model_providers() :: list() | nil
  def on_register_model_providers, do: Callbacks.trigger(:register_model_providers)

  @doc """
  Triggers `:get_motd` callbacks (sync, extend_list merge).

  Each callback returns `{message, version}` or nil.
  """
  @spec on_get_motd() :: list() | nil
  def on_get_motd, do: Callbacks.trigger(:get_motd)

  # ── Security Hooks (thin trigger — no fail-closed) ──────────────
  # Use Callbacks.Security for fail-closed wrappers

  @doc """
  Triggers `:file_permission` callbacks (async, or_bool merge).

  **WARNING:** This uses the hook's declared merge strategy (`:or_bool`).
  For fail-closed security checks, use `Callbacks.Security.on_file_permission/6`
  or `Callbacks.FilePermission.check/7` instead.
  """
  @spec on_file_permission(
          context :: term(),
          file_path :: String.t(),
          operation :: String.t(),
          preview :: String.t() | nil,
          message_group :: String.t() | nil,
          operation_data :: term()
        ) :: {:ok, term()} | {:error, :not_async}
  def on_file_permission(
        context,
        file_path,
        operation,
        preview \\ nil,
        message_group \\ nil,
        operation_data \\ nil
      ) do
    Callbacks.trigger_async(:file_permission, [
      context,
      file_path,
      operation,
      preview,
      message_group,
      operation_data
    ])
  end

  @doc """
  Triggers `:run_shell_command` callbacks (async, noop merge).

  **WARNING:** This is a thin trigger without fail-closed semantics.
  For security checks, use `Callbacks.Security.on_run_shell_command/3`
  or `Callbacks.RunShellCommand.check/2` instead.
  """
  @spec on_run_shell_command(context :: term(), command :: String.t(), cwd :: String.t() | nil) ::
          {:ok, term()} | {:error, :not_async}
  def on_run_shell_command(context, command, cwd \\ nil) do
    Callbacks.trigger_async(:run_shell_command, [context, command, cwd])
  end

  # ── Message History Processor Hooks ─────────────────────────────

  @doc """
  Triggers `:message_history_processor_start` callbacks (async, noop merge).

  Called before message history processing begins.
  """
  @spec on_message_history_processor_start(
          agent_name :: String.t(),
          session_id :: String.t() | nil,
          message_history :: list(),
          incoming_messages :: list()
        ) :: {:ok, term()} | {:error, :not_async}
  def on_message_history_processor_start(
        agent_name,
        session_id,
        message_history,
        incoming_messages
      ) do
    Callbacks.trigger_async(:message_history_processor_start, [
      agent_name,
      session_id,
      message_history,
      incoming_messages
    ])
  end

  @doc """
  Triggers `:message_history_processor_end` callbacks (async, noop merge).

  Called after message history processing completes.
  """
  @spec on_message_history_processor_end(
          agent_name :: String.t(),
          session_id :: String.t() | nil,
          message_history :: list(),
          messages_added :: non_neg_integer(),
          messages_filtered :: non_neg_integer()
        ) :: {:ok, term()} | {:error, :not_async}
  def on_message_history_processor_end(
        agent_name,
        session_id,
        message_history,
        messages_added,
        messages_filtered
      ) do
    Callbacks.trigger_async(:message_history_processor_end, [
      agent_name,
      session_id,
      message_history,
      messages_added,
      messages_filtered
    ])
  end
end
