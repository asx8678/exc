"""Central token ledger for per-attempt and per-session token accounting.

Records both heuristic estimates (from the internal token estimator) and
provider-reported actuals (from pydantic-ai RequestUsage) for every LLM
request attempt. This enables:

- Drift detection between estimated and actual usage
- Retry cost visibility
- Billing reconciliation
- Session-level token summaries

Usage:
    from code_puppy.token_ledger import TokenLedger, TokenAttempt

    ledger = TokenLedger()
    ledger.record(TokenAttempt(
        model="claude-sonnet-4-20250514",
        estimated_input_tokens=5000,
        provider_input_tokens=5123,
        ...
    ))
    print(ledger.summary())

See also: token flow audit recommendations.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import Any


@dataclass(slots=True)
class TokenAttempt:
    """A single LLM request attempt with token accounting.

    Attributes:
        timestamp: Unix timestamp of the attempt.
        model: Model name used for this attempt.
        estimated_input_tokens: Heuristic estimate before the request.
        estimated_output_tokens: Heuristic estimate of expected output.
        provider_input_tokens: Actual input tokens from provider (None if unavailable).
        provider_output_tokens: Actual output tokens from provider (None if unavailable).
        cache_read_tokens: Tokens served from provider cache (None if unavailable).
        cache_write_tokens: Tokens written to provider cache (None if unavailable).
        retry_number: 0 for first attempt, 1+ for retries.
        success: Whether the attempt succeeded.
        error: Error message if failed (None if success).
        agent_name: Name of the agent that made the request.
        is_overflow: Whether this attempt was a context overflow.
    """

    model: str
    estimated_input_tokens: int = 0
    estimated_output_tokens: int = 0
    provider_input_tokens: int | None = None
    provider_output_tokens: int | None = None
    cache_read_tokens: int | None = None
    cache_write_tokens: int | None = None
    retry_number: int = 0
    success: bool = True
    error: str | None = None
    agent_name: str = ""
    is_overflow: bool = False
    timestamp: float = field(default_factory=time.time)


@dataclass
class TokenLedger:
    """Per-session token ledger accumulating all LLM request attempts.

    Thread-safe for single-writer (the agent run loop) with
    multiple readers (UI, cost plugin, session storage).
    """

    attempts: list[TokenAttempt] = field(default_factory=list)
    _max_attempts: int = field(default=10_000, repr=False)
    _lock: threading.Lock = field(
        default_factory=threading.Lock, repr=False, compare=False
    )

    def record(self, attempt: TokenAttempt) -> None:
        """Record a token attempt.

        Silently drops oldest entries if max_attempts is exceeded
        to prevent unbounded memory growth in long sessions.

        Thread-safe: uses internal lock for mutation.
        """
        with self._lock:
            self.attempts.append(attempt)
            if len(self.attempts) > self._max_attempts:
                # Keep the most recent entries
                self.attempts = self.attempts[-self._max_attempts :]

    @property
    def total_estimated_input(self) -> int:
        """Sum of all estimated input tokens across attempts."""
        return sum(a.estimated_input_tokens for a in self.attempts)

    @property
    def total_estimated_output(self) -> int:
        """Sum of all estimated output tokens across attempts."""
        return sum(a.estimated_output_tokens for a in self.attempts)

    @property
    def total_provider_input(self) -> int | None:
        """Sum of provider-reported input tokens, or None if no provider data."""
        values = [
            a.provider_input_tokens
            for a in self.attempts
            if a.provider_input_tokens is not None
        ]
        return sum(values) if values else None

    @property
    def total_provider_output(self) -> int | None:
        """Sum of provider-reported output tokens, or None if no provider data."""
        values = [
            a.provider_output_tokens
            for a in self.attempts
            if a.provider_output_tokens is not None
        ]
        return sum(values) if values else None

    @property
    def total_cache_read(self) -> int | None:
        """Sum of cache-read tokens, or None if no cache data."""
        values = [
            a.cache_read_tokens
            for a in self.attempts
            if a.cache_read_tokens is not None
        ]
        return sum(values) if values else None

    @property
    def successful_attempts(self) -> int:
        """Count of successful attempts."""
        return sum(1 for a in self.attempts if a.success)

    @property
    def failed_attempts(self) -> int:
        """Count of failed attempts (including retries)."""
        return sum(1 for a in self.attempts if not a.success)

    @property
    def overflow_count(self) -> int:
        """Count of context overflow attempts."""
        return sum(1 for a in self.attempts if a.is_overflow)

    @property
    def retry_count(self) -> int:
        """Count of retry attempts (retry_number > 0)."""
        return sum(1 for a in self.attempts if a.retry_number > 0)

    @property
    def drift_ratio(self) -> float | None:
        """Ratio of estimated to provider-reported input tokens.

        Returns None if no provider data is available.
        A ratio > 1.0 means estimates are higher than actual.
        A ratio < 1.0 means estimates are lower (potential overflow risk).
        """
        provider = self.total_provider_input
        estimated = self.total_estimated_input
        if provider is None or provider == 0 or estimated == 0:
            return None
        return estimated / provider

    @property
    def wasted_tokens(self) -> int:
        """Estimated tokens wasted on failed attempts and retries."""
        return sum(
            a.estimated_input_tokens + a.estimated_output_tokens
            for a in self.attempts
            if not a.success
        )

    @property
    def wasted_tokens_by_retry(self) -> dict[int, int]:
        """Wasted tokens broken down by retry number.

        Returns:
            Dict mapping retry_number -> total wasted estimated tokens.
            Only includes failed attempts.
        """
        breakdown: dict[int, int] = {}
        for a in self.attempts:
            if not a.success:
                wasted = a.estimated_input_tokens + a.estimated_output_tokens
                breakdown[a.retry_number] = breakdown.get(a.retry_number, 0) + wasted
        return breakdown

    @property
    def provider_wasted_tokens(self) -> int | None:
        """Provider-reported tokens wasted on failed attempts and retries.

        Returns the sum of provider-reported tokens for failed attempts,
        or None if no provider data is available.
        """
        values: list[int] = []
        for a in self.attempts:
            if not a.success:
                inp = a.provider_input_tokens or 0
                out = a.provider_output_tokens or 0
                if (
                    a.provider_input_tokens is not None
                    or a.provider_output_tokens is not None
                ):
                    values.append(inp + out)
        return sum(values) if values else None

    def summary(self) -> dict[str, Any]:
        """Return a summary dict suitable for logging or UI display.

        Returns:
            Dictionary with session-level token metrics.
        """
        return {
            "total_attempts": len(self.attempts),
            "successful": self.successful_attempts,
            "failed": self.failed_attempts,
            "retries": self.retry_count,
            "overflows": self.overflow_count,
            "estimated_input_tokens": self.total_estimated_input,
            "estimated_output_tokens": self.total_estimated_output,
            "provider_input_tokens": self.total_provider_input,
            "provider_output_tokens": self.total_provider_output,
            "cache_read_tokens": self.total_cache_read,
            "drift_ratio": self.drift_ratio,
            "wasted_tokens": self.wasted_tokens,
            "wasted_tokens_by_retry": self.wasted_tokens_by_retry,
            "provider_wasted_tokens": self.provider_wasted_tokens,
        }

    def clear(self) -> None:
        """Clear all recorded attempts.

        Thread-safe: uses internal lock for mutation.
        """
        with self._lock:
            self.attempts.clear()

    def to_serializable(self) -> list[dict[str, Any]]:
        """Convert to a JSON-serializable list of dicts for persistence.

        Returns:
            List of attempt dictionaries.
        """
        from dataclasses import asdict

        return [asdict(a) for a in self.attempts]

    @classmethod
    def from_serializable(cls, data: list[dict[str, Any]]) -> TokenLedger:
        """Restore a ledger from serialized data.

        Args:
            data: List of attempt dictionaries (from to_serializable).

        Returns:
            Restored TokenLedger instance.

        Note: Construction is thread-safe, but the returned ledger's
        methods follow the normal thread-safety guarantees.
        """
        ledger = cls()
        with ledger._lock:
            for item in data:
                try:
                    ledger.attempts.append(TokenAttempt(**item))
                except TypeError, ValueError:
                    # Skip malformed entries gracefully
                    continue
        return ledger
