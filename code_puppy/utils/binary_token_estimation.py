"""Shared binary content token estimation.

Provides a single source of truth for estimating the token cost
of binary content (images, PDFs, generic files).
"""

from __future__ import annotations

from typing import Any


def estimate_binary_content_tokens(binary_content: Any) -> int:
    """Estimate token cost of binary content for context budgeting.

    Uses conservative heuristics based on media type and data size.
    Anthropic: ~750 tokens per 512x512 image tile
    OpenAI: similar tile-based pricing
    For non-image binary: ~1 token per 4 bytes (conservative)

    Args:
        binary_content: A BinaryContent-like object with ``data`` and
            optional ``media_type`` attributes.

    Returns:
        Estimated token count (always >= 50, >= 100 for images).
    """
    data = getattr(binary_content, "data", b"")
    if isinstance(data, (bytes, bytearray, memoryview)):
        byte_size = len(data)
    else:
        byte_size = len(str(data))

    media_type = getattr(binary_content, "media_type", "") or ""

    if media_type.startswith("image/"):
        # Conservative image estimation:
        # Most screenshots are 1-4 tiles at ~750 tokens each
        # Rough heuristic: 1 tile per 200KB, minimum 1 tile
        tiles = max(1, byte_size // 204800)  # 200KB per tile
        return max(100, tiles * 750)
    elif media_type.startswith("application/pdf"):
        # PDFs: estimate ~250 tokens per page, ~50KB per page
        pages = max(1, byte_size // 51200)
        return max(200, pages * 250)
    else:
        # Generic binary: conservative 1 token per 4 bytes
        return max(50, byte_size // 4)
