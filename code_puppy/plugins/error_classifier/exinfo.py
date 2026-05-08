"""ExInfo dataclass and ErrorSeverity enum for structured exception metadata."""

from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from typing import Any


class ErrorSeverity(Enum):
    """Severity levels for error classification."""

    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"


@dataclass(frozen=True)
class ExInfo:
    """Structured metadata for an exception type.

    Attributes:
        name: Human-readable name for this error type.
        retry: Whether this error is typically transient and safe to retry.
        description: Brief explanation of what this error means.
        suggestion: Actionable suggestion for resolving the error.
        severity: Severity level for UI display.
        retry_after_seconds: Recommended delay before retry (if retry=True).
        callback: Optional hook to run when this exception occurs.
    """

    name: str
    retry: bool
    description: str
    suggestion: str | None = None
    severity: ErrorSeverity = ErrorSeverity.ERROR
    retry_after_seconds: int | None = None
    callback: Callable[[Exception], Any] | None = None

    def format_message(self, exc: Exception) -> str:
        """Format a user-friendly message for this exception."""
        msg = f"[{self.name}] {self.description}"
        if self.suggestion:
            msg += f"\n💡 Suggestion: {self.suggestion}"
        if self.retry:
            msg += "\n🔄 This error may be transient — retry recommended."
        return msg

    def to_dict(self) -> dict[str, Any]:
        """Convert ExInfo to a dictionary for serialization."""
        return {
            "name": self.name,
            "retry": self.retry,
            "description": self.description,
            "suggestion": self.suggestion,
            "severity": self.severity.value,
            "retry_after_seconds": self.retry_after_seconds,
        }
