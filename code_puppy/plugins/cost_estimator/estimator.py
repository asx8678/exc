"""Token counting and cost estimation for LLM API calls.

Provides functions to count tokens and estimate costs without making
actual API calls. Inspired by Agentless ``FL.py:330-340`` mock mode
and ``api_requests.py:7-20`` token counting.

Uses tiktoken when available, falls back to character-based heuristic.
"""

import logging
import threading
from dataclasses import dataclass
from typing import Any

from code_puppy.token_counting import count_tokens as _count_tokens_accurate

logger = logging.getLogger(__name__)

# Thread-safe accumulator for session cost tracking
_lock = threading.Lock()
_session_totals: dict[str, int] = {}  # model → total tokens


# ---------------------------------------------------------------------------
# Pricing table (approximate, USD per 1M tokens as of 2026-Q1)
# ---------------------------------------------------------------------------
#
# Pricing can be overridden via config:
#   [cost_estimator]
#   custom_pricing = {"gpt-4o": [2.50, 10.00], "claude-opus-4": [15.0, 75.0]}
#
_PRICING: dict[str, tuple[float, float]] = {
    # (input_per_1M, output_per_1M)
    # --- OpenAI ---
    "gpt-4.1-nano": (0.10, 0.40),
    "gpt-4.1-mini": (0.40, 1.60),
    "gpt-4.1": (2.00, 8.00),
    "gpt-4o": (2.50, 10.00),
    "gpt-4o-mini": (0.15, 0.60),
    "gpt-4-turbo": (10.00, 30.00),
    "gpt-4": (30.00, 60.00),
    "gpt-3.5-turbo": (0.50, 1.50),
    # --- Anthropic ---
    "claude-opus-4": (15.00, 75.00),
    "claude-sonnet-4": (3.00, 15.00),
    "claude-haiku-4": (0.80, 4.00),
    "claude-3-5-sonnet": (3.00, 15.00),
    "claude-3-5-haiku": (0.80, 4.00),
    "claude-3-opus": (15.00, 75.00),
    "claude-3-sonnet": (3.00, 15.00),
    "claude-3-haiku": (0.25, 1.25),
    # --- Google ---
    "gemini-2.5-pro": (1.25, 10.00),
    "gemini-2.5-flash": (0.15, 0.60),
    "gemini-2.0-flash": (0.10, 0.40),
    "gemini-1.5-pro": (1.25, 5.00),
    "gemini-1.5-flash": (0.075, 0.30),
    # --- DeepSeek ---
    "deepseek-v3": (0.27, 1.10),
    "deepseek-r1": (0.55, 2.19),
    "deepseek-coder": (0.14, 0.28),
    "deepseek-chat": (0.14, 0.28),
}

_DEFAULT_PRICING = (5.00, 15.00)  # conservative default


def _load_custom_pricing() -> None:
    """Load custom pricing overrides from config if available."""
    try:
        from code_puppy.config import get_config

        config = get_config()
        section = getattr(config, "cost_estimator", None)
        custom = getattr(section, "custom_pricing", None) if section else None
        if custom and isinstance(custom, dict):
            for model_key, prices in custom.items():
                if isinstance(prices, (list, tuple)) and len(prices) == 2:
                    _PRICING[model_key.lower()] = (float(prices[0]), float(prices[1]))
            logger.debug("Loaded %d custom pricing overrides from config", len(custom))
    except Exception:
        # Config not available or parsing failed — use hardcoded defaults
        pass


# Try loading custom pricing on import
_load_custom_pricing()


@dataclass(slots=True)
class TokenEstimate:
    """Result of token counting and cost estimation.

    Attributes:
        input_tokens: Estimated input/prompt tokens.
        output_tokens: Estimated output/completion tokens (0 if not estimatable).
        model: Model name used for pricing lookup.
        estimated_cost_usd: Estimated cost in USD.
        method: How tokens were counted ('tiktoken', 'heuristic', 'provider').
        provider_input_tokens: Actual input tokens from provider (None if unavailable).
        provider_output_tokens: Actual output tokens from provider (None if unavailable).
    """

    input_tokens: int = 0
    output_tokens: int = 0
    model: str = ""
    estimated_cost_usd: float = 0.0
    method: str = "unknown"
    provider_input_tokens: int | None = None
    provider_output_tokens: int | None = None

    def __str__(self) -> str:
        """Human-readable summary."""
        parts = [f"~{self.input_tokens:,} input tokens"]
        if self.provider_input_tokens is not None:
            parts.append(f"(provider: {self.provider_input_tokens:,})")
        if self.output_tokens > 0:
            parts.append(f"~{self.output_tokens:,} output tokens")
        if self.provider_output_tokens is not None:
            parts.append(f"(provider: {self.provider_output_tokens:,})")
        parts.append(f"~${self.estimated_cost_usd:.4f} USD")
        parts.append(f"({self.method})")
        return " | ".join(parts)


