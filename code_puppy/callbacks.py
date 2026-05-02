import asyncio
import logging
import threading
import traceback
import weakref
from collections.abc import Callable
from typing import Any, Literal

from code_puppy import _backlog
from code_puppy.run_context import (
    RunContext,
    create_root_run_context,
    get_current_run_context,
    reset_run_context,
    set_current_run_context,
)

__all__ = [
    # Registration API
    "register_callback",
    "unregister_callback",
    "clear_callbacks",
    "_reset_for_tests",
    "get_callbacks",
    "count_callbacks",
    # Trigger functions (used by core and plugins)
    "on_startup",
    "on_shutdown",
    "on_invoke_agent",
    "on_agent_exception",
    "on_version_check",
    "on_load_model_config",
    "on_load_models_config",
    "on_edit_file",
    "on_create_file",
    "on_replace_in_file",
    "on_delete_snippet",
    "on_delete_file",
    "on_run_shell_command",
    "on_agent_run_start",
    "on_agent_run_end",
    "on_pre_tool_call",
    "on_post_tool_call",
    "on_register_tools",
    "on_register_agents",
    "on_register_model_types",
    "on_file_permission",
    "on_file_permission_async",
    "on_register_mcp_catalog_servers",
    "on_register_browser_types",
    "on_get_motd",
    "on_register_model_providers",
    "on_stream_event",
    "on_custom_command",
    "on_custom_command_help",
    "on_get_model_system_prompt",
    "on_load_prompt",
    # Backlog management
    "drain_backlog",
    "drain_all_backlogs",
]

# Sentinel value to distinguish callback failures from None returns
_CALLBACK_FAILED = object()
"""Sentinel returned by callbacks when they fail with an exception."""

PhaseType = Literal[
    "startup",
    "shutdown",
    "invoke_agent",
    "agent_exception",
    "version_check",
    "edit_file",
    "create_file",
    "replace_in_file",
    "delete_snippet",
    "delete_file",
    "run_shell_command",
    "load_model_config",
    "load_models_config",
    "load_prompt",
    "agent_reload",
    "custom_command",
    "custom_command_help",
    "file_permission",
    "pre_tool_call",
    "post_tool_call",
    "stream_event",
    "register_tools",
    "register_agents",
    "register_model_type",
    "get_model_system_prompt",
    "agent_run_start",
    "agent_run_end",
    "register_mcp_catalog_servers",
    "register_browser_types",
    "get_motd",
    "register_model_providers",
    "message_history_processor_start",
    "message_history_processor_end",
]
type CallbackFunc = Callable[..., Any]

_callbacks: dict[PhaseType, list[CallbackFunc]] = {
    "startup": [],
    "shutdown": [],
    "invoke_agent": [],
    "agent_exception": [],
    "version_check": [],
    "edit_file": [],
    "create_file": [],
    "replace_in_file": [],
    "delete_snippet": [],
    "delete_file": [],
    "run_shell_command": [],
    "load_model_config": [],
    "load_models_config": [],
    "load_prompt": [],
    "agent_reload": [],
    "custom_command": [],
    "custom_command_help": [],
    "file_permission": [],
    "pre_tool_call": [],
    "post_tool_call": [],
    "stream_event": [],
    "register_tools": [],
    "register_agents": [],
    "register_model_type": [],
    "get_model_system_prompt": [],
    "agent_run_start": [],
    "agent_run_end": [],
    "register_mcp_catalog_servers": [],
    "register_browser_types": [],
    "get_motd": [],
    "register_model_providers": [],
    "message_history_processor_start": [],
    "message_history_processor_end": [],
}

logger = logging.getLogger(__name__)

# Thread-safety lock for _callbacks dict access
# Using RLock to allow nested locking (safety guard for complex scenarios)
_callbacks_lock = threading.RLock()

# Shutdown reentrancy guard — prevents recursive cleanup when signals
# arrive during an ongoing shutdown.  Inspired by oh-my-pi's
# postmortem.ts (idle → running → complete state machine).
# See: ../oh-my-pi-main/packages/utils/src/postmortem.ts:runCleanup()
_ShutdownStage = Literal["idle", "running", "complete"]
_shutdown_stage: _ShutdownStage = "idle"
_shutdown_stage_lock = threading.Lock()


