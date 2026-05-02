"""
Python wrappers for Elixir message RPC methods.

This module provides Python functions that call the Elixir message.*
RPC methods via the JSON-RPC transport.

## Usage

```python
from code_puppy import message_transport

# Prune orphaned tool calls and oversized messages
result = message_transport.prune_and_filter(messages, max_tokens=50_000)
# result = {"surviving_indices": [...], "dropped_count": 0, ...}

# Serialize messages to MessagePack
binary_data = message_transport.serialize_session(messages)

# Compute content hash for deduplication
hash_value = message_transport.hash_message(message)
```

## Environment Variables

Uses the same transport as elixir_transport_helpers - see that module for
configuration options.
"""

import base64
from typing import Any


def _get_transport() -> "ElixirTransport":  # type: ignore # noqa: F821
    """Get the shared transport singleton from elixir_transport_helpers."""
    from code_puppy.elixir_transport_helpers import get_transport

    return get_transport()


# =============================================================================
# Pruning Operations (Messages.Pruner)
# =============================================================================


def prune_and_filter(
    messages: list[dict[str, Any]],
    max_tokens_per_message: int = 50_000,
) -> dict[str, Any]:
    """Prune orphaned tool calls and oversized messages.

    This function removes:
    - Messages with orphaned tool_call_ids (tool calls without matching returns)
    - Messages that exceed max_tokens_per_message
    - Messages with single empty "thinking" parts

    Args:
        messages: List of message dicts with "kind", "role", "parts" fields
        max_tokens_per_message: Maximum tokens per message before dropping

    Returns:
        Dict with:
        - surviving_indices: List of indices that survived pruning
        - dropped_count: Number of messages dropped
        - had_pending_tool_calls: Whether there were pending tool calls
        - pending_tool_call_count: Number of pending tool calls

    Example:
        >>> result = prune_and_filter(messages, max_tokens=50_000)
        >>> surviving = [messages[i] for i in result["surviving_indices"]]
    """
    transport = _get_transport()
    return transport._send_request(
        "message.prune_and_filter",
        {
            "messages": messages,
            "max_tokens_per_message": max_tokens_per_message,
        },
    )


def truncation_indices(
    per_message_tokens: list[int],
    protected_tokens: int,
    second_has_thinking: bool = False,
) -> list[int]:
    """Calculate which messages to keep within a token budget.

    Algorithm:
    1. Always keeps index 0
    2. If second_has_thinking, also keeps index 1
    3. Walks from END backwards, keeping messages until budget exhausted

    Args:
        per_message_tokens: Token count for each message
        protected_tokens: Total token budget for protected messages
        second_has_thinking: Whether second message has thinking content

    Returns:
        Sorted list of indices to keep

    Example:
        >>> indices = truncation_indices([100, 200, 300, 400], 500)
        >>> # Keeps index 0 (always) plus indices from end that fit
    """
    transport = _get_transport()
    result = transport._send_request(
        "message.truncation_indices",
        {
            "per_message_tokens": per_message_tokens,
            "protected_tokens": protected_tokens,
            "second_has_thinking": second_has_thinking,
        },
    )
    return result["indices"]


def split_for_summarization(
    per_message_tokens: list[int],
    messages: list[dict[str, Any]],
    protected_tokens_limit: int,
) -> dict[str, Any]:
    """Split messages into groups for summarization.

    Divides messages into:
    - summarize_indices: Middle messages to be summarized
    - protected_indices: Start + end messages to preserve

    The boundary is adjusted to avoid splitting tool-call/tool-return pairs.

    Args:
        per_message_tokens: Token count for each message
        messages: List of message dicts
        protected_tokens_limit: Max tokens for protected group

    Returns:
        Dict with:
        - summarize_indices: Indices of messages to summarize
        - protected_indices: Indices of messages to preserve
        - protected_token_count: Total tokens in protected group

    Example:
        >>> result = split_for_summarization(tokens, messages, 10_000)
        >>> to_summarize = [messages[i] for i in result["summarize_indices"]]
    """
    transport = _get_transport()
    return transport._send_request(
        "message.split_for_summarization",
        {
            "per_message_tokens": per_message_tokens,
            "messages": messages,
            "protected_tokens_limit": protected_tokens_limit,
        },
    )


