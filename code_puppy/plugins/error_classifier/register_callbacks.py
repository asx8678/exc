"""Hook registrations for the Error Classifier plugin.

Connects the exception registry to the callback system for automatic
error classification and user-facing messaging.
"""

import logging
from typing import Any

from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_error, emit_info, emit_warning

from .exinfo import ErrorSeverity, ExInfo
from .registry import ExceptionRegistry

logger = logging.getLogger(__name__)

# Track exception IDs we've already emitted to prevent duplicates
_seen_exception_ids: set[int] = set()


def _format_and_emit(ex_info: ExInfo, exception: Exception) -> None:
    """Format and emit a message based on exception severity."""
    message = ex_info.format_message(exception)

    # Emit formatted message based on severity
    if ex_info.severity == ErrorSeverity.CRITICAL:
        emit_error(f"🚨 {message}")
    elif ex_info.severity == ErrorSeverity.ERROR:
        emit_error(f"❌ {message}")
    elif ex_info.severity == ErrorSeverity.WARNING:
        emit_warning(f"⚠️  {message}")
    else:  # INFO
        emit_info(f"ℹ️  {message}")


def _on_agent_exception(exception: Exception, *args: Any, **kwargs: Any) -> None:
    """Classify and handle agent exceptions.

    This callback is triggered whenever an agent encounters an exception.
    It classifies the error, emits user-appropriate messages based on
    severity, and runs any registered callbacks.
    """
    ex_info = ExceptionRegistry.get_ex_info(exception)

    if ex_info is None:
        # Unknown exception - log generically without spamming the user
        logger.debug(
            f"Unhandled exception in agent: {type(exception).__name__}: {exception}"
        )
        return

    # Track this exception to prevent duplicate emissions
    exc_id = id(exception)
    if exc_id in _seen_exception_ids:
        logger.debug(f"Skipping duplicate emission for {ex_info.name}")
        return
    _seen_exception_ids.add(exc_id)

    # Emit formatted message
    _format_and_emit(ex_info, exception)

    # Run callback if registered
    if ex_info.callback is not None:
        try:
            ex_info.callback(exception)
        except Exception as cb_exc:
            logger.error(f"ExInfo callback failed: {cb_exc}")

    # Log structured metadata for debugging
    logger.debug(
        f"Classified exception: {type(exception).__name__} -> "
        f"{ex_info.name} (retry={ex_info.retry}, severity={ex_info.severity.value})"
    )


def _on_agent_run_end(
    agent_name: str,
    model_name: str,
    session_id: str | None = None,
    success: bool = True,
    error: Exception | str | None = None,
    response_text: str | None = None,
    metadata: dict[str, Any] | None = None,
    **kwargs: Any,
) -> None:
    """Classify errors at the end of agent runs.

    This provides a second chance to classify errors that might have been
    wrapped or transformed during the agent run. It also emits user-facing
    messages for errors that weren't emitted by agent_exception (e.g., if
    the error was caught and re-raised, bypassing the exception hook).
    """
    if success or error is None:
        return

    # Handle string errors (shouldn't happen but be defensive)
    if isinstance(error, str):
        logger.debug(f"Agent run ended with string error: {error}")
        return

    # If it's an exception we haven't classified yet, just log
    ex_info = ExceptionRegistry.get_ex_info(error)
    if ex_info is None:
        logger.debug(f"Agent run error not classified: {type(error).__name__}: {error}")
        return

    # Check if we already emitted for this exception instance
    exc_id = id(error)
    if exc_id in _seen_exception_ids:
        logger.debug(
            f"Agent run error already emitted: {ex_info.name} "
            f"(agent={agent_name}, model={model_name})"
        )
        return

    # This error wasn't emitted by agent_exception, so emit it now
    _format_and_emit(ex_info, error)
    _seen_exception_ids.add(exc_id)

    # Run callback if registered
    if ex_info.callback is not None:
        try:
            ex_info.callback(error)
        except Exception as cb_exc:
            logger.error(f"ExInfo callback failed in agent_run_end: {cb_exc}")

    logger.debug(
        f"Agent run ended with classified error: {ex_info.name} "
        f"(agent={agent_name}, model={model_name})"
    )


# Register callbacks
register_callback("agent_exception", _on_agent_exception)
register_callback("agent_run_end", _on_agent_run_end)

logger.debug("Error Classifier plugin callbacks registered")


def clear_seen_exceptions() -> None:
    """Clear the set of seen exception IDs.

    This is primarily useful for testing to reset deduplication state.
    """
    global _seen_exception_ids
    _seen_exception_ids.clear()
    logger.debug("Cleared seen exceptions set")