def register_callback(phase: PhaseType, func: CallbackFunc) -> None:
    with _callbacks_lock:
        if phase not in _callbacks:
            raise ValueError(
                f"Unsupported phase: {phase}. Supported phases: {list(_callbacks.keys())}"
            )

        if not callable(func):
            raise TypeError(f"Callback must be callable, got {type(func)}")

        # Prevent duplicate registration of the same callback function
        # This can happen if plugins are accidentally loaded multiple times
        if func in _callbacks[phase]:
            logger.debug(
                f"Callback {func.__name__} already registered for phase '{phase}', skipping"
            )
            return

        _callbacks[phase].append(func)
    # Mark this phase as having had a listener (for _backlog early-exit optimization)
    # Note: this call is outside the lock to prevent lock contention with _backlog
    _backlog.mark_phase_as_having_listener(phase)
    logger.debug(f"Registered async callback {func.__name__} for phase '{phase}'")


def unregister_callback(phase: PhaseType, func: CallbackFunc) -> bool:
    with _callbacks_lock:
        if phase not in _callbacks:
            return False

        try:
            _callbacks[phase].remove(func)
            logger.debug(
                f"Unregistered async callback {func.__name__} from phase '{phase}'"
            )
            return True
        except ValueError:
            return False


def clear_callbacks(phase: PhaseType | None = None) -> None:
    with _callbacks_lock:
        if phase is None:
            for p in _callbacks:
                _callbacks[p].clear()
        else:
            if phase in _callbacks:
                _callbacks[phase].clear()
    # _backlog calls outside the lock to prevent lock contention
    if phase is None:
        _backlog.clear()
        logger.debug("Cleared all async callbacks")
    else:
        _backlog.clear(phase)
        logger.debug(f"Cleared async callbacks for phase '{phase}'")


def _reset_for_tests() -> None:
    """Reset all callback registrations for test isolation.

    This clears ALL registered callbacks to prevent cross-test pollution.
    Only use in test fixtures, never in production code.
    """
    clear_callbacks(None)


def get_callbacks(phase: PhaseType) -> tuple[CallbackFunc, ...]:
    """Return an immutable snapshot of callbacks for the given phase.

    Returns a tuple (cheaper than list.copy()) to prevent accidental mutation.
    Thread-safe: takes a snapshot while holding the lock to prevent
    concurrent modification during iteration.
    """
    with _callbacks_lock:
        return tuple(_callbacks.get(phase, ()))


def count_callbacks(phase: PhaseType | None = None) -> int:
    with _callbacks_lock:
        if phase is None:
            return sum(len(callbacks) for callbacks in _callbacks.values())
        return len(_callbacks.get(phase, []))


def _ensure_plugins_loaded_for_phase(phase: PhaseType) -> None:
    """Ensure all lazy-loaded plugins for a phase are imported.

    This is called before triggering callbacks to ensure plugins that
    registered for this phase via lazy loading are actually loaded.
    """
    import os

    # Allow tests to disable auto-plugin-loading for isolated testing
    if os.environ.get("PUP_DISABLE_CALLBACK_PLUGIN_LOADING"):
        return

    try:
        from code_puppy.plugins import (
            ensure_plugins_loaded_for_phase,
            load_plugin_callbacks,
        )

        # Ensure plugins are discovered first (idempotent - safe to call multiple times)
        load_plugin_callbacks()
        # Then load plugins for this specific phase
        ensure_plugins_loaded_for_phase(phase)
    except ImportError:
        # Plugin system not available (shouldn't happen in normal operation)
        pass


def _trigger_callbacks_sync(phase: PhaseType, *args, **kwargs) -> list[Any]:
    # Ensure lazy-loaded plugins for this phase are loaded first
    # MUST happen before count check, otherwise plugins never get a chance to register
    _ensure_plugins_loaded_for_phase(phase)

    # Now check if any callbacks are registered
    callbacks = get_callbacks(phase)
    if not callbacks:
        _backlog.buffer_event(phase, args, kwargs)
        return []

    results = []
    for callback in callbacks:
        try:
            result = callback(*args, **kwargs)
            # Handle async callbacks - if we get a coroutine, run it
            if asyncio.iscoroutine(result):
                # Try to get the running event loop
                try:
                    _ = asyncio.get_running_loop()
                    # We're inside a running event loop - schedule without blocking
                    # Use ensure_future to fire on the existing loop and return the Task
                    task = asyncio.ensure_future(result)
                    results.append(task)
                    continue
                except RuntimeError:
                    # No running loop - we're in a sync/worker thread context
                    # Use asyncio.run() which is safe here since we're in an isolated thread
                    result = asyncio.run(result)
            results.append(result)
            logger.debug(f"Successfully executed callback {callback.__name__}")
        except Exception as e:
            logger.error(
                f"Callback {callback.__name__} failed in phase '{phase}': {e}\n"
                f"{traceback.format_exc()}"
            )
            results.append(_CALLBACK_FAILED)

    return results


