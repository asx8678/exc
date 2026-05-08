"""Shared fallback emit utilities for Code Puppy.

This module provides fallback emit_* functions that can be used when
the full messaging system may not be available or to avoid circular imports.
All functions delegate to the main messaging module when available.
"""

from typing import Any


def emit_error(message: Any) -> None:
    """Emit an error message via the messaging system.

    Args:
        message: The error message to emit (can be any type).
    """
    from code_puppy.messaging import emit_error as _emit_error

    _emit_error(message)


def emit_info(message: Any) -> None:
    """Emit an info message via the messaging system.

    Args:
        message: The info message to emit (can be any type).
    """
    from code_puppy.messaging import emit_info as _emit_info

    _emit_info(message)


def emit_success(message: Any) -> None:
    """Emit a success message via the messaging system.

    Args:
        message: The success message to emit (can be any type).
    """
    from code_puppy.messaging import emit_success as _emit_success

    _emit_success(message)


def emit_warning(message: Any) -> None:
    """Emit a warning message via the messaging system.

    Args:
        message: The warning message to emit (can be any type).
    """
    from code_puppy.messaging import emit_warning as _emit_warning

    _emit_warning(message)


__all__ = [
    "emit_error",
    "emit_info",
    "emit_success",
    "emit_warning",
]
