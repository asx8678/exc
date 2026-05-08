"""Context overflow detection across LLM providers.

Ported from pi-mono-main's packages/ai/src/utils/overflow.ts.
Provides 20+ provider-specific regex patterns for detecting context
window overflow errors across Anthropic, OpenAI, Google, xAI, Groq,
OpenRouter, llama.cpp, LM Studio, GitHub Copilot, MiniMax, Kimi,
Cerebras, Mistral, z.ai, Ollama, and more.

Usage:
    from code_puppy.utils.overflow_detect import is_context_overflow

    if is_context_overflow(error_message):
        # Trigger compaction or model switch
        ...
"""

import re

__all__ = [
    "is_context_overflow",
    "is_rate_limit_error",
    "get_overflow_patterns",
    "get_non_overflow_patterns",
]

# Compiled patterns for context overflow errors across providers.
# Each pattern is case-insensitive.
# Sources: Anthropic, OpenAI, Google, xAI, Groq, OpenRouter,
# llama.cpp, LM Studio, GitHub Copilot, MiniMax, Kimi, Cerebras,
# Mistral, z.ai, Ollama
_OVERFLOW_PATTERNS: tuple[re.Pattern[str], ...] = tuple(
    re.compile(p, re.IGNORECASE)
    for p in (
        # Anthropic
        r"prompt is too long",
        r"request_too_large",
        # OpenAI / Azure
        r"input is too long for requested model",
        r"maximum context length is \d+ tokens",
        r"reduce the length of the messages",
        # Google / Vertex
        r"exceeds the context window",
        r"input token count.*exceeds the maximum",
        r"maximum prompt length is \d+",
        # Generic / multi-provider
        r"exceeds the limit of \d+",
        r"exceeds the available context size",
        r"greater than the context length",
        r"context window exceeds limit",
        r"exceeded model token limit",
        r"too large for model with \d+ maximum context length",
        r"model_context_window_exceeded",
        # Ollama / llama.cpp / LM Studio
        r"prompt too long; exceeded (?:max )?context length",
        r"context[_ ]length[_ ]exceeded",
        # Generic overflow signals
        r"too many tokens",
        r"token limit exceeded",
        # Bare HTTP status codes that indicate overflow (no body)
        r"^4(?:00|13)\s*(?:status code)?\s*\(no body\)",
    )
)

# Patterns that look like overflow but are actually rate limiting.
# These must be checked FIRST to avoid false positives.
_NON_OVERFLOW_PATTERNS: tuple[re.Pattern[str], ...] = tuple(
    re.compile(p, re.IGNORECASE)
    for p in (
        r"^(?:Throttling error|Service unavailable):",
        r"rate limit",
        r"too many requests",
    )
)


def is_context_overflow(
    error_message: str,
    *,
    input_tokens: int | None = None,
    context_window: int | None = None,
) -> bool:
    """Detect if an error indicates context window overflow.

    Supports two detection modes:
    1. **Error-based**: Matches error message text against known provider
       overflow patterns (20+ patterns across 15+ providers).
    2. **Silent overflow**: When ``input_tokens`` exceeds ``context_window``
       (some providers like z.ai don't error, they just truncate).

    Args:
        error_message: The error message string from the LLM provider.
        input_tokens: Optional total input tokens (including cache reads).
        context_window: Optional model context window size.

    Returns:
        ``True`` if the error indicates context overflow, ``False`` otherwise.

    Examples:
        >>> is_context_overflow("prompt is too long: 150000 tokens > 128000")
        True
        >>> is_context_overflow("rate limit exceeded")
        False
        >>> is_context_overflow("", input_tokens=200000, context_window=128000)
        True
    """
    if not error_message and input_tokens is None:
        return False

    # Case 1: Error-based overflow detection
    if error_message:
        # Check non-overflow patterns first to avoid false positives
        if any(p.search(error_message) for p in _NON_OVERFLOW_PATTERNS):
            return False
        if any(p.search(error_message) for p in _OVERFLOW_PATTERNS):
            return True

    # Case 2: Silent overflow detection (z.ai style)
    if (
        input_tokens is not None
        and context_window is not None
        and input_tokens > context_window
    ):
        return True

    return False


def is_rate_limit_error(error_message: str) -> bool:
    """Check if an error is a rate limit (not overflow).

    Useful for distinguishing rate limiting from overflow when both
    could match generic patterns.

    Args:
        error_message: The error message string.

    Returns:
        ``True`` if the error is a rate limit.
    """
    if not error_message:
        return False
    return any(p.search(error_message) for p in _NON_OVERFLOW_PATTERNS)


def get_overflow_patterns() -> list[re.Pattern[str]]:
    """Return a copy of the overflow detection patterns (for testing/extension)."""
    return list(_OVERFLOW_PATTERNS)


def get_non_overflow_patterns() -> list[re.Pattern[str]]:
    """Return a copy of the non-overflow exclusion patterns."""
    return list(_NON_OVERFLOW_PATTERNS)
