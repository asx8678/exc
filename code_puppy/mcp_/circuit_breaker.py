"""
Circuit breaker implementation for MCP servers to prevent cascading failures.

This module implements the circuit breaker pattern to protect against cascading
failures when MCP servers become unhealthy. The circuit breaker has three states:
- CLOSED: Normal operation, calls pass through
- OPEN: Calls are blocked and fail fast
- HALF_OPEN: Limited calls allowed to test recovery
"""

import asyncio
import inspect
import logging
import time
from collections.abc import Callable
from typing import Any

from code_puppy.circuit_state import CircuitState
from code_puppy.utils.thread_safe_cache import thread_safe_lru_cache

logger = logging.getLogger(__name__)


# Cache for coroutine function checks (avoids repeated introspection on hot paths)
@thread_safe_lru_cache(maxsize=128)
def _is_coro_func(func: Callable) -> bool:
    """Cached check if a function is a coroutine function."""
    return inspect.iscoroutinefunction(func)


class CircuitOpenError(Exception):
    """Raised when circuit breaker is in OPEN state."""

    pass


class CircuitBreaker:
    """
    Circuit breaker to prevent cascading failures in MCP servers.

    The circuit breaker monitors the success/failure rate of operations and
    transitions between states to protect the system from unhealthy dependencies.

    States:
    - CLOSED: Normal operation, all calls allowed
    - OPEN: Circuit is open, all calls fail fast with CircuitOpenError
    - HALF_OPEN: Testing recovery, limited calls allowed

    State Transitions:
    - CLOSED → OPEN: After failure_threshold consecutive failures
    - OPEN → HALF_OPEN: After timeout seconds
    - HALF_OPEN → CLOSED: After success_threshold consecutive successes
    - HALF_OPEN → OPEN: After any failure
    """

    def __init__(
        self, failure_threshold: int = 5, success_threshold: int = 2, timeout: int = 60
    ):
        """
        Initialize circuit breaker.

        Args:
            failure_threshold: Number of consecutive failures before opening circuit
            success_threshold: Number of consecutive successes needed to close circuit from half-open
            timeout: Seconds to wait before transitioning from OPEN to HALF_OPEN
        """
        self.failure_threshold = failure_threshold
        self.success_threshold = success_threshold
        self.timeout = timeout

        self._state = CircuitState.CLOSED
        self._failure_count = 0
        self._success_count = 0
        self._last_failure_time = None
        # Use asyncio.Lock for proper async safety. This prevents event loop blocking
        # that can occur with threading.Lock in async contexts.
        self._lock = asyncio.Lock()
        self._half_open_in_flight = False

        logger.info(
            f"Circuit breaker initialized: failure_threshold={failure_threshold}, "
            f"success_threshold={success_threshold}, timeout={timeout}s"
        )

    async def call(self, func: Callable, *args, **kwargs) -> Any:
        """
        Execute a function through the circuit breaker.

        Args:
            func: Function to execute
            *args: Positional arguments for the function
            **kwargs: Keyword arguments for the function

        Returns:
            Result of the function call

        Raises:
            CircuitOpenError: If circuit is in OPEN state
            Exception: Any exception raised by the wrapped function
        """
        async with self._lock:
            current_state = self._get_current_state()

            if current_state == CircuitState.OPEN:
                logger.warning("Circuit breaker is OPEN, failing fast")
                raise CircuitOpenError("Circuit breaker is open")

            if current_state == CircuitState.HALF_OPEN:
                if self._half_open_in_flight:
                    logger.warning(
                        "Circuit breaker HALF_OPEN with call already in flight, failing fast"
                    )
                    raise CircuitOpenError(
                        "Circuit breaker half-open test call already in flight"
                    )
                # In half-open state, we're testing recovery
                logger.info("Circuit breaker is HALF_OPEN, allowing test call")
                self._half_open_in_flight = True

            checked_state = current_state

        # Execute the function outside the lock to avoid blocking other calls
        try:
            result = (
                await func(*args, **kwargs)
                if _is_coro_func(func)
                else func(*args, **kwargs)
            )
            await self._on_success(checked_state=checked_state)
            return result
        except Exception:
            await self._on_failure(checked_state=checked_state)
            raise

    async def record_success(self) -> None:
        """Record a successful operation."""
        async with self._lock:
            self._on_success_sync()

    async def record_failure(self) -> None:
        """Record a failed operation."""
        async with self._lock:
            self._on_failure_sync()

    async def get_state(self) -> CircuitState:
        """Get current circuit breaker state."""
        async with self._lock:
            return self._get_current_state()

    async def is_open(self) -> bool:
        """Check if circuit breaker is in OPEN state."""
        async with self._lock:
            return self._get_current_state() == CircuitState.OPEN

    async def is_half_open(self) -> bool:
        """Check if circuit breaker is in HALF_OPEN state."""
        async with self._lock:
            return self._get_current_state() == CircuitState.HALF_OPEN

    async def is_closed(self) -> bool:
        """Check if circuit breaker is in CLOSED state."""
        async with self._lock:
            return self._get_current_state() == CircuitState.CLOSED

    async def reset(self) -> None:
        """Reset circuit breaker to CLOSED state and clear counters."""
        async with self._lock:
            logger.info("Resetting circuit breaker to CLOSED state")
            self._state = CircuitState.CLOSED
            self._failure_count = 0
            self._success_count = 0
            self._last_failure_time = None
            self._half_open_in_flight = False

    async def force_open(self) -> None:
        """Force circuit breaker to OPEN state."""
        async with self._lock:
            logger.warning("Forcing circuit breaker to OPEN state")
            self._state = CircuitState.OPEN
            self._last_failure_time = time.time()
            self._half_open_in_flight = False

    async def force_close(self) -> None:
        """Force circuit breaker to CLOSED state and reset counters."""
        async with self._lock:
            logger.info("Forcing circuit breaker to CLOSED state")
            self._state = CircuitState.CLOSED
            self._failure_count = 0
            self._success_count = 0
            self._last_failure_time = None
            self._half_open_in_flight = False

    def _get_current_state(self) -> CircuitState:
        """
        Get the current state, handling automatic transitions.

        This method handles the automatic transition from OPEN to HALF_OPEN
        after the timeout period has elapsed.
        """
        if self._state == CircuitState.OPEN and self._should_attempt_reset():
            logger.info("Timeout reached, transitioning from OPEN to HALF_OPEN")
            self._state = CircuitState.HALF_OPEN
            self._success_count = 0  # Reset success counter for half-open testing

        return self._state

    def _should_attempt_reset(self) -> bool:
        """Check if enough time has passed to attempt reset from OPEN to HALF_OPEN."""
        if self._last_failure_time is None:
            return False

        return time.time() - self._last_failure_time >= self.timeout

    def _on_success_sync(self, checked_state: CircuitState | None = None) -> None:
        """Handle successful operation (synchronous, no lock)."""
        current_state = (
            checked_state if checked_state is not None else self._get_current_state()
        )

        if current_state == CircuitState.CLOSED:
            if self._failure_count > 0:
                logger.debug("Resetting failure count after success")
                self._failure_count = 0

        elif current_state == CircuitState.HALF_OPEN:
            self._success_count += 1
            logger.debug(
                f"Success in HALF_OPEN state: {self._success_count}/{self.success_threshold}"
            )

            self._half_open_in_flight = False

            if self._success_count >= self.success_threshold:
                logger.info(
                    "Success threshold reached, transitioning from HALF_OPEN to CLOSED"
                )
                self._state = CircuitState.CLOSED
                self._failure_count = 0
                self._success_count = 0
                self._last_failure_time = None
                self._half_open_in_flight = False

    def _on_failure_sync(self, checked_state: CircuitState | None = None) -> None:
        """Handle failed operation (synchronous, no lock)."""
        current_state = (
            checked_state if checked_state is not None else self._get_current_state()
        )

        if current_state == CircuitState.CLOSED:
            self._failure_count += 1
            logger.debug(
                f"Failure in CLOSED state: {self._failure_count}/{self.failure_threshold}"
            )

            if self._failure_count >= self.failure_threshold:
                logger.warning(
                    "Failure threshold reached, transitioning from CLOSED to OPEN"
                )
                self._state = CircuitState.OPEN
                self._last_failure_time = time.time()

        elif current_state == CircuitState.HALF_OPEN:
            logger.warning("Failure in HALF_OPEN state, transitioning back to OPEN")
            self._state = CircuitState.OPEN
            self._success_count = 0
            self._last_failure_time = time.time()
            self._half_open_in_flight = False

    async def _on_success(self, checked_state: CircuitState | None = None) -> None:
        """Handle successful operation.

        Uses asyncio.Lock to properly handle async concurrency without
        blocking the event loop.
        """
        async with self._lock:
            self._on_success_sync(checked_state=checked_state)

    async def _on_failure(self, checked_state: CircuitState | None = None) -> None:
        """Handle failed operation.

        Uses asyncio.Lock to properly handle async concurrency without
        blocking the event loop.
        """
        async with self._lock:
            self._on_failure_sync(checked_state=checked_state)
