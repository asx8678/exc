"""Shadow mode utilities for Elixir message integration.

This module provides utilities for running message operations in shadow mode,
where both Python and Elixir execute the same operation and results are compared.
"""

import logging
from typing import Any

from pydantic_ai.messages import ModelMessage

logger = logging.getLogger(__name__)


def _is_shadow_mode_enabled() -> bool:
    """Check if shadow mode is enabled via config."""
    try:
        from code_puppy.config import get_elixir_message_shadow_mode_enabled

        return get_elixir_message_shadow_mode_enabled()
    except ImportError:
        return False


def _serialize_messages_for_elixir(
    messages: list[ModelMessage],
) -> list[dict[str, Any]]:
    """Convert ModelMessage objects to dicts for Elixir RPC.

    Args:
        messages: List of pydantic-ai ModelMessage objects

    Returns:
        List of dicts with string keys matching Elixir message format
    """
    result = []
    for msg in messages:
        msg_dict: dict[str, Any] = {
            "kind": getattr(msg, "kind", "unknown"),
            "role": getattr(msg, "role", None),
            "parts": [],
        }

        for part in getattr(msg, "parts", []) or []:
            part_dict: dict[str, Any] = {
                "part_kind": getattr(part, "part_kind", "unknown"),
                "content": getattr(part, "content", None),
                "tool_call_id": getattr(part, "tool_call_id", None),
                "tool_name": getattr(part, "tool_name", None),
            }
            # Handle content that might be a model
            if hasattr(part_dict["content"], "model_dump"):
                part_dict["content"] = str(part_dict["content"].model_dump())
            msg_dict["parts"].append(part_dict)

        result.append(msg_dict)
    return result


def shadow_prune_and_filter(
    messages: list[ModelMessage],
    python_result: list[ModelMessage],
    max_tokens_per_message: int = 50_000,
) -> None:
    """Run Elixir prune_and_filter in shadow mode and compare results.

    This function is called AFTER Python has computed its result.
    It runs the Elixir version and compares, logging any discrepancies.

    Args:
        messages: Original messages (for Elixir call)
        python_result: Result from Python implementation
        max_tokens_per_message: Token limit passed to Elixir
    """
    if not _is_shadow_mode_enabled():
        return

    try:
        from code_puppy import message_transport

        # Serialize messages for Elixir
        serialized = _serialize_messages_for_elixir(messages)

        # Call Elixir
        elixir_result = message_transport.prune_and_filter(
            serialized, max_tokens_per_message
        )

        # Compare: Python returns list of messages, Elixir returns indices
        python_count = len(python_result)
        elixir_surviving_count = len(elixir_result.get("surviving_indices", []))

        if python_count != elixir_surviving_count:
            logger.warning(
                "[shadow-mode] prune_and_filter mismatch: "
                f"Python kept {python_count} messages, "
                f"Elixir kept {elixir_surviving_count} messages. "
                f"Elixir dropped {elixir_result.get('dropped_count', 0)}, "
                f"pending_tool_calls={elixir_result.get('pending_tool_call_count', 0)}"
            )
        else:
            logger.debug(
                f"[shadow-mode] prune_and_filter match: {python_count} messages"
            )

    except Exception as e:
        logger.warning(f"[shadow-mode] prune_and_filter error: {e}")


def shadow_hash_messages(
    messages: list[ModelMessage],
    python_hashes: list[str],
) -> None:
    """Run Elixir hash_batch in shadow mode and compare results.

    Note: Python uses SHA256 (hex string), Elixir uses phash2 (int).
    We can only compare counts and consistency, not exact values.

    Args:
        messages: Messages that were hashed
        python_hashes: Hashes computed by Python
    """
    if not _is_shadow_mode_enabled():
        return

    try:
        from code_puppy import message_transport

        serialized = _serialize_messages_for_elixir(messages)
        elixir_hashes = message_transport.hash_batch(serialized)

        # Check consistency: same messages should produce same relative hashes
        if len(python_hashes) != len(elixir_hashes):
            logger.warning(
                "[shadow-mode] hash_batch length mismatch: "
                f"Python={len(python_hashes)}, Elixir={len(elixir_hashes)}"
            )
            return

        # Check uniqueness patterns match
        python_unique = len(set(python_hashes))
        elixir_unique = len(set(elixir_hashes))

        if python_unique != elixir_unique:
            logger.warning(
                "[shadow-mode] hash uniqueness mismatch: "
                f"Python has {python_unique} unique, "
                f"Elixir has {elixir_unique} unique"
            )
        else:
            logger.debug(
                f"[shadow-mode] hash_batch match: {len(python_hashes)} hashes, "
                f"{python_unique} unique"
            )

    except Exception as e:
        logger.warning(f"[shadow-mode] hash_batch error: {e}")
