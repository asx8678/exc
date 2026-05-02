"""Central registry for exception metadata."""

import logging
import re
import threading

from .exinfo import ExInfo

logger = logging.getLogger(__name__)


class ExceptionRegistry:
    """Central registry for exception metadata.

    Maintains mappings from exception classes to ExInfo metadata,
    enabling automatic classification of errors into retryable vs permanent,
    with actionable guidance for users.

    This class is thread-safe for concurrent registrations.
    """

    _registry: dict[type[Exception], ExInfo] = {}
    _patterns: list[tuple[re.Pattern, ExInfo]] = []
    _lock: threading.Lock = threading.Lock()

    @classmethod
    def register(
        cls,
        exc_class: type[Exception],
        ex_info: ExInfo,
    ) -> None:
        """Register ExInfo for an exception class.

        Args:
            exc_class: The exception class to register.
            ex_info: The metadata for this exception type.
        """
        with cls._lock:
            cls._registry[exc_class] = ex_info
        logger.debug(f"Registered {exc_class.__name__} -> {ex_info.name}")

    @classmethod
    def register_pattern(
        cls,
        pattern: str,
        ex_info: ExInfo,
        flags: int = re.IGNORECASE,
    ) -> None:
        """Register ExInfo for exceptions matching a regex pattern.

        This is a fallback for exceptions that can't be matched by class,
        such as HTTP errors wrapped in generic exception types.

        Args:
            pattern: Regex pattern to match against exception strings.
            ex_info: The metadata for matching exceptions.
            flags: Regex flags (default: IGNORECASE).

        Raises:
            re.PatternError: If the pattern is invalid regex.
        """
        try:
            compiled = re.compile(pattern, flags)
        except re.PatternError as e:
            logger.error(f"Invalid regex pattern '{pattern}': {e}")
            raise

        with cls._lock:
            cls._patterns.append((compiled, ex_info))
        logger.debug(f"Registered pattern '{pattern}' -> {ex_info.name}")

    @classmethod
    def get_ex_info(cls, exc: Exception) -> ExInfo | None:
        """Look up ExInfo for an exception instance.

        Tries exact class match first, then MRO (parent classes),
        then falls back to pattern matching on the exception string.

        Args:
            exc: The exception instance to classify.

        Returns:
            ExInfo if found, None otherwise.
        """
        exc_class = type(exc)

        # Direct lookup
        if exc_class in cls._registry:
            return cls._registry[exc_class]

        # MRO lookup (check parent classes in order)
        for parent in exc_class.__mro__[1:]:  # Skip self
            if parent in cls._registry:
                return cls._registry[parent]

        # Pattern fallback for string exceptions
        exc_str = str(exc)
        for regex, ex_info in cls._patterns:
            if regex.search(exc_str):
                return ex_info

        return None

    @classmethod
    def classify(cls, exc: Exception) -> tuple[bool, ExInfo | None]:
        """Classify an exception.

        Args:
            exc: The exception to classify.

        Returns:
            Tuple of (should_retry, ex_info). If ex_info is None,
            the exception is unknown and should not be retried by default.
        """
        ex_info = cls.get_ex_info(exc)
        if ex_info is not None:
            return ex_info.retry, ex_info
        # Default: unknown errors are not retryable
        return False, None

    @classmethod
    def should_retry(cls, exc: Exception) -> bool:
        """Quick check if an exception should be retried.

        Args:
            exc: The exception to check.

        Returns:
            True if the exception is retryable, False otherwise.
        """
        should_retry, _ = cls.classify(exc)
        return should_retry

    @classmethod
    def get_retry_delay(cls, exc: Exception) -> int:
        """Get recommended retry delay for an exception.

        Args:
            exc: The exception to check.

        Returns:
            Recommended delay in seconds, or 0 if unknown/not retryable.
        """
        ex_info = cls.get_ex_info(exc)
        if ex_info is not None and ex_info.retry:
            return ex_info.retry_after_seconds or 0
        return 0

    @classmethod
    def clear(cls) -> None:
        """Clear all registrations. Useful for testing."""
        with cls._lock:
            cls._registry.clear()
            cls._patterns.clear()

    @classmethod
    def list_registered(cls) -> dict[str, list[str]]:
        """List all registered exception classes and patterns.

        Returns:
            Dict with 'classes' and 'patterns' keys listing registered items.
        """
        return {
            "classes": [cls.__name__ for cls in cls._registry.keys()],
            "patterns": [pattern.pattern for pattern, _ in cls._patterns],
        }
