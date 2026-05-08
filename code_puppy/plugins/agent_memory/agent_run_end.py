"""Agent run end callback handler for agent memory plugin.

Orchestrates signal confidence updates and fact extraction when
an agent run completes.
"""

import logging
from typing import Any

from code_puppy.callbacks import register_callback

from .core import get_config, is_memory_enabled_global
from .messaging import _get_conversation_messages
from .processing import _apply_signal_confidence_updates, _schedule_fact_extraction

logger = logging.getLogger(__name__)


async def _on_agent_run_end(
    agent_name: str,
    model_name: str,
    session_id: str | None = None,
    success: bool = True,
    error: Exception | None = None,
    response_text: str | None = None,
    metadata: dict | None = None,
    **kwargs: Any,
) -> None:
    """Handle agent run end - extract facts and apply signal confidence updates.

    This callback:
    1. Gets conversation messages from the run context
    2. Runs SignalDetector on user messages to detect corrections/reinforcements
    3. Applies signal confidence deltas to existing facts in storage
    4. Schedules async fact extraction via FactExtractor (non-blocking)
    5. Queues extracted facts via MemoryUpdater (debounced)

    Args:
        agent_name: Name of the agent that finished
        model_name: Name of the model used
        session_id: Optional session identifier
        success: Whether the run completed successfully
        error: Exception if the run failed
        response_text: Final response from the agent
        metadata: Additional context data
    """
    if not is_memory_enabled_global():
        return

    config = get_config()
    if config and not config.enabled:
        return

    # Only process successful runs with actual conversation
    if not success:
        return

    try:
        # Get conversation messages
        messages = _get_conversation_messages(agent_name, session_id, metadata)

        if not messages:
            logger.debug(f"No conversation messages found for {agent_name}")
            return

        # Step 1: Apply signal-based confidence updates
        signal_updates = _apply_signal_confidence_updates(
            agent_name, messages, session_id
        )

        if signal_updates > 0:
            logger.debug(f"Applied {signal_updates} signal-based confidence updates")

        # Step 2: Schedule async fact extraction (non-blocking)
        _schedule_fact_extraction(agent_name, messages, session_id)

    except Exception as e:
        # Fail gracefully - memory should never break agent operation
        logger.debug(f"Memory processing failed for {agent_name}: {e}")


def register_agent_run_end_callback() -> None:
    """Register the agent run end callback."""
    register_callback("agent_run_end", _on_agent_run_end)