# Re-export for backward compatibility (tests may import these)
# These functions are now implemented via the centralized token_counting module
# but kept here for API compatibility
_count_tokens_tiktoken = _count_tokens_accurate
_count_tokens_heuristic = _count_tokens_accurate


def _lookup_pricing(model: str) -> tuple[float, float]:
    """Look up pricing for a model. Returns (input_per_1M, output_per_1M)."""
    model_lower = model.lower()
    # Sort keys by length (descending) so longer/more specific matches win
    # e.g., "gpt-4o-mini" matches before "gpt-4o"
    for key in sorted(_PRICING.keys(), key=len, reverse=True):
        if key in model_lower:
            return _PRICING[key]
    return _DEFAULT_PRICING


def count_tokens(
    text: str,
    *,
    model: str = "gpt-4o",
) -> int:
    """Count tokens in text, using provider-aware accurate counting.

    Args:
        text: Text to count tokens for.
        model: Model name for tokenizer selection.

    Returns:
        Token count (exact if tiktoken available, heuristic otherwise).
    """
    return _count_tokens_accurate(text, model_name=model)


def estimate_cost(
    prompt: str | list[dict[str, Any]],
    *,
    model: str = "gpt-4o",
    expected_output_tokens: int = 1024,
    provider_input_tokens: int | None = None,
    provider_output_tokens: int | None = None,
) -> TokenEstimate:
    """Estimate the cost of an LLM API call without making it.

    When provider-reported token counts are available, they are preferred
    over heuristic/tiktoken estimates for accuracy. The ``method`` field
    reflects which counting approach was used:

    * ``"provider"`` — provider-reported actuals (most accurate)
    * ``"tiktoken"`` — tiktoken-based estimate
    * ``"heuristic"`` — len/4 character-based estimate (least accurate)

    Args:
        prompt: Either a string prompt or a list of message dicts
            (each with 'role' and 'content' keys).
        model: Model name for pricing and tokenizer selection.
        expected_output_tokens: Expected output tokens (default: 1024).
        provider_input_tokens: Actual input tokens from provider (preferred when available).
        provider_output_tokens: Actual output tokens from provider (preferred when available).

    Returns:
        TokenEstimate with input tokens, cost, and method used.

    Examples:
        >>> est = estimate_cost("Hello, world!", model="gpt-4o")
        >>> est.input_tokens > 0
        True
        >>> est.estimated_cost_usd >= 0
        True
    """
    # Concatenate message contents if list of messages
    if isinstance(prompt, list):
        text = "\n".join(
            msg.get("content", "")
            if isinstance(msg.get("content"), str)
            else str(msg.get("content", ""))
            for msg in prompt
        )
    else:
        text = prompt

    # Prefer provider-reported counts when available
    if provider_input_tokens is not None:
        input_tokens = provider_input_tokens
        method = "provider"
    else:
        # Use provider-aware accurate token counting
        input_tokens = _count_tokens_accurate(text, model_name=model)
        # Detect which method was used based on tiktoken availability
        import importlib.util

        if importlib.util.find_spec("tiktoken") is not None:
            method = "tiktoken"
        else:
            method = "heuristic"

    # Determine output token count — prefer provider data when available
    output_tokens = (
        provider_output_tokens
        if provider_output_tokens is not None
        else expected_output_tokens
    )

    # Calculate cost
    input_price, output_price = _lookup_pricing(model)
    cost = (input_tokens * input_price + output_tokens * output_price) / 1_000_000

    return TokenEstimate(
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        model=model,
        estimated_cost_usd=cost,
        method=method,
        provider_input_tokens=provider_input_tokens,
        provider_output_tokens=provider_output_tokens,
    )


def track_session_tokens(model: str, tokens: int) -> None:
    """Accumulate token usage for the current session.

    Thread-safe. Called by the pre_tool_call hook in dry-run mode.
    """
    with _lock:
        _session_totals[model] = _session_totals.get(model, 0) + tokens


def get_session_summary() -> dict[str, Any]:
    """Get accumulated session cost summary.

    Returns:
        Dict with per-model token counts and total estimated cost.
    """
    with _lock:
        totals = dict(_session_totals)

    total_cost = 0.0
    model_summaries: list[dict[str, Any]] = []

    for model, tokens in totals.items():
        input_price, _ = _lookup_pricing(model)
        cost = tokens * input_price / 1_000_000
        total_cost += cost
        model_summaries.append(
            {
                "model": model,
                "total_tokens": tokens,
                "estimated_cost_usd": cost,
            }
        )

    return {
        "models": model_summaries,
        "total_estimated_cost_usd": total_cost,
    }


def reset_session() -> None:
    """Reset session tracking. Called on startup or manual reset."""
    with _lock:
        _session_totals.clear()