async def _trigger_callbacks(phase: PhaseType, *args, **kwargs) -> list[Any]:
    # Ensure lazy-loaded plugins for this phase are loaded first
    # MUST happen before count check, otherwise plugins never get a chance to register
    _ensure_plugins_loaded_for_phase(phase)

    # Now check if any callbacks are registered
    callbacks = get_callbacks(phase)
    if not callbacks:
        _backlog.buffer_event(phase, args, kwargs)
        return []

    logger.debug(f"Triggering {len(callbacks)} async callbacks for phase '{phase}'")

    async def _run_one(callback: CallbackFunc) -> Any:
        try:
            result = callback(*args, **kwargs)
            if asyncio.iscoroutine(result):
                result = await result
            logger.debug(f"Successfully executed async callback {callback.__name__}")
            return result
        except Exception as e:
            logger.error(
                f"Async callback {callback.__name__} failed in phase '{phase}': {e}\n"
                f"{traceback.format_exc()}"
            )
            return _CALLBACK_FAILED

    # Use TaskGroup (Python 3.11+) for structured concurrency.
    # Note: _run_one catches all exceptions and returns None, so TaskGroup
    # won't auto-cancel siblings on failure. The TaskGroup still provides
    # better structured concurrency semantics than manual task management.
    results: list[Any] = []
    async with asyncio.TaskGroup() as tg:
        tasks = [tg.create_task(_run_one(cb)) for cb in callbacks]
    results = [t.result() for t in tasks]
    return results


def drain_backlog(phase: PhaseType) -> list[Any]:
    """Replay buffered events for a phase that had no listeners when fired.

    Call after registering callbacks to process events that were fired
    during plugin loading before listeners were registered.
    """
    buffered = _backlog.drain_backlog(phase)
    results = []
    for args, kwargs in buffered:
        results.extend(_trigger_callbacks_sync(phase, *args, **kwargs))
    return results


def drain_all_backlogs() -> dict[str, list[Any]]:
    """Drain backlogs for all phases. Call after plugin loading completes."""
    all_buffered = _backlog.drain_all()
    results: dict[str, list[Any]] = {}
    for phase, events in all_buffered.items():
        phase_results = []
        for args, kwargs in events:
            phase_results.extend(_trigger_callbacks_sync(phase, *args, **kwargs))
        if phase_results:
            results[phase] = phase_results
    return results


async def on_startup() -> list[Any]:
    return await _trigger_callbacks("startup")


async def on_shutdown() -> list[Any]:
    """Trigger shutdown callbacks with reentrancy protection.

    Implements a 3-state machine (idle → running → complete) to prevent
    recursive cleanup when signals arrive during an ongoing shutdown.

    Ported from oh-my-pi's postmortem.ts reentrancy guard pattern.

    Returns:
        List of results from shutdown callbacks, or empty list if
        shutdown is already running or complete.
    """
    global _shutdown_stage

    with _shutdown_stage_lock:
        if _shutdown_stage == "running":
            logger.warning(
                "Shutdown triggered recursively (already running); "
                "ignoring duplicate shutdown request"
            )
            return []
        if _shutdown_stage == "complete":
            logger.debug("Shutdown already complete; ignoring duplicate request")
            return []
        _shutdown_stage = "running"

    try:
        results = await _trigger_callbacks("shutdown")
        return results
    finally:
        with _shutdown_stage_lock:
            _shutdown_stage = "complete"


def get_shutdown_stage() -> str:
    """Return the current shutdown stage for monitoring/testing.

    Returns:
        One of "idle", "running", or "complete".
    """
    with _shutdown_stage_lock:
        return _shutdown_stage


def reset_shutdown_stage() -> None:
    """Reset the shutdown stage to idle.

    Only intended for testing. Do not call in production code.
    """
    global _shutdown_stage
    with _shutdown_stage_lock:
        _shutdown_stage = "idle"


async def on_invoke_agent(*args, **kwargs) -> list[Any]:
    return await _trigger_callbacks("invoke_agent", *args, **kwargs)


async def on_agent_exception(exception: Exception, *args, **kwargs) -> list[Any]:
    return await _trigger_callbacks("agent_exception", exception, *args, **kwargs)


async def on_version_check(*args, **kwargs) -> list[Any]:
    # TODO(audit-2026): No plugin implements version_check. Consider removal or implementation.
    return await _trigger_callbacks("version_check", *args, **kwargs)


# Extension point: plugin-provided model config patches (no default handler required)
def on_load_model_config(*args, **kwargs) -> list[Any]:
    return _trigger_callbacks_sync("load_model_config", *args, **kwargs)


# Extension point: plugin-provided model configurations (no default handler required)
def on_load_models_config() -> list[Any]:
    """Trigger callbacks to load additional model configurations.

    Plugins can register callbacks that return a dict of model configurations
    to be merged with the built-in models.json. Plugin models override built-in
    models with the same name.

    Returns:
        List of model config dicts from all registered callbacks.
    """
    return _trigger_callbacks_sync("load_models_config")


