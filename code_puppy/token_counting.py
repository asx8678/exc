"""
Provider-aware token counting for accurate LLM budget decisions.

This module provides accurate token counting using provider-specific
tokenizers when available, with graceful fallback to heuristics.
"""

from __future__ import annotations

import functools
from typing import Any


# Provider detection
def detect_provider(model_name: str) -> str:
    """Detect the provider from model name."""
    model_lower = model_name.lower()
    if any(x in model_lower for x in ("gpt", "o1", "o3", "chatgpt", "openai")):
        return "openai"
    if any(x in model_lower for x in ("claude", "anthropic")):
        return "anthropic"
    if any(x in model_lower for x in ("gemini", "google", "palm")):
        return "google"
    return "unknown"


@functools.lru_cache(maxsize=8)
def _get_tiktoken_encoding(model_name: str):
    """Get tiktoken encoding, cached."""
    try:
        import tiktoken

        try:
            return tiktoken.encoding_for_model(model_name)
        except KeyError:
            # Fall back to cl100k_base for unknown models
            return tiktoken.get_encoding("cl100k_base")
    except ImportError:
        return None


def count_tokens_openai(text: str, model_name: str = "gpt-4o") -> int | None:
    """Count tokens using tiktoken for OpenAI models."""
    encoding = _get_tiktoken_encoding(model_name)
    if encoding is None:
        return None
    return len(encoding.encode(text))


def count_tokens_anthropic(
    text: str, model_name: str = "claude-3-5-sonnet"
) -> int | None:
    """Count tokens for Anthropic models."""
    # Anthropic uses a similar tokenizer to GPT-4
    # Their official SDK has count_tokens but requires API call
    # For now, use tiktoken cl100k_base as close approximation
    return count_tokens_openai(text, "gpt-4o")


def count_tokens_heuristic(text: str) -> int:
    """Fallback heuristic: ~4 chars per token."""
    return max(1, len(text) // 4)


def count_tokens(text: str, model_name: str = "gpt-4o") -> int:
    """
    Count tokens in text using the best available method for the model.

    Args:
        text: The text to count tokens for
        model_name: The model name (used to select tokenizer)

    Returns:
        Estimated token count
    """
    if not text:
        return 0

    provider = detect_provider(model_name)

    if provider == "openai":
        result = count_tokens_openai(text, model_name)
        if result is not None:
            return result
    elif provider == "anthropic":
        result = count_tokens_anthropic(text, model_name)
        if result is not None:
            return result

    # Fallback to heuristic
    return count_tokens_heuristic(text)


def count_messages_tokens(
    messages: list[dict[str, Any]], model_name: str = "gpt-4o"
) -> int:
    """
    Count tokens for a list of messages (including role overhead).

    Accounts for message structure overhead (roles, formatting).
    """
    total = 0
    tokens_per_message = 4  # Approximate overhead per message

    for msg in messages:
        total += tokens_per_message
        content = msg.get("content", "")
        if isinstance(content, str):
            total += count_tokens(content, model_name)
        elif isinstance(content, list):
            # Handle multi-part content (text + tool calls)
            for part in content:
                if isinstance(part, dict):
                    if "text" in part:
                        total += count_tokens(part["text"], model_name)
                    elif "input" in part:  # Tool call input
                        import json

                        total += count_tokens(json.dumps(part["input"]), model_name)

    return total
