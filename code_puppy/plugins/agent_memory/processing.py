"""Signal processing and fact extraction handlers for agent memory.

Handles applying signal-based confidence updates and async fact extraction
from conversation messages. Includes signal safeguards (code-puppy-eed):
- Caps: Maximum number of preference signals per fact
- Decay: Time-based decay so old signals lose influence
- Rate limiting: Prevents rapid-fire preference signal injection

Async correctness notes (code-puppy-48p):
- All async tasks are tracked via _async_task_tracker for proper error handling
- Fire-and-forget patterns eliminated: all async operations are either awaited
  or tracked with error callbacks
"""

import asyncio
import logging
import re
from datetime import datetime, timezone
from typing import Any

from .core import _get_storage, _get_updater, get_config, get_detector, get_extractor
from .messaging import _extract_user_messages
from .signal_safeguards import get_safeguard_manager
from .signals import SignalType

logger = logging.getLogger(__name__)

# Global async task tracker for fire-and-forget prevention (code-puppy-48p)
_pending_tasks: set[asyncio.Task] = set()
_task_lock = asyncio.Lock() if asyncio._get_running_loop() else None  # Created lazily


async def _track_task(coro, name: str = "unnamed") -> Any:
    """Track an async task and handle errors properly.

    Prevents fire-and-forget patterns by keeping strong references to tasks
    and logging errors when they complete.

    Args:
        coro: The coroutine to track
        name: Task name for logging

    Returns:
        The result of the coroutine
    """
    task = asyncio.create_task(coro)
    task.set_name(f"agent_memory:{name}")

    # Store strong reference to prevent GC
    _pending_tasks.add(task)

    def _on_task_done(t: asyncio.Task) -> None:
        """Callback when task completes - handles errors and cleanup."""
        _pending_tasks.discard(t)

        if not t.cancelled():
            exc = t.exception()
            if exc:
                logger.warning(f"Task {name} failed: {exc}")

    task.add_done_callback(_on_task_done)
    return await task


def _schedule_tracked_task(coro, name: str = "unnamed") -> asyncio.Task | None:
    """Schedule a tracked async task from sync code.

    This should be used instead of fire-and-forget patterns.
    Errors will be logged when the task completes.

    Args:
        coro: The coroutine to schedule
        name: Task name for logging

    Returns:
        The created task, or None if no event loop is running
    """
    try:
        loop = asyncio.get_running_loop()
        task = loop.create_task(coro)
        task.set_name(f"agent_memory:{name}")

        _pending_tasks.add(task)

        def _on_task_done(t: asyncio.Task) -> None:
            """Callback when task completes - handles errors and cleanup."""
            _pending_tasks.discard(t)

            if not t.cancelled():
                exc = t.exception()
                if exc:
                    logger.warning(f"Background task {name} failed: {exc}")

        task.add_done_callback(_on_task_done)
        return task

    except RuntimeError:
        # No event loop running - caller should handle differently
        return None


def _apply_signal_confidence_updates(
    agent_name: str, messages: list[dict[str, Any]], session_id: str | None
) -> int:
    """Apply confidence adjustments based on detected signals.

    Implements signal safeguards (code-puppy-eed):
    - Caps: Maximum number of preference signals per fact
    - Decay: Time-based decay so old signals lose influence
    - Rate limiting: Prevents rapid-fire preference signal injection

    Performance optimization (code-puppy-48p):
    - Uses batch updates instead of individual writes for O(1) file I/O
    - Collects all updates and writes once at the end

    Args:
        agent_name: Name of the agent
        messages: Conversation messages to analyze
        session_id: Optional session identifier

    Returns:
        Number of facts updated
    """
    detector = get_detector()
    if not detector:
        return 0

    updater = _get_updater(agent_name)
    storage = _get_storage(agent_name)

    # Get safeguard manager for this agent
    config = get_config()
    safeguard_manager = get_safeguard_manager(agent_name, config)

    user_messages = _extract_user_messages(messages)

    # Load existing facts for matching
    existing_facts = storage.get_facts(min_confidence=0.0)
    fact_texts = {f.get("text", ""): f for f in existing_facts}

    # Collect all updates to apply in batch (code-puppy-48p optimization)
    # Structure: {fact_text: {field: value}}
    batch_updates: dict[str, dict[str, Any]] = {}
    facts_reinforced: set[str] = set()
    updated_count = 0

    for msg in user_messages:
        text = msg.get("content", "")
        if not text:
            continue

        # Detect signals in this message
        signals = detector.analyze_message(text)

        for signal in signals:
            # Try to match signal with existing facts
            # Simple approach: check if any fact text appears in the message
            for fact_text, fact in fact_texts.items():
                if fact_text and len(fact_text) > 10:
                    # Use word-boundary matching to avoid substring false positives
                    # e.g., "the cat" should not match "the category"
                    fact_lower = fact_text.lower()
                    msg_lower = text.lower()

                    # Check for word-level overlap instead of simple substring
                    if _has_word_overlap(fact_lower, msg_lower):
                        # Apply signal safeguards for preference signals
                        if signal.signal_type == SignalType.PREFERENCE:
                            allowed, reason = safeguard_manager.can_apply_signal(
                                fact_text, signal, session_id
                            )
                            if not allowed:
                                logger.debug(
                                    f"Blocked preference signal for fact '{fact_text[:50]}...': {reason}"
                                )
                                break  # Skip this signal

                        # Apply confidence delta
                        current_conf = fact.get("confidence", 0.5)
                        new_conf = max(
                            0.0, min(1.0, current_conf + signal.confidence_delta)
                        )

                        if new_conf != current_conf:
                            # Collect for batch update instead of immediate write
                            if fact_text not in batch_updates:
                                batch_updates[fact_text] = {}
                            batch_updates[fact_text]["confidence"] = new_conf
                            batch_updates[fact_text]["last_reinforced"] = (
                                signal.matched_text
                            )
                            updated_count += 1
                            logger.debug(
                                f"Queued confidence update for fact '{fact_text[:50]}...' "
                                f"({current_conf:.2f} -> {new_conf:.2f}) via {signal.signal_type.name}"
                            )

                            # Record signal application for safeguard tracking
                            if signal.signal_type == SignalType.PREFERENCE:
                                safeguard_manager.record_signal_applied(
                                    fact_text, signal, session_id
                                )

                        # If reinforcement signal, also update last_reinforced
                        if signal.signal_type == SignalType.REINFORCEMENT:
                            facts_reinforced.add(fact_text)

                        break  # Only update one fact per signal

    # Apply all updates in batch (single file write vs N writes - code-puppy-48p)
    if batch_updates:
        storage.update_facts(batch_updates)

    # Apply reinforcements (bypasses debounce - these are immediate)
    for fact_text in facts_reinforced:
        updater.reinforce_fact(fact_text, session_id)

    return updated_count