# Extension points: file mutation observers (no default handler required).
# Plugins can register for these hooks to observe file changes.
def on_edit_file(*args, **kwargs) -> Any:
    return _trigger_callbacks_sync("edit_file", *args, **kwargs)


def on_create_file(*args, **kwargs) -> Any:
    return _trigger_callbacks_sync("create_file", *args, **kwargs)


def on_replace_in_file(*args, **kwargs) -> Any:
    return _trigger_callbacks_sync("replace_in_file", *args, **kwargs)


def on_delete_snippet(*args, **kwargs) -> Any:
    return _trigger_callbacks_sync("delete_snippet", *args, **kwargs)


def on_delete_file(*args, **kwargs) -> Any:
    return _trigger_callbacks_sync("delete_file", *args, **kwargs)


async def on_run_shell_command(*args, **kwargs) -> Any:
    """Trigger callbacks for shell command execution.

    SECURITY-CRITICAL: This function implements FAIL-CLOSED semantics.
    If a security callback raises an exception, the operation is denied
    (returns a Deny result) rather than being allowed to proceed.

    Returns:
        List of callback results. If any callback raises an exception,
        the result will be a Deny object indicating the operation should be blocked.
    """
    # Import here to avoid circular dependency
    try:
        from code_puppy.permission_decision import Deny
    except ImportError:
        # Fallback if permission_decision is not available
        Deny = None

    results = await _trigger_callbacks("run_shell_command", *args, **kwargs)

    # Replace _CALLBACK_FAILED results with Deny for fail-closed behavior
    # This ensures that if a security plugin crashes, the command is blocked
    security_results = []
    for result in results:
        if result is _CALLBACK_FAILED and Deny is not None:
            # Callback failed with exception - deny the operation
            logger.warning(
                "Security callback for run_shell_command failed with exception; "
                "denying operation (fail-closed)"
            )
            security_results.append(
                Deny(
                    reason="Security check failed",
                    user_feedback="Command blocked due to security check failure",
                )
            )
        else:
            security_results.append(result)

    return security_results


def on_agent_reload(*args, **kwargs) -> Any:
    return _trigger_callbacks_sync("agent_reload", *args, **kwargs)


def on_load_prompt():
    return _trigger_callbacks_sync("load_prompt")


def on_custom_command_help() -> list[Any]:
    """Collect custom command help entries from plugins.

    Each callback should return a list of tuples [(name, description), ...]
    or a single tuple, or None. We'll flatten and sanitize results.
    """
    return _trigger_callbacks_sync("custom_command_help")


def on_custom_command(command: str, name: str) -> list[Any]:
    """Trigger custom command callbacks.

    This allows plugins to register handlers for slash commands
    that are not built into the core command handler.

    Args:
        command: The full command string (e.g., "/foo bar baz").
        name: The primary command name without the leading slash (e.g., "foo").

    Returns:
        Implementations may return:
        - True if the command was handled (and no further action is needed)
        - A string to be processed as user input by the caller
        - None to indicate not handled
    """
    return _trigger_callbacks_sync("custom_command", command, name)


def on_file_permission(
    context: Any,
    file_path: str,
    operation: str,
    preview: str | None = None,
    message_group: str | None = None,
    operation_data: Any = None,
) -> list[Any]:
    """Trigger file permission callbacks.

    SECURITY-CRITICAL: This function implements FAIL-CLOSED semantics.
    If a security callback raises an exception, the operation is denied
    (returns False) rather than being allowed to proceed.

    This allows plugins to register handlers for file permission checks
    before file operations are performed.

    Args:
        context: The operation context
        file_path: Path to the file being operated on
        operation: Description of the operation
        preview: Optional preview of changes (deprecated - use operation_data instead)
        message_group: Optional message group
        operation_data: Operation-specific data for preview generation (recommended)

    Returns:
        List of boolean results from permission handlers.
        Returns True if permission should be granted, False if denied.
        If a callback raises an exception, returns False to deny the operation.
    """
    # For backward compatibility, if operation_data is provided, prefer it over preview
    if operation_data is not None:
        preview = None

    results = _trigger_callbacks_sync(
        "file_permission",
        context,
        file_path,
        operation,
        preview,
        message_group,
        operation_data,
    )

    # Replace _CALLBACK_FAILED results with False for fail-closed behavior
    # This ensures that if a security plugin crashes, the file operation is blocked
    security_results = []
    for result in results:
        if result is _CALLBACK_FAILED:
            # Callback failed with exception - deny the operation
            logger.warning(
                "Security callback for file_permission failed with exception; "
                "denying %s on %s (fail-closed)",
                operation,
                file_path,
            )
            security_results.append(False)
        else:
            security_results.append(result)

    return security_results


