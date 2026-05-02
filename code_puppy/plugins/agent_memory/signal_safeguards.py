"""Signal safeguards module for agent memory.

Prevents memory poisoning by implementing:
- Caps: Maximum number/weight of preference signals per fact
- Decay: Time-based decay so old signals lose influence
- Rate limiting: Prevents rapid-fire preference signal injection

This module is part of the code-puppy-eed fix for memory poisoning issues.
"""

import logging
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from code_puppy.plugins.agent_memory.config import MemoryConfig
    from code_puppy.plugins.agent_memory.signals import Signal

logger = logging.getLogger(__name__)

# Default safeguard settings (used when config not available)
DEFAULT_MAX_PREFERENCE_SIGNALS = 10
DEFAULT_DECAY_HOURS = 168.0  # 7 days
DEFAULT_RATE_LIMIT_SECONDS = 60


@dataclass(frozen=True)
class SignalApplication:
    """Record of a signal being applied to a fact.

    Attributes:
        signal_type: Type of signal applied (preference, correction, reinforcement)
        applied_at: ISO timestamp when signal was applied
        session_id: Session that triggered the signal
        delta_applied: The confidence delta that was applied
    """

    signal_type: str
    applied_at: str
    session_id: str | None = None
    delta_applied: float = 0.0


@dataclass
class SignalTracker:
    """Tracks signal applications to a specific fact for safeguard enforcement.

    Maintains history of preference signals applied to a fact, enabling
    caps enforcement, decay calculation, and rate limiting.
    """

    fact_text: str
    applications: list[SignalApplication] = field(default_factory=list)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def can_apply_preference(
        self,
        session_id: str | None,
        max_signals: int = DEFAULT_MAX_PREFERENCE_SIGNALS,
        rate_limit_seconds: int = DEFAULT_RATE_LIMIT_SECONDS,
    ) -> tuple[bool, str]:
        """Check if a preference signal can be applied under safeguards.

        Args:
            session_id: Current session identifier for rate limiting
            max_signals: Maximum number of preference signals allowed
            rate_limit_seconds: Minimum seconds between signals from same session

        Returns:
            Tuple of (allowed: bool, reason: str)
        """
        with self._lock:
            now = datetime.now(timezone.utc)

            # Count existing preference signals (after decay)
            preference_count = self._count_active_preferences(now)

            # Check cap
            if preference_count >= max_signals:
                return (
                    False,
                    f"Preference signal cap reached ({max_signals} max) for fact",
                )

            # Check rate limiting for same session
            if session_id and self._is_rate_limited(
                session_id, rate_limit_seconds, now
            ):
                return (
                    False,
                    f"Rate limit active: wait {rate_limit_seconds}s between preference signals",
                )

            return (True, "")

    def _count_active_preferences(self, now: datetime) -> int:
        """Count preference signals that haven't fully decayed.

        Uses a simple decay model: signals older than decay window count as 0,
        signals within window count as 1 (linear decay could be added later).

        Args:
            now: Current datetime for decay calculation

        Returns:
            Count of active (non-decayed) preference signals
        """
        active_count = 0
        for app in self.applications:
            if app.signal_type == "PREFERENCE":
                # Parse timestamp
                try:
                    applied_time = datetime.fromisoformat(app.applied_at)
                    # Consider it active if within reasonable timeframe (simplified)
                    # Full decay implementation could use config.decay_hours
                    age_hours = (now - applied_time).total_seconds() / 3600
                    # Signal counts less as it ages - simplified model
                    if age_hours < 168:  # 7 days
                        active_count += 1
                except ValueError, TypeError:
                    # Malformed timestamp, count as expired
                    pass
        return active_count

    def _is_rate_limited(
        self, session_id: str, rate_limit_seconds: int, now: datetime
    ) -> bool:
        """Check if rate limit applies for this session.

        Args:
            session_id: Session to check
            rate_limit_seconds: Rate limit window
            now: Current datetime

        Returns:
            True if rate limited, False otherwise
        """
        for app in reversed(self.applications):  # Check most recent first
            if app.signal_type == "PREFERENCE" and app.session_id == session_id:
                try:
                    applied_time = datetime.fromisoformat(app.applied_at)
                    elapsed = (now - applied_time).total_seconds()
                    if elapsed < rate_limit_seconds:
                        return True
                except ValueError, TypeError:
                    continue
        return False

    def record_application(
        self,
        signal_type: str,
        session_id: str | None,
        delta_applied: float,
    ) -> None:
        """Record that a signal was applied to this fact.

        Args:
            signal_type: Type of signal applied
            session_id: Session that triggered the signal
            delta_applied: The confidence delta that was applied
        """
        with self._lock:
            application = SignalApplication(
                signal_type=signal_type,
                applied_at=datetime.now(timezone.utc).isoformat(),
                session_id=session_id,
                delta_applied=delta_applied,
            )
            self.applications.append(application)

            # Cleanup: limit history size to prevent unbounded growth
            if len(self.applications) >= 100:
                # Keep most recent 50, discard oldest
                self.applications = self.applications[-50:]


