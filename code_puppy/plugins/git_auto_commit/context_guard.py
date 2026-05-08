"""GAC (Git Auto Commit) Context Guard - Safety guard for git mutations.

This module provides fail-closed safety guards that ensure git mutations
(commit, add, push, etc.) only occur in safe, interactive, main-agent contexts.
Sub-agents and non-interactive environments are blocked by default.

Usage:
    >>> from code_puppy.plugins.git_auto_commit.context_guard import (
    ...     check_gac_context,
    ...     is_gac_safe,
    ...     require_interactive_context,
    ...     GACContextError,
    ... )

    # Check and raise if unsafe
    >>> check_gac_context()  # Raises GACContextError in unsafe contexts

    # Check without raising
    >>> is_safe, reason = is_gac_safe()

    # Use as decorator
    >>> @require_interactive_context
    ... def git_commit(message: str):
    ...     # This will only run in safe contexts
    ...     pass
"""

import functools
import inspect
import sys
from collections.abc import Callable
from typing import Any, TypeVar

from code_puppy.tools.subagent_context import (
    get_subagent_depth,
    get_subagent_name,
    is_subagent,
)

__all__ = [
    "GACContextError",
    "REASON_SUBAGENT",
    "REASON_NON_INTERACTIVE",
    "REASON_NESTED_AGENT",
    "check_gac_context",
    "is_gac_safe",
    "require_interactive_context",
]

# Rejection reason constants for programmatic handling
REASON_SUBAGENT = "sub-agent context"
REASON_NON_INTERACTIVE = "non-interactive terminal"
REASON_NESTED_AGENT = "nested agent context"


class GACContextError(RuntimeError):
    """Exception raised when GAC operations are attempted in unsafe contexts.

    This is a hard-fail exception that prevents git mutations from occurring
    in contexts where user confirmation cannot be obtained (sub-agents,
    non-interactive terminals, etc.).

    Attributes:
        reason: The specific reason for the rejection (one of REASON_* constants)
        agent_name: The sub-agent name if applicable, None otherwise
        depth: The sub-agent nesting depth if applicable, 0 otherwise
    """

    def __init__(
        self,
        message: str,
        reason: str | None = None,
        agent_name: str | None = None,
        depth: int = 0,
    ):
        super().__init__(message)
        self.reason = reason
        self.agent_name = agent_name
        self.depth = depth


def check_gac_context() -> None:
    """Verify GAC is running in a safe context for git mutations.

    This is a fail-closed check: if detection fails or is uncertain,
    the operation is DENIED. Git mutations require:

    1. Main agent context (NOT a sub-agent)
    2. Interactive TTY (for user confirmation)

    Raises:
        GACContextError: If any safety check fails, with actionable error message

    Example:
        >>> check_gac_context()  # Passes silently in safe context
        >>> # Proceed with git operations

        >>> # In sub-agent context, raises:
        >>> check_gac_context()
        GACContextError: GAC refused: running in sub-agent context (retriever, depth=1).
        Git mutations require interactive main-agent context.
    """
    # Check 1: Sub-agent detection (fail-closed: if detection fails, assume unsafe)
    try:
        is_sub = is_subagent()
        depth = get_subagent_depth()
        agent_name = get_subagent_name()
    except Exception as e:
        # Fail-closed: if detection fails, we cannot guarantee safety
        raise GACContextError(
            f"GAC refused: unable to verify execution context ({type(e).__name__}: {e}). "
            "Git mutations require verifiable interactive main-agent context.",
            reason=REASON_SUBAGENT,
            agent_name=None,
            depth=0,
        ) from e

    if is_sub:
        # Determine if this is nested (depth > 1)
        is_nested = depth > 1
        reason = REASON_NESTED_AGENT if is_nested else REASON_SUBAGENT

        # Build actionable error message
        agent_info = f" ({agent_name}, depth={depth})" if agent_name else ""
        raise GACContextError(
            f"GAC refused: running in {reason}{agent_info}. "
            "Git mutations require interactive main-agent context. "
            "Run this command from the main agent to proceed.",
            reason=reason,
            agent_name=agent_name,
            depth=depth,
        )

    # Check 2: Interactive TTY detection
    try:
        is_tty = sys.stdin.isatty()
    except (AttributeError, OSError) as e:
        # Fail-closed: if TTY detection fails, assume non-interactive
        raise GACContextError(
            f"GAC refused: unable to verify terminal interactivity ({type(e).__name__}: {e}). "
            "Git mutations require an interactive TTY for user confirmation.",
            reason=REASON_NON_INTERACTIVE,
            agent_name=None,
            depth=0,
        ) from e

    if not is_tty:
        raise GACContextError(
            f"GAC refused: {REASON_NON_INTERACTIVE}. "
            "Git mutations require an interactive TTY for user confirmation. "
            "Run this command in an interactive terminal session.",
            reason=REASON_NON_INTERACTIVE,
            agent_name=None,
            depth=0,
        )

    # All checks passed - safe to proceed
    return None


