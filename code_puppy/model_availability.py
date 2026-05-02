"""Circuit breaker for model availability tracking.

Tracks model health states to enable quota-aware failover:
- healthy: model is working normally
- sticky_retry: try once more this turn, then skip
- terminal: quota/capacity exhausted, skip until reset

Inspired by Gemini CLI's ModelAvailabilityService.
"""

import logging
import threading
from dataclasses import dataclass
from typing import Literal

logger = logging.getLogger(__name__)

HealthStatus = Literal["terminal", "sticky_retry"]
UnavailabilityReason = Literal["quota", "capacity", "retry_once_per_turn", "unknown"]


@dataclass(frozen=True)
class ModelAvailabilitySnapshot:
    """Point-in-time availability check for a model."""

    available: bool
    reason: UnavailabilityReason | None = None


@dataclass(frozen=True)
class ModelSelectionResult:
    """Result of selecting the first available model from a list."""

    selected_model: str | None
    skipped: list[tuple[str, UnavailabilityReason]]


class ModelAvailabilityService:
    """Circuit breaker tracking model health for quota-aware failover."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        # model_id -> (status, reason, consumed)
        self._health: dict[str, tuple[HealthStatus, UnavailabilityReason, bool]] = {}

    def mark_terminal(
        self, model_id: str, reason: UnavailabilityReason = "quota"
    ) -> None:
        """Mark model as terminally unavailable (quota/capacity exhausted)."""
        with self._lock:
            self._health[model_id] = ("terminal", reason, False)
            logger.info("Model '%s' marked terminal: %s", model_id, reason)

    def mark_healthy(self, model_id: str) -> None:
        """Mark model as healthy, clearing any failure state."""
        with self._lock:
            if model_id in self._health:
                del self._health[model_id]

    def mark_sticky_retry(self, model_id: str) -> None:
        """Mark model for one more retry this turn, then skip."""
        with self._lock:
            current = self._health.get(model_id)
            # Don't downgrade terminal to sticky
            if current and current[0] == "terminal":
                return
            consumed = False
            if current and current[0] == "sticky_retry":
                consumed = current[2]
            self._health[model_id] = ("sticky_retry", "retry_once_per_turn", consumed)

    def consume_sticky_attempt(self, model_id: str) -> None:
        """Mark the sticky retry as consumed for this turn."""
        with self._lock:
            current = self._health.get(model_id)
            if current and current[0] == "sticky_retry":
                self._health[model_id] = (current[0], current[1], True)

    def snapshot(self, model_id: str) -> ModelAvailabilitySnapshot:
        """Check current availability of a model."""
        with self._lock:
            state = self._health.get(model_id)
            if state is None:
                return ModelAvailabilitySnapshot(available=True)
            status, reason, consumed = state
            if status == "terminal":
                return ModelAvailabilitySnapshot(available=False, reason=reason)
            if status == "sticky_retry" and consumed:
                return ModelAvailabilitySnapshot(available=False, reason=reason)
            return ModelAvailabilitySnapshot(available=True)

    def select_first_available(self, model_ids: list[str]) -> ModelSelectionResult:
        """Select the first available model from an ordered list."""
        skipped: list[tuple[str, UnavailabilityReason]] = []
        for model_id in model_ids:
            snap = self.snapshot(model_id)
            if snap.available:
                return ModelSelectionResult(selected_model=model_id, skipped=skipped)
            skipped.append((model_id, snap.reason or "unknown"))
        return ModelSelectionResult(selected_model=None, skipped=skipped)

    def reset_turn(self) -> None:
        """Reset sticky states for a new conversation turn."""
        with self._lock:
            for model_id, (status, reason, _consumed) in list(self._health.items()):
                if status == "sticky_retry":
                    self._health[model_id] = (status, reason, False)

    def reset(self) -> None:
        """Full reset — clear all health state."""
        with self._lock:
            self._health.clear()


# Module-level singleton
availability_service = ModelAvailabilityService()
model_availability_service = availability_service  # alias for round_robin_model.py

# Last-resort fallback tracking (simple set for backward compatibility)
_last_resort_models: set[str] = set()
_lock = threading.Lock()


def get_last_resort_models() -> list[str]:
    """Return names of all models marked ``is_last_resort=True``.

    Ported from gemini-cli/packages/core/src/fallback/handler.ts:43-56
    (``lastResortPolicy`` fallback). Used by ``LastResortStrategy``
    to provide a guaranteed fallback when primary routing fails.
    """
    with _lock:
        return list(_last_resort_models)


def mark_as_last_resort(model_name: str, value: bool = True) -> None:
    """Mark (or unmark) a model as a last-resort fallback.

    Last-resort models are tried when all preferred routing strategies
    return ``None``, preventing "no model available" fatal errors.
    """
    with _lock:
        if value:
            _last_resort_models.add(model_name)
            logger.debug("Model '%s' marked as last-resort", model_name)
        else:
            _last_resort_models.discard(model_name)
            logger.debug("Model '%s' unmarked as last-resort", model_name)


def is_last_resort(model_name: str) -> bool:
    """Return whether ``model_name`` is marked as a last-resort fallback."""
    with _lock:
        return model_name in _last_resort_models
