"""Typed fatal errors with distinct exit codes for CI/supervisor branching.

Ported from gemini-cli's TypeScript error hierarchy.

Instead of generic sys.exit(1) everywhere, raise typed exceptions that carry
distinct process exit codes. This allows CI/supervisor scripts to branch on
exit codes without parsing stderr.

Example:
    raise FatalAuthenticationError("API key invalid")
    # exits with code 41

Exit code mapping (matches gemini-cli):
    41 - Authentication failed
    42 - Invalid input
    44 - Sandbox error
    52 - Configuration error
    53 - Turn limit reached
    54 - Tool execution failed
    130 - Cancelled by user (standard SIGINT code)
"""

__all__ = [
    "FatalError",
    "FatalAuthenticationError",
    "FatalInputError",
    "FatalSandboxError",
    "FatalConfigError",
    "FatalTurnLimitedError",
    "FatalToolExecutionError",
    "FatalCancellationError",
]


class FatalError(Exception):
    """Base class for fatal errors with a specific exit code.

    Attributes:
        exit_code: The process exit code to use when this error is caught.
    """

    def __init__(self, message: str = "", exit_code: int = 1) -> None:
        """Initialize a FatalError.

        Args:
            message: Human-readable error message. If empty, a default is used.
            exit_code: The exit code for sys.exit().
        """
        super().__init__(message)
        self.exit_code = exit_code


class FatalAuthenticationError(FatalError):
    """Authentication failed (exit code 41)."""

    def __init__(self, message: str = "") -> None:
        if not message:
            message = "Authentication failed"
        super().__init__(message, exit_code=41)


class FatalInputError(FatalError):
    """Invalid input provided (exit code 42)."""

    def __init__(self, message: str = "") -> None:
        if not message:
            message = "Invalid input"
        super().__init__(message, exit_code=42)


class FatalSandboxError(FatalError):
    """Sandbox execution error (exit code 44)."""

    def __init__(self, message: str = "") -> None:
        if not message:
            message = "Sandbox error"
        super().__init__(message, exit_code=44)


class FatalConfigError(FatalError):
    """Configuration error (exit code 52)."""

    def __init__(self, message: str = "") -> None:
        if not message:
            message = "Configuration error"
        super().__init__(message, exit_code=52)


class FatalTurnLimitedError(FatalError):
    """Turn limit reached (exit code 53)."""

    def __init__(self, message: str = "") -> None:
        if not message:
            message = "Turn limit reached"
        super().__init__(message, exit_code=53)


class FatalToolExecutionError(FatalError):
    """Tool execution failed (exit code 54)."""

    def __init__(self, message: str = "") -> None:
        if not message:
            message = "Tool execution failed"
        super().__init__(message, exit_code=54)


class FatalCancellationError(FatalError):
    """Cancelled by user (exit code 130, standard SIGINT code)."""

    def __init__(self, message: str = "") -> None:
        if not message:
            message = "Cancelled by user"
        super().__init__(message, exit_code=130)