def is_gac_safe() -> tuple[bool, str | None]:
    """Check if current context is safe for GAC operations without raising.

    This is the non-exception version of check_gac_context() for callers
    who need to check safety before deciding whether to proceed.

    Returns:
        Tuple of (is_safe, reason_or_none):
        - (True, None): Context is safe for git mutations
        - (False, reason_string): Context is unsafe, reason explains why

    Example:
        >>> is_safe, reason = is_gac_safe()
        >>> if not is_safe:
        ...     print(f"Skipping git operation: {reason}")
        ...     return
    """
    # Check 1: Sub-agent detection
    try:
        is_sub = is_subagent()
        depth = get_subagent_depth()
        agent_name = get_subagent_name()
    except Exception as e:
        # Fail-closed: if detection fails, report as unsafe
        return (False, f"context detection failed: {type(e).__name__}: {e}")

    if is_sub:
        is_nested = depth > 1
        reason = REASON_NESTED_AGENT if is_nested else REASON_SUBAGENT
        agent_info = f" ({agent_name}, depth={depth})" if agent_name else ""
        return (False, f"running in {reason}{agent_info}")

    # Check 2: Interactive TTY detection
    try:
        is_tty = sys.stdin.isatty()
    except (AttributeError, OSError) as e:
        # Fail-closed: if TTY detection fails, report as unsafe
        return (
            False,
            f"terminal interactivity detection failed: {type(e).__name__}: {e}",
        )

    if not is_tty:
        return (False, REASON_NON_INTERACTIVE)

    # All checks passed
    return (True, None)


# Type variable for decorator - supports both sync and async functions
F = TypeVar("F", bound=Callable[..., Any])


def require_interactive_context(func: F) -> F:
    """Decorator that ensures wrapped function only runs in safe GAC contexts.

    Automatically calls check_gac_context() before executing the wrapped
    function. Works with both synchronous and asynchronous functions.

    Args:
        func: The function to wrap (sync or async)

    Returns:
        Wrapped function that checks context before execution

    Raises:
        GACContextError: If the context is unsafe

    Example:
        >>> @require_interactive_context
        ... def commit_changes(message: str) -> str:
        ...     # Only runs in safe contexts
        ...     return f"Committed: {message}"

        >>> @require_interactive_context
        ... async def async_commit(message: str) -> str:
        ...     # Async functions work too
        ...     return f"Async committed: {message}"
    """
    if inspect.iscoroutinefunction(func):
        # Async version
        @functools.wraps(func)
        async def async_wrapper(*args: Any, **kwargs: Any) -> Any:
            check_gac_context()
            return await func(*args, **kwargs)

        return async_wrapper  # type: ignore[return-value]
    else:
        # Sync version
        @functools.wraps(func)
        def sync_wrapper(*args: Any, **kwargs: Any) -> Any:
            check_gac_context()
            return func(*args, **kwargs)

        return sync_wrapper  # type: ignore[return-value]