async def on_file_permission_async(
    context: Any,
    file_path: str,
    operation: str,
    preview: str | None = None,
    message_group: str | None = None,
    operation_data: Any = None,
) -> list[Any]:
    """Async version of on_file_permission.

    This async variant properly awaits async callbacks, ensuring that
    async file permission handlers (like those that generate diffs in
    thread pools) are fully executed before returning results.

    SECURITY-CRITICAL: This function implements FAIL-CLOSED semantics.
    If a security callback raises an exception, the operation is denied
    (returns False) rather than being allowed to proceed.

    Args:
        context: The operation context
        file_path: Path to the file being operated on
        operation: Description of the operation
        preview: Optional preview of changes (deprecated - use operation_data instead)
        message_group: Optional message group
        operation_data: Operation-specific data for preview generation (recommended)

    Returns:
        List of boolean results from permission handlers.
        Returns True if permission should be granted, False if denied.
        If a callback raises an exception, returns False to deny the operation.
    """
    # For backward compatibility, if operation_data is provided, prefer it over preview
    if operation_data is not None:
        preview = None

    results = await _trigger_callbacks(
        "file_permission",
        context,
        file_path,
        operation,
        preview,
        message_group,
        operation_data,
    )

    # Replace _CALLBACK_FAILED results with False for fail-closed behavior
    # This ensures that if a security plugin crashes, the file operation is blocked
    security_results = []
    for result in results:
        if result is _CALLBACK_FAILED:
            # Callback failed with exception - deny the operation
            logger.warning(
                "Security callback for file_permission failed with exception; "
                "denying %s on %s (fail-closed)",
                operation,
                file_path,
            )
            security_results.append(False)
        else:
            security_results.append(result)

    return security_results


async def on_pre_tool_call(
    tool_name: str, tool_args: dict, context: Any = None
) -> list[Any]:
    """Trigger callbacks before a tool is called.

    SECURITY-CRITICAL: This function implements FAIL-CLOSED semantics.
    If a security callback raises an exception, the operation is denied
    (returns a Deny result) rather than being allowed to proceed.

    This allows plugins to inspect, modify, or log tool calls before
    they are executed.

    If an active :class:`~code_puppy.run_context.RunContext` exists, a child
    context is created for the tool invocation and set as the current context.
    The previous context is automatically restored by
    :func:`~code_puppy.callbacks.on_post_tool_call`.

    Args:
        tool_name: Name of the tool being called
        tool_args: Arguments being passed to the tool
        context: Optional context data for the tool call

    Returns:
        List of results from registered callbacks.
        If any callback raises an exception, returns a Deny object to block the tool.
    """
    # Import here to avoid circular dependency
    try:
        from code_puppy.permission_decision import Deny
    except ImportError:
        Deny = None

    parent = get_current_run_context()
    if parent is not None:
        child = RunContext.create_child(
            parent,
            component_type="tool",
            component_name=tool_name,
            metadata={"tool_args_keys": list(tool_args.keys())},
        )
        # Stash weak reference to parent to avoid memory retention chain.
        child.metadata["_parent_ref"] = weakref.ref(parent)
        # Store the token for proper context reset in on_post_tool_call.
        child.metadata["_context_token"] = set_current_run_context(child)
        try:
            results = await _trigger_callbacks(
                "pre_tool_call", tool_name, tool_args, context
            )
        except Exception:
            # Restore parent context on error to prevent context leaks.
            token = child.metadata.pop("_context_token", None)
            if token is not None:
                reset_run_context(token)
            raise
    else:
        results = await _trigger_callbacks(
            "pre_tool_call", tool_name, tool_args, context
        )

    # Replace _CALLBACK_FAILED results with Deny for fail-closed behavior
    # This ensures that if a security plugin crashes, the tool is blocked
    security_results = []
    for result in results:
        if result is _CALLBACK_FAILED and Deny is not None:
            # Callback failed with exception - deny the operation
            logger.warning(
                "Security callback for pre_tool_call failed with exception; "
                "denying tool %s (fail-closed)",
                tool_name,
            )
            security_results.append(
                Deny(
                    reason="Security check failed",
                    user_feedback=f"Tool {tool_name} blocked due to security check failure",
                )
            )
        else:
            security_results.append(result)

    return security_results


