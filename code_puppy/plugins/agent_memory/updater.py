"""Debounced batch updater for agent memory.

Provides a MemoryUpdater class that sits between the fact extraction layer
and the storage layer, batching writes with a configurable debounce window.
"""

import logging
import threading
from datetime import datetime, timezone

from code_puppy.async_utils import DebouncedQueue
from code_puppy.plugins.agent_memory.storage import Fact, FileMemoryStorage

logger = logging.getLogger(__name__)

# Default debounce window in milliseconds (30 seconds)
DEFAULT_DEBOUNCE_MS = 30000


class MemoryUpdater:
    """Debounced batch updater for agent memory facts.

    Wraps FileMemoryStorage with a DebouncedQueue to batch fact writes,
    reducing I/O overhead while ensuring data consistency.

    Features:
    - add_fact(): Debounced batch writes with text-based deduplication
    - reinforce_fact(): Immediate confidence update (no debounce)
    - remove_fact(): Immediate removal (no debounce)
    - flush(): Force immediate write of pending facts
    - Configurable debounce window (default: 30 seconds)
    - Automatic graceful flush on shutdown
    - Thread-safe for concurrent access

    Example:
        storage = FileMemoryStorage("my-agent")
        updater = MemoryUpdater(storage, debounce_ms=30000)

        # These get batched and written together after 30s of inactivity
        updater.add_fact({"text": "Python is fun", "confidence": 0.9})
        updater.add_fact({"text": "Rust is fast", "confidence": 0.85})

        # This bypasses debounce and writes immediately
        updater.reinforce_fact("Python is fun")

        # Force flush all pending writes
        updater.flush()
    """

    def __init__(
        self,
        storage: FileMemoryStorage,
        debounce_ms: float = DEFAULT_DEBOUNCE_MS,
    ) -> None:
        """Initialize the memory updater.

        Args:
            storage: FileMemoryStorage instance for persisting facts
            debounce_ms: Debounce window in milliseconds (default: 30000 = 30s)
        """
        self._storage = storage
        self._debounce_ms = debounce_ms
        self._lock = threading.Lock()

        # Create debounced queue for batching fact writes
        # The DebouncedQueue handles the callback execution
        self._queue: DebouncedQueue[Fact] = DebouncedQueue[Fact](
            callback=self._flush_batch,
            interval_ms=debounce_ms,
            daemon_timer=True,
        )

        logger.debug(
            "MemoryUpdater initialized for %s (debounce: %d ms)",
            storage.agent_name,
            debounce_ms,
        )

    def _flush_batch(self, facts: list[Fact]) -> None:
        """Callback invoked by DebouncedQueue when flushing batched facts.

        Deduplicates facts by text (latest wins) before writing to storage.
        Uses batch operation for efficient single-file-write.

        Args:
            facts: List of fact dictionaries to persist
        """
        if not facts:
            return

        # Deduplicate by text - latest fact for each text wins
        # The DebouncedQueue already deduplicates during add(), but we double-check
        # here in case multiple facts with same text ended up in the batch
        unique_facts: dict[str, Fact] = {}
        for fact in facts:
            text = fact.get("text", "")
            if text:
                unique_facts[text] = fact

        # Use batch add for single-file-write efficiency (was: N file writes)
        if unique_facts:
            self._storage.add_facts(list(unique_facts.values()))

        logger.debug(
            "Flushed %d facts to %s memory",
            len(unique_facts),
            self._storage.agent_name,
        )

    def add_fact(self, fact: Fact) -> None:
        """Add a fact to the debounced batch queue.

        Facts with the same 'text' value will be deduplicated, with the
        latest version winning. The write is batched and flushed after
        the debounce window expires.

        Args:
            fact: Fact dictionary with at least a 'text' key.
                  Recommended keys: text, confidence, source_session,
                  created_at, last_reinforced

        Thread-safe: Yes
        """
        if not isinstance(fact, dict) or "text" not in fact:
            logger.warning(
                "Invalid fact format for %s: missing 'text' key",
                self._storage.agent_name,
            )
            return

        # Ensure timestamp if not provided
        if "created_at" not in fact:
            fact["created_at"] = datetime.now(timezone.utc).isoformat()

        # Add to debounced queue - keyed by text for deduplication
        # If same text is added again, it replaces the previous entry
        text = fact["text"]
        self._queue.add(text, fact)

    def reinforce_fact(self, text: str, session_id: str | None = None) -> bool:
        """Reinforce a fact by updating its confidence (bypasses debounce).

        This immediately updates the fact in storage without going through
        the debounced queue. Use when you want immediate persistence.

        Args:
            text: The exact text of the fact to reinforce
            session_id: Optional session ID where reinforcement occurred

        Returns:
            True if the fact was found and reinforced, False otherwise

        Thread-safe: Yes
        """
        return self._storage.reinforce_fact(text, session_id)

    def remove_fact(self, text: str) -> bool:
        """Remove a fact by text (bypasses debounce).

        This immediately removes the fact from storage without going through
        the debounced queue.

        Args:
            text: The exact text of the fact to remove

        Returns:
            True if a fact was removed, False if not found

        Thread-safe: Yes
        """
        return self._storage.remove_fact(text)

    def flush(self) -> list[Fact]:
        """Force flush all pending facts to storage.

        Returns:
            List of flushed facts

        Thread-safe: Yes
        """
        items = self._queue.flush()
        if items:
            # Manually invoke the flush callback since DebouncedQueue.flush()
            # only returns items without calling the callback
            self._flush_batch(items)
        return items

    def pending_count(self) -> int:
        """Return the number of pending facts in the debounce queue.

        Returns:
            Number of facts waiting to be flushed

        Thread-safe: Yes
        """
        return self._queue.pending_count()

    def is_empty(self) -> bool:
        """Check if the debounce queue has no pending facts.

        Returns:
            True if no facts are pending, False otherwise

        Thread-safe: Yes
        """
        return self._queue.is_empty()

    def get_facts(self, min_confidence: float = 0.0) -> list[Fact]:
        """Get all facts from storage with optional confidence filtering.

        Note: This reads from storage, not from the pending queue.
        Use flush() first if you need to ensure pending facts are included.

        Args:
            min_confidence: Minimum confidence threshold (0.0 to 1.0)

        Returns:
            List of facts meeting the confidence threshold

        Thread-safe: Yes
        """
        return self._storage.get_facts(min_confidence)

    def clear(self) -> None:
        """Clear all facts from storage and the pending queue.

        Thread-safe: Yes
        """
        # First flush any pending facts (they'll get cleared too)
        self._queue.flush()
        self._storage.clear()
