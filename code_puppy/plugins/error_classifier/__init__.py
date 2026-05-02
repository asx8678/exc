"""Error Classifier - Structured exception registry for Code Puppy.

Centralizes exception metadata and provides automatic error classification.

Example usage:
    from code_puppy.plugins.error_classifier import ExceptionRegistry, ExInfo
    from code_puppy.plugins.error_classifier.exinfo import ErrorSeverity

    # Register a custom exception
    ExceptionRegistry.register(
        MyCustomError,
        ExInfo(
            name="My Custom Error",
            retry=True,
            description="Something specific went wrong.",
            suggestion="Try restarting the service.",
        )
    )

    # Classify an exception
    should_retry, ex_info = ExceptionRegistry.classify(some_exception)

See DESIGN.md for detailed implementation details.
"""

__version__ = "0.1.0"

from .builtins import register_builtin_exceptions, register_custom_pattern
from .exinfo import ErrorSeverity, ExInfo
from .registry import ExceptionRegistry

# Register built-in exception classifications on import
register_builtin_exceptions()

__all__ = [
    "ErrorSeverity",
    "ExInfo",
    "ExceptionRegistry",
    "register_builtin_exceptions",
    "register_custom_pattern",
]
