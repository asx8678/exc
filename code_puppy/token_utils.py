"""Shared token estimation utilities.

Centralizes the token count heuristic so all parts of the codebase
use the same formula. Uses a tiered approach:
  - Code (detected by common code indicators): ~4.5 chars/token
  - Prose/natural language: ~4 chars/token (standard GPT tokenizer avg)

For large texts (>500 chars), uses line-sampling extrapolation inspired
by aider's RepoMap.token_count() — sample ~1% of lines and scale up.
This keeps estimation O(sample_size) instead of O(n) for huge files.
"""

import functools
import re

# Simple heuristics to detect code-heavy content
_CODE_INDICATORS = re.compile(
    r"[{}\[\]();]"  # braces, brackets, semicolons
    r"|^\s*(def |class |import |from |if |for |while |return )"  # Python keywords
    r"|^\s*(function |const |let |var |=>)"  # JS/TS keywords
    r"|^\s*#include\b",  # C/C++
    re.MULTILINE,
)

# Threshold above which we switch to line-sampling.
_SAMPLING_THRESHOLD = 500  # characters


def _is_code_heavy(text: str) -> bool:
    """Heuristic: does the text look like source code?"""
    if len(text) < 20:
        return False
    # Count code indicator matches in first 2000 chars
    sample = text[:2000]
    matches = len(_CODE_INDICATORS.findall(sample))
    # If >30% of lines have code indicators, treat as code
    line_count = max(1, sample.count("\n") + 1)
    return matches / line_count > 0.3


def _chars_per_token(text: str) -> float:
    """Return the estimated characters-per-token ratio for *text*."""
    return 4.5 if _is_code_heavy(text) else 4.0


@functools.lru_cache(maxsize=512)
def estimate_token_count(text: str) -> int:
    """Estimate the number of tokens in a text string.

    For short texts (<=500 chars) uses a direct character-ratio heuristic.
    For longer texts, samples ~1% of lines and extrapolates, which is both
    faster and more robust for large files with mixed content density.

    The code-vs-prose detection uses the first 2000 chars to decide the
    chars-per-token ratio (4.5 for code, 4.0 for prose).

    Args:
        text: The text to estimate tokens for.

    Returns:
        Estimated token count, minimum 1.
    """
    if not text:
        return 1

    text_len = len(text)
    ratio = _chars_per_token(text)

    # Fast path for short texts — direct division.
    if text_len <= _SAMPLING_THRESHOLD:
        return max(1, int(text_len / ratio))

    # Sampling path for large texts.
    # Split into lines, sample every Nth line, measure the sample,
    # then scale up proportionally.
    lines = text.splitlines(keepends=True)
    num_lines = len(lines)
    # Sample ~1% of lines, minimum 1 line
    step = max(1, num_lines // 100)
    sample_lines = lines[::step]
    sample_text_len = sum(len(line) for line in sample_lines)

    if sample_text_len == 0:
        return max(1, int(text_len / ratio))

    # Tokens in the sample
    sample_tokens = sample_text_len / ratio
    # Scale up: (sample_tokens / sample_chars) * total_chars
    estimated = sample_tokens / sample_text_len * text_len
    return max(1, int(estimated))