async def on_post_tool_call(
    tool_name: str,
    tool_args: dict,
    result: Any,
    duration_ms: float,
    context: Any = None,
) -> list[Any]:
    """Trigger callbacks after a tool completes.

    This allows plugins to inspect tool results, log execution times,
    or perform post-processing.

    If a tool-level :class:`~code_puppy.run_context.RunContext` is active it
    is closed and the parent context is restored.

    Args:
        tool_name: Name of the tool that was called
        tool_args: Arguments that were passed to the tool
        result: The result returned by the tool
        duration_ms: Execution time in milliseconds
        context: Optional context data for the tool call

    Returns:
        List of results from registered callbacks.
    """
    # Close the tool-level child context and restore the parent.
    ctx = get_current_run_context()
    if (
        ctx is not None
        and ctx.component_type == "tool"
        and ctx.component_name == tool_name
    ):
        ctx.end(success=True)
        ctx.metadata["duration_ms"] = duration_ms
        # Restore the parent context that was stashed by on_pre_tool_call.
        token = ctx.metadata.pop("_context_token", None)
        if token is not None:
            reset_run_context(token)
        # Resolve weakref to parent if still available.
        parent_ref = ctx.metadata.pop("_parent_ref", None)
        if parent_ref is not None:
            parent = parent_ref() if callable(parent_ref) else parent_ref
            if parent is not None:
                set_current_run_context(parent)

    return await _trigger_callbacks(
        "post_tool_call", tool_name, tool_args, result, duration_ms, context
    )


async def on_stream_event(
    event_type: str, event_data: Any, agent_session_id: str | None = None
) -> list[Any]:
    """Trigger callbacks for streaming events.

    This allows plugins to react to streaming events in real-time,
    such as tokens being generated, tool calls starting, etc.

    If an active :class:`~code_puppy.run_context.RunContext` exists, the
    context's ``run_id`` and ``component_name`` are attached to
    *event_data* (when it is a dict) under the keys ``_run_id`` and
    ``_component_name`` so that downstream consumers can correlate events
    with the tracing hierarchy without changing the callback signature.

    Args:
        event_type: Type of the streaming event
        event_data: Data associated with the event
        agent_session_id: Optional session ID of the agent emitting the event

    Returns:
        List of results from registered callbacks.
    """
    ctx = get_current_run_context()
    if ctx is not None and isinstance(event_data, dict):
        event_data.setdefault("_run_id", ctx.run_id)
        event_data.setdefault("_component_name", ctx.component_name)

    return await _trigger_callbacks(
        "stream_event", event_type, event_data, agent_session_id
    )


def on_register_tools() -> list[dict[str, Any]]:
    """Collect custom tool registrations from plugins.

    Each callback should return a list of dicts with:
    - "name": str - the tool name
    - "register_func": callable - function that takes an agent and registers the tool

    Example return: [{"name": "my_tool", "register_func": register_my_tool}]
    """
    return _trigger_callbacks_sync("register_tools")


# Extension point: plugin-provided agent catalogue entries (no default handler required)
def on_register_agents() -> list[dict[str, Any]]:
    """Collect custom agent registrations from plugins.

    Each callback should return a list of dicts with either:
    - "name": str, "class": type[BaseAgent] - for Python agent classes
    - "name": str, "json_path": str - for JSON agent files

    Example return: [{"name": "my-agent", "class": MyAgentClass}]
    """
    import os

    # Allow tests to disable auto-plugin-loading for isolated testing
    if not os.environ.get("PUP_DISABLE_CALLBACK_PLUGIN_LOADING"):
        # AP visibility fix: Ensure plugins are discovered and loaded for register_agents
        # BEFORE checking callback count, since lazy-loaded plugins register callbacks
        # at import time. Without this, AP agents would not be visible in /agent.
        try:
            from code_puppy.plugins import (
                ensure_plugins_loaded_for_phase,
                load_plugin_callbacks,
            )

            load_plugin_callbacks()
            ensure_plugins_loaded_for_phase("register_agents")
        except ImportError:
            pass  # Plugin system not available

    return _trigger_callbacks_sync("register_agents")


def on_register_model_types() -> list[dict[str, Any]]:
    """Collect custom model type registrations from plugins.

    This hook allows plugins to register custom model types that can be used
    in model configurations. Each callback should return a list of dicts with:
    - "type": str - the model type name (e.g., "antigravity", "claude_code")
    - "handler": callable - function(model_name, model_config, config) -> model instance

    The handler function receives:
    - model_name: str - the name of the model being created
    - model_config: dict - the model's configuration from models.json
    - config: dict - the full models configuration

    The handler should return a model instance or None if creation fails.

    Example callback:
        def register_my_model_types():
            return [{
                "type": "my_custom_type",
                "handler": create_my_custom_model,
            }]

    Example return: [{"type": "antigravity", "handler": create_antigravity_model}]
    """
    return _trigger_callbacks_sync("register_model_type")


