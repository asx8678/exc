"""Built-in exception registrations for common error types."""

import asyncio
import logging

from .exinfo import ErrorSeverity, ExInfo
from .registry import ExceptionRegistry

logger = logging.getLogger(__name__)


def register_builtin_exceptions() -> None:
    """Register known exception types with metadata.

    This should be called once at plugin initialization.
    """
    registry = ExceptionRegistry

    # -----------------------------------------------------------------------
    # Network / Transient Errors (Retryable)
    # -----------------------------------------------------------------------

    registry.register(
        ConnectionError,
        ExInfo(
            name="Connection Failed",
            retry=True,
            description="Could not establish connection to remote service.",
            suggestion="Check network connectivity and retry.",
            retry_after_seconds=5,
        ),
    )

    registry.register(
        TimeoutError,
        ExInfo(
            name="Request Timeout",
            retry=True,
            description="The operation timed out waiting for a response.",
            suggestion="The service may be slow — retry with backoff.",
            retry_after_seconds=10,
        ),
    )

    # asyncio.TimeoutError is a different class from TimeoutError (Python 3.8+)
    # Both need to be registered for comprehensive async support
    registry.register(
        asyncio.TimeoutError,
        ExInfo(
            name="Async Request Timeout",
            retry=True,
            description="The async operation timed out waiting for a response.",
            suggestion="The service may be slow — retry with backoff.",
            retry_after_seconds=10,
        ),
    )

    # -----------------------------------------------------------------------
    # HTTP-like errors (often transient)
    # -----------------------------------------------------------------------

    # These are registered by pattern since they may be wrapped in different
    # exception types by different HTTP libraries.
    # Note: The timeout pattern below handles cases where TimeoutError is wrapped
    # in a generic exception (e.g., HTTP library wraps it with additional context).
    # The direct TimeoutError class registration handles unwrapped timeouts.

    registry.register_pattern(
        r"rate.?limit|429|too many requests",
        ExInfo(
            name="Rate Limited",
            retry=True,
            description="API rate limit exceeded.",
            suggestion="Wait and retry with exponential backoff.",
            retry_after_seconds=60,
        ),
    )

    registry.register_pattern(
        r"5\d{2}|server error|bad gateway|service unavailable",
        ExInfo(
            name="Server Error",
            retry=True,
            description="The server encountered an error.",
            suggestion="This is typically temporary — retry after a brief wait.",
            severity=ErrorSeverity.WARNING,
            retry_after_seconds=30,
        ),
    )

    registry.register_pattern(
        r"timeout|timed out",
        ExInfo(
            name="Timeout",
            retry=True,
            description="The request timed out.",
            suggestion="Retry with increased timeout or check service health.",
            retry_after_seconds=10,
        ),
    )

    # -----------------------------------------------------------------------
    # Auth / Permission Errors (Not retryable without action)
    # -----------------------------------------------------------------------

    registry.register(
        PermissionError,
        ExInfo(
            name="Permission Denied",
            retry=False,
            description="Insufficient permissions to perform this action.",
            suggestion="Check file permissions or run with elevated privileges.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    registry.register_pattern(
        r"unauthorized|401|auth",
        ExInfo(
            name="Unauthorized",
            retry=False,
            description="Authentication failed or credentials missing.",
            suggestion="Check your API key or authentication credentials.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    registry.register_pattern(
        r"forbidden|403",
        ExInfo(
            name="Access Forbidden",
            retry=False,
            description="You don't have permission to access this resource.",
            suggestion="Check your account permissions or contact support.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    # -----------------------------------------------------------------------
    # Quota / Billing Errors (Not retryable)
    # -----------------------------------------------------------------------

    registry.register_pattern(
        r"quota|billing|payment|insufficient.*credit",
        ExInfo(
            name="Account Quota",
            retry=False,
            description="Account quota or billing issue.",
            suggestion="Check your account billing and quota settings.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    # -----------------------------------------------------------------------
    # Client Error (4xx) - Usually not retryable
    # -----------------------------------------------------------------------

    registry.register_pattern(
        r"\b4\d{2}\b|bad request|not found",
        ExInfo(
            name="Client Error",
            retry=False,
            description="The request was malformed or the resource doesn't exist.",
            suggestion="Check your request parameters and try again.",
            severity=ErrorSeverity.ERROR,
        ),
    )

    # -----------------------------------------------------------------------
    # File System Errors
    # -----------------------------------------------------------------------

    registry.register(
        FileNotFoundError,
        ExInfo(
            name="File Not Found",
            retry=False,
            description="The requested file does not exist.",
            suggestion="Check the file path and ensure the file exists.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    registry.register(
        IsADirectoryError,
        ExInfo(
            name="Is a Directory",
            retry=False,
            description="Expected a file but found a directory.",
            suggestion="Check the path and specify a file, not a directory.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    registry.register(
        NotADirectoryError,
        ExInfo(
            name="Not a Directory",
            retry=False,
            description="Expected a directory but found a file.",
            suggestion="Check the path and ensure you're using a directory path where required.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    # -----------------------------------------------------------------------
    # Value / Type Errors (Usually logic errors, not retryable)
    # -----------------------------------------------------------------------

    registry.register(
        ValueError,
        ExInfo(
            name="Invalid Value",
            retry=False,
            description="An invalid value was provided.",
            suggestion="Check the input values and ensure they meet the expected format.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    registry.register(
        TypeError,
        ExInfo(
            name="Type Error",
            retry=False,
            description="An operation was applied to an object of inappropriate type.",
            suggestion="Check that you're passing the correct types to functions.",
            severity=ErrorSeverity.WARNING,
        ),
    )

    # -----------------------------------------------------------------------
    # OSError variations
    # -----------------------------------------------------------------------

    registry.register(
        OSError,
        ExInfo(
            name="Operating System Error",
            retry=False,
            description="A system-level error occurred.",
            suggestion="Check system resources, permissions, and paths.",
            severity=ErrorSeverity.ERROR,
        ),
    )

    # -----------------------------------------------------------------------
    # Keyboard Interrupt (Not retryable - user cancelled)
    # -----------------------------------------------------------------------

    registry.register(
        KeyboardInterrupt,
        ExInfo(
            name="Interrupted",
            retry=False,
            description="The operation was interrupted by the user.",
            suggestion="Resume your workflow when ready.",
            severity=ErrorSeverity.INFO,
        ),
    )

    logger.debug("Registered built-in exception classifications")


def register_custom_pattern(
    pattern: str,
    name: str,
    retry: bool,
    description: str,
    suggestion: str | None = None,
    severity: ErrorSeverity = ErrorSeverity.ERROR,
    retry_after_seconds: int | None = None,
) -> None:
    """Register a custom pattern-based exception classification.

    This allows users or plugins to add their own error patterns
    without modifying the built-in registrations.

    Args:
        pattern: Regex pattern to match against exception strings.
        name: Human-readable name for this error type.
        retry: Whether this error is typically transient.
        description: Brief explanation of what this error means.
        suggestion: Actionable suggestion for resolving the error.
        severity: Severity level for UI display.
        retry_after_seconds: Recommended delay before retry.
    """
    ExceptionRegistry.register_pattern(
        pattern,
        ExInfo(
            name=name,
            retry=retry,
            description=description,
            suggestion=suggestion,
            severity=severity,
            retry_after_seconds=retry_after_seconds,
        ),
    )
