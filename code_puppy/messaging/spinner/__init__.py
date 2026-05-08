"""
Shared spinner implementation for CLI mode.

This module provides consistent spinner animations across different UI modes.
Also includes LongSpinnerWithWarning variant that flashes a warning after 3s.
"""

import asyncio
import itertools
import logging

from .console_spinner import ConsoleSpinner
from .spinner_base import SpinnerBase

logger = logging.getLogger(__name__)

# Keep track of all active spinners to manage them globally
_active_spinners = []

# Monotonically-increasing counter; each call to long_spinner_with_warning
# increments this, and any in-flight flasher checks its captured value to
# determine if it's stale.
_warning_loop_counter: itertools.count = itertools.count(1)
_current_warning_loop: int = 0
_current_warning_task: asyncio.Task | None = None


def register_spinner(spinner):
    """Register an active spinner to be managed globally."""
    if spinner not in _active_spinners:
        _active_spinners.append(spinner)


def unregister_spinner(spinner):
    """Remove a spinner from global management."""
    if spinner in _active_spinners:
        _active_spinners.remove(spinner)


def pause_all_spinners():
    """Pause all active spinners.

    No-op when called from a sub-agent context to prevent
    parallel sub-agents from interfering with the main spinner.
    """
    # Lazy import to avoid circular dependency
    from code_puppy.tools.subagent_context import is_subagent

    if is_subagent():
        return  # Sub-agents don't control the main spinner
    for spinner in _active_spinners:
        try:
            spinner.pause()
        except Exception:
            # Ignore errors if a spinner can't be paused
            pass


def resume_all_spinners():
    """Resume all active spinners.

    No-op when called from a sub-agent context to prevent
    parallel sub-agents from interfering with the main spinner.
    """
    # Lazy import to avoid circular dependency
    from code_puppy.tools.subagent_context import is_subagent

    if is_subagent():
        return  # Sub-agents don't control the main spinner
    for spinner in _active_spinners:
        try:
            spinner.resume()
        except Exception:
            # Ignore errors if a spinner can't be resumed
            pass


def update_spinner_context(info: str) -> None:
    """Update the shared context information displayed beside active spinners."""
    SpinnerBase.set_context_info(info)


def clear_spinner_context() -> None:
    """Clear any context information displayed beside active spinners."""
    SpinnerBase.clear_context_info()


def _start_spinner_impl(msg: str) -> None:
    """Update the spinner display text.

    This updates SpinnerBase.MESSAGE which is used by all spinners.
    Note: The current ConsoleSpinner uses THINKING_MESSAGE, so we update that too.

    Args:
        msg: The message to display with the spinner.
    """
    # Update the base class message - this is the hook for the real spinner backend
    SpinnerBase.MESSAGE = msg
    SpinnerBase.THINKING_MESSAGE = msg


async def long_spinner_with_warning(
    message: str,
    warning: str,
    *,
    initial_delay_s: float = 3.0,
    warning_duration_s: float = 2.0,
) -> None:
    """Start a spinner that flashes a warning message after a long wait.

    After ``initial_delay_s`` seconds, the spinner text switches to
    ``warning`` for ``warning_duration_s`` seconds, then flips back to
    ``message``, and repeats the cycle.

    If a new ``long_spinner_with_warning`` call happens (or the spinner is
    stopped), the stale flash loop is cancelled via a monotonically-
    increasing loop counter — matches plandex's atomic.AddInt32 pattern.

    This function itself returns immediately after scheduling the flasher
    and starting the initial spinner message. The flasher runs in the
    background until cancelled.

    Args:
        message: Primary spinner text.
        warning: Text to flash after initial_delay_s (e.g. "This is taking longer than expected...").
        initial_delay_s: Seconds before the first warning flash.
        warning_duration_s: How long the warning is shown before reverting.
    """
    global _current_warning_loop, _current_warning_task

    # Advance the counter; capture our loop id
    _current_warning_loop = next(_warning_loop_counter)
    my_loop = _current_warning_loop

    # Cancel any existing flasher task
    if _current_warning_task is not None and not _current_warning_task.done():
        _current_warning_task.cancel()

    # Start the initial spinner with the main message
    _start_spinner_impl(message)

    async def _flash_loop() -> None:
        try:
            while True:
                await asyncio.sleep(initial_delay_s)
                if _current_warning_loop != my_loop:
                    return  # stale; newer call superseded us
                _start_spinner_impl(warning)
                await asyncio.sleep(warning_duration_s)
                if _current_warning_loop != my_loop:
                    return
                _start_spinner_impl(message)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.debug("long_spinner_with_warning flasher exited: %s", e)

    _current_warning_task = asyncio.create_task(_flash_loop())


def stop_long_spinner_with_warning() -> None:
    """Cancel any in-flight warning flasher and advance the loop counter."""
    global _current_warning_loop, _current_warning_task
    _current_warning_loop = next(_warning_loop_counter)
    if _current_warning_task is not None and not _current_warning_task.done():
        _current_warning_task.cancel()
    _current_warning_task = None


__all__ = [
    "SpinnerBase",
    "ConsoleSpinner",
    "register_spinner",
    "unregister_spinner",
    "pause_all_spinners",
    "resume_all_spinners",
    "update_spinner_context",
    "clear_spinner_context",
    # Warning spinner functions
    "long_spinner_with_warning",
    "stop_long_spinner_with_warning",
    # Test hook
    "_start_spinner_impl",
]
