"""Shared circuit breaker state enum.

Consolidates the CircuitState enum that was previously duplicated across
resilience.py, adaptive_rate_limiter.py, and mcp_/circuit_breaker.py.

Used by circuit breaker implementations across the codebase. Uses string
values for debuggability (visible in logs and repr).
"""

from enum import Enum


class CircuitState(Enum):
    """State of a circuit breaker.

    States:
        CLOSED: Normal operation. Requests flow through.
        OPEN: Circuit tripped. Requests are rejected immediately.
        HALF_OPEN: Trial state. Limited requests allowed to test recovery.
    """

    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"
