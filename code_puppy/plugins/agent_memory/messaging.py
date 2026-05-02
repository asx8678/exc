"""Message extraction and normalization utilities for agent memory.

Handles retrieving conversation messages from various sources and
normalizing them to a standard format.
"""

from typing import TYPE_CHECKING, Any

from code_puppy.run_context import get_current_run_context

if TYPE_CHECKING:
    from .storage import FileMemoryStorage


def _get_conversation_messages(
    agent_name: str, session_id: str | None, metadata: dict | None
) -> list[dict[str, Any]]:
    """Extract conversation messages from run context or metadata.

    Args:
        agent_name: Name of the agent
        session_id: Optional session identifier
        metadata: Optional metadata dict that might contain messages

    Returns:
        List of conversation message dicts with 'role' and 'content'
    """
    # Try to get messages from run context first
    ctx = get_current_run_context()
    if ctx and ctx.metadata:
        messages = ctx.metadata.get("message_history", [])
        if messages:
            return messages

    # Try metadata passed to callback
    if metadata:
        messages = metadata.get("message_history", [])
        if messages:
            return messages

    # Try to get from agent's message history if agent instance available
    try:
        from code_puppy.agents import get_current_agent

        agent = get_current_agent()
        if agent and agent.name == agent_name:
            history = agent.get_message_history()
            if history:
                return _normalize_messages(history)
    except Exception:
        pass

    return []


def _get_current_agent_name() -> str | None:
    """Get the name of the currently active agent.

    Returns:
        Agent name string, or None if not available
    """
    try:
        from code_puppy.agents import get_current_agent

        agent = get_current_agent()
        return agent.name
    except Exception:
        return None


def _get_storage_for_current_agent() -> "FileMemoryStorage | None":
    """Get FileMemoryStorage for the current agent.

    Returns:
        FileMemoryStorage instance, or None if no agent

    Thread-safe: Yes. Uses cached storage instance to ensure
    all accesses share the same lock, preventing race conditions.
    """
    from .core import _get_storage

    agent_name = _get_current_agent_name()
    if not agent_name:
        return None
    return _get_storage(agent_name)


def _normalize_messages(messages: list[Any]) -> list[dict[str, Any]]:
    """Normalize various message formats to standard dict format.

    Args:
        messages: Messages in various formats (dicts, pydantic models, etc.)

    Returns:
        List of normalized message dicts with 'role' and 'content'
    """
    normalized: list[dict[str, Any]] = []

    for msg in messages:
        if isinstance(msg, dict):
            # Already a dict, extract standard fields
            normalized.append(
                {
                    "role": msg.get("role", "unknown"),
                    "content": msg.get("content", str(msg)),
                }
            )
        else:
            # Try to extract from object attributes
            try:
                role = getattr(msg, "role", "unknown")
                content = getattr(msg, "content", str(msg))
                normalized.append({"role": role, "content": content})
            except Exception:
                # Fallback: treat as string content
                normalized.append({"role": "unknown", "content": str(msg)})

    return normalized


def _extract_user_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Filter messages to only include user messages.

    Args:
        messages: All conversation messages

    Returns:
        List of user messages only
    """
    return [m for m in messages if m.get("role") in ("user", "human", "input")]