# =============================================================================
# Serialization Operations (Messages.Serializer)
# =============================================================================


def serialize_session(messages: list[dict[str, Any]]) -> bytes:
    """Serialize messages to MessagePack binary format.

    Uses Elixir's msgpax library for serialization, ensuring
    round-trip compatibility with Python sessions.

    Args:
        messages: List of message dicts to serialize

    Returns:
        Binary MessagePack data

    Example:
        >>> data = serialize_session(messages)
        >>> # Store data to file or send over network
        >>> restored = deserialize_session(data)
    """
    transport = _get_transport()
    result = transport._send_request(
        "message.serialize_session",
        {
            "messages": messages,
        },
    )
    # Elixir returns base64-encoded binary for JSON transport
    return base64.b64decode(result["data"])


def deserialize_session(data: bytes) -> list[dict[str, Any]]:
    """Deserialize MessagePack binary data to messages.

    Args:
        data: Binary MessagePack data

    Returns:
        List of message dicts

    Example:
        >>> with open("session.msgpack", "rb") as f:
        ... messages = deserialize_session(f.read())
    """
    transport = _get_transport()
    # Encode binary as base64 for JSON transport
    encoded = base64.b64encode(data).decode("ascii")
    result = transport._send_request(
        "message.deserialize_session",
        {
            "data": encoded,
        },
    )
    return result["messages"]


def serialize_incremental(
    new_messages: list[dict[str, Any]],
    existing_data: bytes | None = None,
) -> bytes:
    """Append new messages to existing serialized data.

    If existing_data is None, creates a fresh serialization.
    Otherwise, deserializes existing data, appends new messages,
    and re-serializes.

    Args:
        new_messages: New messages to add
        existing_data: Previously serialized data (optional)

    Returns:
        Combined serialized data

    Example:
        >>> data = serialize_session(initial_messages)
        >>> data = serialize_incremental(more_messages, data)
    """
    transport = _get_transport()
    params: dict[str, Any] = {"new_messages": new_messages}

    if existing_data is not None:
        params["existing_data"] = base64.b64encode(existing_data).decode("ascii")

    result = transport._send_request("message.serialize_incremental", params)
    return base64.b64decode(result["data"])


# =============================================================================
# Hashing Operations (Messages.Hasher)
# =============================================================================


def hash_message(message: dict[str, Any]) -> int:
    """Compute a content hash for a message.

    The hash is computed from the message's role, instructions,
    and all parts. Used for deduplication and change detection.

    Note: Hash values are consistent within an Elixir session but
    may differ from Python hash implementations.

    Args:
        message: Message dict with "kind", "role", "parts" fields

    Returns:
        Non-negative integer hash value

    Example:
        >>> hash1 = hash_message(msg)
        >>> hash2 = hash_message(msg)
        >>> assert hash1 == hash2 # Same content = same hash
    """
    transport = _get_transport()
    result = transport._send_request(
        "message.hash",
        {
            "message": message,
        },
    )
    return result["hash"]


def hash_batch(messages: list[dict[str, Any]]) -> list[int]:
    """Compute hashes for multiple messages.

    More efficient than calling hash_message() repeatedly
    as it batches the RPC call.

    Args:
        messages: List of message dicts

    Returns:
        List of hash values (same order as input)

    Example:
        >>> hashes = hash_batch(messages)
        >>> unique_hashes = set(hashes)
    """
    transport = _get_transport()
    result = transport._send_request(
        "message.hash_batch",
        {
            "messages": messages,
        },
    )
    return result["hashes"]


def stringify_part(part: dict[str, Any]) -> str:
    """Get canonical string representation of a message part.

    Used internally by hash_message() but exposed for debugging
    and testing hash consistency.

    Args:
        part: Message part dict with "part_kind", "content", etc.

    Returns:
        Canonical string like "text|content=Hello"

    Example:
        >>> s = stringify_part({"part_kind": "text", "content": "Hi"})
        >>> assert "text" in s and "content=Hi" in s
    """
    transport = _get_transport()
    result = transport._send_request(
        "message.stringify_part",
        {
            "part": part,
        },
    )
    return result["stringified"]


# =============================================================================
# Convenience / Compatibility
# =============================================================================


# Aliases for consistency with other code_puppy modules
prune = prune_and_filter
serialize = serialize_session
deserialize = deserialize_session