def on_get_model_system_prompt(
    model_name: str, default_system_prompt: str, user_prompt: str
) -> list[Any]:
    """Allow plugins to provide custom system prompts for specific model types.

    This hook allows plugins to override or extend system prompt handling for
    custom model types (like claude_code or antigravity models). Callbacks are
    executed sequentially, and each callback receives the current effective
    prompt values produced by earlier callbacks. That chaining behavior lets
    additive prompt plugins cooperate instead of each recomputing from the
    original prompt independently.

    Args:
        model_name: The name of the model being used (e.g., "claude-code-sonnet")
        default_system_prompt: The default system prompt from the agent
        user_prompt: The user's prompt/message

    Each callback should return a dict with:
    - "instructions": str - the system prompt/instructions to use
    - "user_prompt": str - the (possibly modified) user prompt
    - "handled": bool - True if this callback fully handled the model

    Or return None if the callback doesn't handle this model type.

    Returns:
        List of results from registered callbacks in execution order.
    """
    phase: PhaseType = "get_model_system_prompt"

    # Ensure plugins are loaded BEFORE checking count, otherwise lazy-loaded
    # plugins never get a chance to register callbacks
    _ensure_plugins_loaded_for_phase(phase)

    callbacks = get_callbacks(phase)
    if not callbacks:
        _backlog.buffer_event(
            phase, (model_name, default_system_prompt, user_prompt), {}
        )
        return []

    results: list[Any] = []
    current_system_prompt = default_system_prompt
    current_user_prompt = user_prompt

    for callback in callbacks:
        try:
            result = callback(model_name, current_system_prompt, current_user_prompt)
            if asyncio.iscoroutine(result):
                try:
                    _ = asyncio.get_running_loop()
                    task = asyncio.ensure_future(result)
                    results.append(task)
                    continue
                except RuntimeError:
                    result = asyncio.run(result)

            results.append(result)
            if isinstance(result, dict):
                current_system_prompt = result.get(
                    "instructions", current_system_prompt
                )
                current_user_prompt = result.get("user_prompt", current_user_prompt)
            logger.debug(f"Successfully executed callback {callback.__name__}")
        except Exception as e:
            logger.error(
                f"Callback {callback.__name__} failed in phase '{phase}': {e}\n"
                f"{traceback.format_exc()}"
            )
            results.append(_CALLBACK_FAILED)

    return results


async def on_agent_run_start(
    agent_name: str,
    model_name: str,
    session_id: str | None = None,
    tags: list[str] | None = None,
    metadata: dict[str, Any] | None = None,
) -> tuple[list[Any], RunContext]:
    """Trigger callbacks when an agent run starts.

    This fires at the beginning of run_with_mcp, before the agent task is created.
    Useful for:
    - Starting background tasks (like token refresh heartbeats)
    - Logging/analytics
    - Resource allocation

    Additionally, a root :class:`~code_puppy.run_context.RunContext` is created
    and set in the current ``ContextVar`` so that downstream tool / stream
    callbacks can access hierarchical tracing information.

    Args:
        agent_name: Name of the agent starting
        model_name: Name of the model being used
        session_id: Optional session identifier
        tags: Optional list of tags for the run context
        metadata: Optional dict with additional metadata (merged with model_name)

    Returns:
        Tuple of (callback_results, run_context) for downstream use.
    """
    # Create and activate a root run context for hierarchical tracing.
    # Merge provided metadata with model_name.
    merged_metadata = {"model_name": model_name}
    if metadata:
        merged_metadata.update(metadata)

    ctx = create_root_run_context(
        component_type="agent",
        component_name=agent_name,
        session_id=session_id,
        tags=tags or [],
        metadata=merged_metadata,
    )
    set_current_run_context(ctx)

    results = await _trigger_callbacks(
        "agent_run_start", agent_name, model_name, session_id
    )
    return results, ctx


