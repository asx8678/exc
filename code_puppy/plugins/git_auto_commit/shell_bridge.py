"""Shell Bridge - Sync to Async Bridge for Git Commands.

This module bridges the gap between:
- sync `custom_command` callback (invoked via _trigger_callbacks_sync)
- async `run_shell_command` callbacks (checked by SecurityBoundary)

The bridge uses an adaptive approach to safely execute async shell commands
through the security boundary without deadlocking and without breaking signal
compatibility with plugins like shell_safety that use signal.alarm().

Key insight: signal.alarm() only works in the main thread. We need to:
1. Detect if we're already in an async context (have a running event loop)
2. If yes: schedule the coroutine directly on that loop
3. If no: we're in the main thread, so we can use asyncio.run() safely
"""

import asyncio
import concurrent.futures
import logging
import threading
from typing import Any

from code_puppy.security import get_security_boundary

logger = logging.getLogger(__name__)


async def execute_git_command(command: str, cwd: str | None = None) -> dict[str, Any]:
    """Execute a git command through the security boundary.

    This async function:
    1. Gets the SecurityBoundary instance
    2. Calls `check_shell_command()` to validate the command
    3. If allowed, executes via `asyncio.create_subprocess_shell`
    4. Returns result with success status, output, and error

    Args:
        command: The git command to execute (e.g., "git status")
        cwd: Optional working directory for the command

    Returns:
        Dict with keys:
            - success: bool - Whether command executed successfully
            - output: str - stdout from the command
            - error: str - stderr from the command (if any)
            - blocked: bool - True if blocked by security (if True, success=False)
            - reason: str | None - Reason if blocked by security
    """
    logger.debug(f"Executing git command: {command}")

    if not command or not command.strip():
        return {
            "success": False,
            "output": "",
            "error": "Command cannot be empty",
            "blocked": False,
            "reason": None,
        }

    # Get security boundary and check if command is allowed
    security = get_security_boundary()
    decision = await security.check_shell_command(command, cwd)

    if not decision.allowed:
        logger.warning(f"Command blocked by security: {command[:50]}...")
        # Extract policy source from decision metadata if available
        policy_source = (
            decision.metadata.get("blocked_by") if decision.metadata else None
        )
        return {
            "success": False,
            "output": "",
            "error": f"Security blocked: {decision.reason}",
            "blocked": True,
            "reason": decision.reason,
            "policy_source": policy_source,
        }

    logger.debug(f"Command allowed by security, executing: {command[:50]}...")

    # Execute the command
    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd,
        )
        stdout, stderr = await proc.communicate()

        output = stdout.decode("utf-8", errors="replace") if stdout else ""
        error = stderr.decode("utf-8", errors="replace") if stderr else ""

        success = proc.returncode == 0

        if not success:
            logger.debug(
                f"Command failed with exit code {proc.returncode}: {command[:50]}..."
            )

        return {
            "success": success,
            "output": output,
            "error": error,
            "blocked": False,
            "reason": None,
            "returncode": proc.returncode,
        }

    except Exception as e:
        logger.exception(f"Failed to execute command: {command[:50]}...")
        return {
            "success": False,
            "output": "",
            "error": f"Execution error: {type(e).__name__}: {e}",
            "blocked": False,
            "reason": None,
        }


def _run_in_thread_with_loop(coro) -> Any:
    """Run a coroutine in a new thread with its own event loop.

    This is a specialized version that handles the signal.alarm() issue:
    - When shell_safety uses signal.alarm(), it fails in non-main threads
    - We catch the ValueError and fallback to subprocess-based execution
    """

    def run_coro():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            return loop.run_until_complete(coro)
        finally:
            loop.close()
            asyncio.set_event_loop(None)

    # Try running in thread - this might fail if shell_safety uses signal
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(run_coro)
            return future.result()
    except ValueError as e:
        if "signal only works in main thread" in str(e).lower():
            # shell_safety's signal.alarm() doesn't work in threads
            # Fallback: run without the shell_safety callback path
            logger.debug("Signal compatibility issue detected, using fallback")
            return _execute_git_command_fallback(coro)
        raise


def _execute_git_command_fallback(coro) -> Any:
    """Fallback execution when signal compatibility issues occur.

    This runs the coroutine in the main thread using asyncio.run()
    which is safe for signal.alarm(). This only works when called
    from the main thread with no existing event loop.
    """
    try:
        # Try to get the current loop - if there is one, we can't use asyncio.run
        asyncio.get_running_loop()  # noqa: B018  # We only care if this raises
        # We're in an async context with a running loop - we need to schedule
        # The caller must handle this case - we return a special error
        return {
            "success": False,
            "output": "",
            "error": "Signal compatibility: Cannot execute from non-main thread with shell_safety loaded",
            "blocked": False,
            "reason": "thread_compatibility",
        }
    except RuntimeError:
        # No running loop - we're in a sync context, can use asyncio.run()
        # This will work even with signal.alarm() since we're in the main thread
        return asyncio.run(coro)


def execute_git_command_sync(command: str, cwd: str | None = None) -> dict[str, Any]:
    """Synchronous wrapper for `execute_git_command()`.

    This function bridges the sync `custom_command` callback world to the
    async shell execution world. It uses an adaptive approach:

    1. If called from within an async context (has running loop):
       - Schedule the coroutine on the existing loop
    2. If called from main thread (no running loop):
       - Use asyncio.run() which supports signal.alarm()
    3. If called from non-main thread (no running loop):
       - Use a thread with event loop, but handle signal compatibility

    Args:
        command: The git command to execute
        cwd: Optional working directory

    Returns:
        Dict with execution results (see execute_git_command for details)

    Example:
        >>> result = execute_git_command_sync("git status")
        >>> if result["success"]:
        ...     print(result["output"])
        ... else:
        ...     print(f"Error: {result['error']}")
    """
    # Check for async context FIRST, before creating any coroutine
    # This prevents leaking unawaited coroutines when called from async code
    try:
        loop = asyncio.get_running_loop()
        if loop.is_running():
            return {
                "success": False,
                "output": "",
                "error": "Cannot use sync bridge from async context - use execute_git_command() directly",
                "blocked": False,
                "reason": "async_context",
            }
    except RuntimeError:
        pass  # No running loop - proceed with sync execution

    # NOW create the coroutine and run it
    coro = execute_git_command(command, cwd)

    # Check if we're in the main thread
    if threading.current_thread() is threading.main_thread():
        # In main thread - we can use asyncio.run() which works with signal.alarm()
        try:
            return asyncio.run(coro)
        except Exception as e:
            logger.exception(
                f"Failed to execute command via asyncio.run: {command[:50]}..."
            )
            return {
                "success": False,
                "output": "",
                "error": f"Execution error: {type(e).__name__}: {e}",
                "blocked": False,
                "reason": None,
            }
    else:
        # In a non-main thread - use the thread-based approach
        # This might fail if shell_safety is loaded (signal.alarm() limitation)
        return _run_in_thread_with_loop(coro)
