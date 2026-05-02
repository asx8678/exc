"""Model-aware summarization threshold computation.

Replaces fixed token counts with fraction-based thresholds that scale
with the model's context window. Falls back to absolute values when
model context is unknown.
"""

import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING

from code_puppy.constants import (
    SUMMARIZATION_ABSOLUTE_PROTECTED_DEFAULT,
    SUMMARIZATION_ABSOLUTE_TRIGGER_DEFAULT,
    SUMMARIZATION_KEEP_FRACTION_DEFAULT,
    SUMMARIZATION_MIN_KEEP_TOKENS,
    SUMMARIZATION_MIN_TRIGGER_TOKENS,
    SUMMARIZATION_TRIGGER_FRACTION_DEFAULT,
)

if TYPE_CHECKING:
    pass

logger = logging.getLogger(__name__)

# Default absolute fallback values (centralized in constants.py)
DEFAULT_ABSOLUTE_TRIGGER = SUMMARIZATION_ABSOLUTE_TRIGGER_DEFAULT
DEFAULT_ABSOLUTE_PROTECTED = SUMMARIZATION_ABSOLUTE_PROTECTED_DEFAULT

# Default fraction values (centralized in constants.py)
DEFAULT_TRIGGER_FRACTION = SUMMARIZATION_TRIGGER_FRACTION_DEFAULT
DEFAULT_KEEP_FRACTION = SUMMARIZATION_KEEP_FRACTION_DEFAULT


@dataclass(frozen=True)
class SummarizationThresholds:
    """Computed summarization trigger and keep thresholds.

    - trigger_tokens: When message history exceeds this count, summarization fires.
    - keep_tokens: Number of tokens in recent messages to preserve untouched.
    """

    trigger_tokens: int
    keep_tokens: int
    source: str  # "model_aware_fraction" or "absolute_fallback"


def get_model_context_window(model_name: str) -> int | None:
    """Return the known max input tokens for a model, or None if unknown.

    Checks code_puppy's model metadata via ModelFactory.

    Args:
        model_name: The model name to look up (e.g., "claude-sonnet-4-5")

    Returns:
        Context window size in tokens, or None if the model is unknown.
    """
    try:
        # Import here to avoid circular imports at module load time
        from code_puppy.model_factory import ModelFactory

        model_configs = ModelFactory.load_config()
        model_config = model_configs.get(model_name, {})
        context_length = model_config.get("context_length")
        if context_length is not None:
            return int(context_length)
        return None
    except Exception:
        logger.debug("Failed to get context window for %s", model_name, exc_info=True)
        return None


def compute_summarization_thresholds(
    model_name: str,
    *,
    trigger_fraction: float = DEFAULT_TRIGGER_FRACTION,
    keep_fraction: float = DEFAULT_KEEP_FRACTION,
    absolute_trigger: int | None = None,
    absolute_protected: int | None = None,
) -> SummarizationThresholds:
    """Compute when to trigger summarization and how much to keep.

    Priority:
    1. If model context window is known → use fractions (85% trigger, 10% keep)
    2. If model context window is unknown → fall back to absolute values

    Args:
        model_name: The model being used (e.g., "claude-sonnet-4-5")
        trigger_fraction: Fraction of context window that triggers summarization
        keep_fraction: Fraction to preserve as recent "protected" messages
        absolute_trigger: Absolute token count fallback
        absolute_protected: Existing `protected_token_count` fallback

    Returns:
        SummarizationThresholds with computed trigger + keep values
    """
    # Validate and clamp fractions
    trigger_fraction = max(0.0, min(1.0, trigger_fraction))
    keep_fraction = max(0.0, min(1.0, keep_fraction))

    # Use provided fallbacks or defaults
    abs_trigger = (
        absolute_trigger if absolute_trigger is not None else DEFAULT_ABSOLUTE_TRIGGER
    )
    abs_protected = (
        absolute_protected
        if absolute_protected is not None
        else DEFAULT_ABSOLUTE_PROTECTED
    )

    context = get_model_context_window(model_name)
    if context is not None and context > 0:
        trigger_tokens = int(context * trigger_fraction)
        keep_tokens = int(context * keep_fraction)

        # Sanity checks: keep_tokens shouldn't exceed trigger_tokens
        if keep_tokens >= trigger_tokens:
            keep_tokens = max(1, trigger_tokens // 2)

        # Absolute minimums - never go below reasonable floor
        trigger_tokens = max(SUMMARIZATION_MIN_TRIGGER_TOKENS, trigger_tokens)
        keep_tokens = max(SUMMARIZATION_MIN_KEEP_TOKENS, keep_tokens)

        return SummarizationThresholds(
            trigger_tokens=trigger_tokens,
            keep_tokens=keep_tokens,
            source="model_aware_fraction",
        )

    # Fallback to absolute values
    return SummarizationThresholds(
        trigger_tokens=abs_trigger,
        keep_tokens=abs_protected,
        source="absolute_fallback",
    )