async def on_agent_run_end(
    agent_name: str,
    model_name: str,
    session_id: str | None = None,
    success: bool = True,
    error: Exception | None = None,
    response_text: str | None = None,
    metadata: dict | None = None,
    run_context: RunContext | None = None,
) -> list[Any]:
    """Trigger callbacks when an agent run ends.

    This fires at the end of run_with_mcp, in the finally block.
    Always fires regardless of success/failure/cancellation.

    The active :class:`~code_puppy.run_context.RunContext` (if any) is closed
    and enriched with ``success``, ``error``, and ``response_text`` before the
    callbacks fire.

    Useful for:
    - Stopping background tasks (like token refresh heartbeats)
    - Workflow orchestration (like Ralph's autonomous loop)
    - Logging/analytics
    - Resource cleanup
    - Detecting completion signals in responses

    Args:
        agent_name: Name of the agent that finished
        model_name: Name of the model that was used
        session_id: Optional session identifier
        success: Whether the run completed successfully
        error: Exception if the run failed, None otherwise
        response_text: The final text response from the agent (if successful)
        metadata: Optional dict with additional context (tokens used, etc.)
        run_context: Optional RunContext passed from caller (for API consistency).
            If not provided, uses the current context from get_current_run_context().

    Returns:
        List of results from registered callbacks.
    """
    # Close and enrich the run context (if one exists).
    # Prefer the explicitly passed run_context, fall back to current context.
    ctx = run_context if run_context is not None else get_current_run_context()
    if ctx is not None:
        ctx.end(success=success, error=error)
        ctx.metadata["success"] = success
        if error is not None:
            ctx.metadata["error"] = str(error)
        if response_text is not None:
            ctx.metadata["response_text_length"] = len(response_text)
        if metadata:
            ctx.metadata.update(metadata)

    return await _trigger_callbacks(
        "agent_run_end",
        agent_name,
        model_name,
        session_id,
        success,
        error,
        response_text,
        metadata,
        run_context=ctx,
    )


# Extension point: no default handler required
def on_register_mcp_catalog_servers() -> list[Any]:
    """Trigger callbacks to register additional MCP catalog servers.

    Plugins can register callbacks that return list[MCPServerTemplate] to add
    servers to the MCP catalog/marketplace.

    Returns:
        List of results from all registered callbacks (each should be a list of MCPServerTemplate).
    """
    return _trigger_callbacks_sync("register_mcp_catalog_servers")


# Extension point: no default handler required
def on_register_browser_types() -> list[Any]:
    """Trigger callbacks to register custom browser types/providers.

    Plugins can register callbacks that return a dict mapping browser type names
    to initialization functions. This allows plugins to provide custom browser
    implementations (like Camoufox for stealth browsing).

    Each callback should return a dict with:
    - key: str - the browser type name (e.g., "camoufox", "firefox-stealth")
    - value: callable - async initialization function that takes (manager, **kwargs)
                        and sets up the browser on the manager instance

    Example callback:
        def register_my_browser_types():
            return {
                "camoufox": initialize_camoufox,
                "my-stealth-browser": initialize_my_stealth,
            }

    Returns:
        List of dicts from all registered callbacks.
    """
    return _trigger_callbacks_sync("register_browser_types")


# Extension point: no default handler required
def on_get_motd() -> list[Any]:
    """Trigger callbacks to get custom MOTD content.

    Plugins can register callbacks that return a tuple of (message, version).
    The last non-None result will be used as the MOTD.

    Returns:
        List of (message, version) tuples from registered callbacks.
    """
    return _trigger_callbacks_sync("get_motd")


# Extension point: no default handler required
def on_register_model_providers() -> list[Any]:
    """Trigger callbacks to register custom model provider classes.

    Plugins can register callbacks that return a dict mapping provider names
    to model classes. Example: {"walmart_gemini": WalmartGeminiModel}

    Returns:
        List of dicts from all registered callbacks.
    """
    return _trigger_callbacks_sync("register_model_providers")


def on_message_history_processor_start(
    agent_name: str,
    session_id: str | None,
    message_history: list[Any],
    incoming_messages: list[Any],
) -> list[Any]:
    """Trigger callbacks at the start of message history processing.

    This hook fires at the beginning of the message_history_accumulator,
    before any deduplication or processing occurs. Useful for:
    - Logging/debugging message flow
    - Observing raw incoming messages
    - Analytics on message history growth

    Args:
        agent_name: Name of the agent processing messages
        session_id: Optional session identifier
        message_history: Current message history (before processing)
        incoming_messages: New messages being added

    Returns:
        List of results from registered callbacks.
    """
    return _trigger_callbacks_sync(
        "message_history_processor_start",
        agent_name,
        session_id,
        message_history,
        incoming_messages,
    )


def on_message_history_processor_end(
    agent_name: str,
    session_id: str | None,
    message_history: list[Any],
    messages_added: int,
    messages_filtered: int,
) -> list[Any]:
    """Trigger callbacks at the end of message history processing.

    This hook fires at the end of the message_history_accumulator,
    after deduplication and filtering has been applied. Useful for:
    - Logging/debugging final message state
    - Analytics on deduplication effectiveness
    - Observing what was actually added to history

    Args:
        agent_name: Name of the agent processing messages
        session_id: Optional session identifier
        message_history: Final message history (after processing)
        messages_added: Count of new messages that were added
        messages_filtered: Count of messages that were filtered out (dupes/empty)

    Returns:
        List of results from registered callbacks.
    """
    return _trigger_callbacks_sync(
        "message_history_processor_end",
        agent_name,
        session_id,
        message_history,
        messages_added,
        messages_filtered,
    )