async def _async_extract_and_store_facts(
    agent_name: str,
    messages: list[dict[str, Any]],
    session_id: str | None,
) -> int:
    """Async extraction and storage of facts.

    Errors are properly propagated to task tracking (code-puppy-48p).

    Args:
        agent_name: Name of the agent
        messages: Conversation messages to extract from
        session_id: Optional session identifier

    Returns:
        Number of facts extracted and queued

    Raises:
        Exception: Re-raises extraction errors for task tracking to catch
    """
    extractor = get_extractor()
    config = get_config()

    if not extractor or not config:
        return 0

    if not config.extraction_enabled:
        return 0

    # Extract facts from conversation
    extracted = await extractor.extract_facts(messages)

    if not extracted:
        return 0

    # Queue facts for storage
    updater = _get_updater(agent_name)

    for fact in extracted:
        fact_dict: dict[str, Any] = {
            "text": fact.text,
            "confidence": fact.confidence,
            "source_session": session_id,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        updater.add_fact(fact_dict)

    logger.debug(
        f"Queued {len(extracted)} facts for extraction from {agent_name} session"
    )
    return len(extracted)


def _has_word_overlap(text1: str, text2: str, min_words: int = 2) -> bool:
    """Check if two texts share significant word-level overlap.

    Uses token-based matching to avoid substring false positives
    (e.g., "the cat" vs "the category").

    Args:
        text1: First text to compare
        text2: Second text to compare
        min_words: Minimum number of words that must overlap

    Returns:
        True if significant word overlap detected
    """
    # Extract words (alphanumeric sequences of 3+ chars)
    words1 = set(w.lower() for w in re.findall(r"\b[a-zA-Z0-9]{3,}\b", text1))
    words2 = set(w.lower() for w in re.findall(r"\b[a-zA-Z0-9]{3,}\b", text2))

    if not words1 or not words2:
        # Fallback: check for substring if no words found
        return text1 in text2 or text2 in text1

    # Check for significant word overlap
    overlap = words1 & words2

    # Also check if one text contains the other as a phrase
    contains_phrase = text1 in text2 or text2 in text1

    return len(overlap) >= min_words or contains_phrase


def cleanup_async_tasks() -> int:
    """Clean up any pending async tasks on shutdown.

    Waits briefly for tasks to complete, cancels any that are still running.

    Returns:
        Number of tasks cleaned up
    """
    count = len(_pending_tasks)
    if not count:
        return 0

    # Make a copy since the set will be modified during iteration
    tasks = list(_pending_tasks)

    for task in tasks:
        if not task.done():
            # Give tasks a brief moment to complete gracefully
            if asyncio._get_running_loop():
                # We're in async context - can't wait synchronously
                task.cancel()
            # Task will be removed from _pending_tasks by its done callback

    return count


def _schedule_fact_extraction(
    agent_name: str,
    messages: list[dict[str, Any]],
    session_id: str | None,
) -> asyncio.Task | None:
    """Schedule async fact extraction with proper error tracking.

    Fixed (code-puppy-48p): Previously used fire-and-forget pattern that
    lost errors. Now properly tracks the task and logs errors.

    Args:
        agent_name: Name of the agent
        messages: Conversation messages
        session_id: Optional session identifier

    Returns:
        The scheduled task if in async context, None if no event loop
    """
    # Use tracked task scheduling (code-puppy-48p fix)
    # Create coroutine but don't start it yet
    coro = _async_extract_and_store_facts(agent_name, messages, session_id)

    task = _schedule_tracked_task(coro, name=f"fact_extraction:{agent_name}")

    if task is None:
        # No event loop running - close the coroutine to avoid warning
        # and schedule synchronously in thread pool instead
        coro.close()

        # Schedule synchronously in thread pool with error handling
        try:
            from code_puppy.async_utils import run_async_sync

            # Wrap to catch and log errors (otherwise they're lost)
            def _sync_extract_with_error_handling():
                try:
                    # Create fresh coroutine for this call
                    fresh_coro = _async_extract_and_store_facts(
                        agent_name, messages, session_id
                    )
                    return run_async_sync(fresh_coro)
                except Exception as e:
                    logger.warning(f"Fact extraction failed for {agent_name}: {e}")
                    return 0

            # Run in a thread to avoid blocking
            import threading

            thread = threading.Thread(
                target=_sync_extract_with_error_handling,
                name=f"agent_memory_extraction_{agent_name}",
            )
            thread.daemon = True
            thread.start()
        except Exception as e:
            logger.debug(f"Could not schedule fact extraction: {e}")

    return task