class SafeguardManager:
    """Manages signal safeguards across all facts for an agent.

    Provides centralized rate limiting, caps enforcement, and decay tracking
    for preference signals to prevent memory poisoning.
    """

    def __init__(
        self,
        max_preference_signals: int = DEFAULT_MAX_PREFERENCE_SIGNALS,
        decay_hours: float = DEFAULT_DECAY_HOURS,
        rate_limit_seconds: int = DEFAULT_RATE_LIMIT_SECONDS,
    ) -> None:
        """Initialize the safeguard manager.

        Args:
            max_preference_signals: Maximum preference signals per fact
            decay_hours: Hours after which signals are considered decayed
            rate_limit_seconds: Minimum seconds between signals from same session
        """
        self.max_preference_signals = max_preference_signals
        self.decay_hours = decay_hours
        self.rate_limit_seconds = rate_limit_seconds

        # Per-fact signal trackers
        self._trackers: dict[str, SignalTracker] = {}
        self._lock = threading.Lock()

    def get_tracker(self, fact_text: str) -> SignalTracker:
        """Get or create a signal tracker for a fact.

        Args:
            fact_text: The text of the fact to track

        Returns:
            SignalTracker for this fact
        """
        with self._lock:
            if fact_text not in self._trackers:
                self._trackers[fact_text] = SignalTracker(fact_text=fact_text)
            return self._trackers[fact_text]

    def can_apply_signal(
        self,
        fact_text: str,
        signal: "Signal",
        session_id: str | None,
    ) -> tuple[bool, str]:
        """Check if a signal can be applied to a fact under safeguards.

        Args:
            fact_text: Text of the fact being modified
            signal: The signal to potentially apply
            session_id: Current session identifier

        Returns:
            Tuple of (allowed: bool, reason: str)
        """
        # Only preference signals have safeguards currently
        if signal.signal_type.name != "PREFERENCE":
            return (True, "")  # Corrections and reinforcements allowed freely

        tracker = self.get_tracker(fact_text)
        return tracker.can_apply_preference(
            session_id,
            max_signals=self.max_preference_signals,
            rate_limit_seconds=self.rate_limit_seconds,
        )

    def record_signal_applied(
        self,
        fact_text: str,
        signal: "Signal",
        session_id: str | None,
    ) -> None:
        """Record that a signal was successfully applied.

        Args:
            fact_text: Text of the fact that was modified
            signal: The signal that was applied
            session_id: Session that triggered the signal
        """
        tracker = self.get_tracker(fact_text)
        tracker.record_application(
            signal_type=signal.signal_type.name,
            session_id=session_id,
            delta_applied=signal.confidence_delta,
        )

    def calculate_decayed_delta(
        self,
        fact_text: str,
        base_delta: float,
    ) -> float:
        """Calculate confidence delta after applying decay.

        Args:
            fact_text: Text of the fact
            base_delta: Original delta from the signal

        Returns:
            Decayed delta value (may be reduced based on signal age)
        """
        # Simplified decay: just return the base delta
        # Full implementation would reduce influence based on signal age
        # and the configured decay_hours
        return base_delta

    def get_signal_stats(self, fact_text: str) -> dict[str, Any]:
        """Get signal statistics for a fact.

        Args:
            fact_text: Text of the fact

        Returns:
            Dictionary with signal statistics
        """
        tracker = self._trackers.get(fact_text)
        if not tracker:
            return {
                "total_signals": 0,
                "preference_signals": 0,
                "recent_signals": 0,
            }

        now = datetime.now(timezone.utc)
        total = len(tracker.applications)
        preferences = sum(
            1 for a in tracker.applications if a.signal_type == "PREFERENCE"
        )
        recent = tracker._count_active_preferences(now)

        return {
            "total_signals": total,
            "preference_signals": preferences,
            "recent_signals": recent,
        }


# Global safeguard managers per agent (cached)
_safeguard_managers: dict[str, SafeguardManager] = {}
_safeguard_lock = threading.Lock()


def get_safeguard_manager(
    agent_name: str,
    config: "MemoryConfig" | None = None,
) -> SafeguardManager:
    """Get or create a safeguard manager for an agent.

    Args:
        agent_name: Name of the agent
        config: Optional memory config for safeguard settings

    Returns:
        SafeguardManager for this agent
    """
    with _safeguard_lock:
        if agent_name not in _safeguard_managers:
            if config:
                manager = SafeguardManager(
                    max_preference_signals=config.max_preference_signals_per_fact,
                    decay_hours=config.preference_signal_decay_hours,
                    rate_limit_seconds=config.preference_rate_limit_seconds,
                )
            else:
                manager = SafeguardManager()
            _safeguard_managers[agent_name] = manager
        return _safeguard_managers[agent_name]


def clear_safeguard_manager(agent_name: str) -> None:
    """Clear the safeguard manager for an agent (useful for testing).

    Args:
        agent_name: Name of the agent to clear
    """
    with _safeguard_lock:
        _safeguard_managers.pop(agent_name, None)


def clear_all_safeguard_managers() -> None:
    """Clear all safeguard managers (useful for testing)."""
    with _safeguard_lock:
        _safeguard_managers.clear()
