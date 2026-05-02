"""
Python wrappers for Elixir text processing RPC methods.

This module provides Python functions that call the Elixir text.*
RPC methods via the JSON-RPC transport for text manipulation,
fuzzy matching, and diff generation.

## Usage

```python
from code_puppy import text_ops

# Apply replacements with fuzzy matching
result = text_ops.text_replace(
    content="Hello World",
    replacements=[{"old_str": "World", "new_str": "Python"}]
)
# result = {"modified": "Hello Python", "success": True, ...}

# Find best fuzzy match for a string within file lines
match = text_ops.text_fuzzy_match(
    haystack_lines=["line 1", "line 2", "target line", "line 4"],
    needle="target line"
)
# match = {"matched_text": "target line", "start": 3, "end": 3, "score": 1.0}

# Generate unified diff between two strings
diff = text_ops.text_unified_diff(
    old_string="hello",
    new_string="world"
)
# diff = "--- ...\n+++ ...\n@@ -1 +1 @@\n-hello\n+world\n"
```

## Environment Variables

Uses the same transport as elixir_transport_helpers - see that module for
configuration options.
"""

from typing import Any


def _get_transport() -> "ElixirTransport":  # type: ignore # noqa: F821
    """Get the shared transport singleton from elixir_transport_helpers."""
    from code_puppy.elixir_transport_helpers import get_transport

    return get_transport()


# =============================================================================
# Text Replace Operations
# =============================================================================


def text_replace(
    content: str,
    replacements: list[dict[str, str]],
) -> dict[str, Any]:
    """Apply text replacements with exact and fuzzy matching.

    Uses Jaro-Winkler similarity scoring for fuzzy matching when exact
    matches are not found. Each replacement dict should contain:
    - "old_str": The text to find and replace
    - "new_str": The replacement text

    Args:
        content: The original text content
        replacements: List of replacement dicts with "old_str" and "new_str" keys

    Returns:
        Dict with:
        - "modified": The modified text after replacements
        - "diff": Unified diff showing the changes
        - "success": Boolean indicating if all replacements succeeded
        - "error": Error message if any replacement failed (null if success)
        - "jw_score": Jaro-Winkler similarity score (0.0-1.0) for best match,
          or None for exact matches

    Example:
        >>> result = text_replace(
        ... "Hello World",
        ... [{"old_str": "World", "new_str": "Python"}]
        ... )
        >>> assert result["success"] is True
        >>> assert result["modified"] == "Hello Python"
    """
    transport = _get_transport()
    return transport._send_request(
        "text_replace",
        {
            "content": content,
            "replacements": replacements,
        },
    )


# =============================================================================
# Fuzzy Match Operations
# =============================================================================


def text_fuzzy_match(
    haystack_lines: list[str],
    needle: str,
) -> dict[str, Any]:
    """Find the best matching window using fuzzy string matching.

    Uses the Jaro-Winkler algorithm to find the best matching window
    within a list of text lines. This is useful for finding code blocks
    or text snippets that may have slight variations.

    Args:
        haystack_lines: List of text lines to search within
        needle: The target text to find (may be multi-line)

    Returns:
        Dict with:
        - "matched_text": The matched text (null if no match found)
        - "start": 1-based starting line number of match (0 if no match)
        - "end": 1-based ending line number of match (null if no match)
        - "score": Jaro-Winkler similarity score (0.0-1.0)

    Example:
        >>> lines = ["def foo():", " pass", "def bar():"]
        >>> result = text_fuzzy_match(lines, "def foo():")
        >>> assert result["start"] == 1
        >>> assert result["score"] >= 0.9
    """
    transport = _get_transport()
    return transport._send_request(
        "text_fuzzy_match",
        {
            "haystack_lines": haystack_lines,
            "needle": needle,
        },
    )


# =============================================================================
# Diff Operations
# =============================================================================


def text_unified_diff(
    old_string: str,
    new_string: str,
    context_lines: int = 3,
    from_file: str = "",
    to_file: str = "",
) -> str:
    """Generate a unified diff between two strings.

    Creates a standard unified diff format output suitable for patches,
    code reviews, and displaying changes between text versions.

    Args:
        old_string: The original text
        new_string: The modified text
        context_lines: Number of context lines around each hunk (default: 3)
        from_file: Label for the original file in diff header (default: "")
        to_file: Label for the modified file in diff header (default: "")

    Returns:
        Unified diff string in standard format with headers and hunks

    Example:
        >>> diff = text_unified_diff(
        ... "Hello World",
        ... "Hello Python",
        ... from_file="a.txt",
        ... to_file="b.txt"
        ... )
        >>> assert "-Hello World" in diff
        >>> assert "+Hello Python" in diff
    """
    transport = _get_transport()
    result = transport._send_request(
        "text_unified_diff",
        {
            "old": old_string,
            "new": new_string,
            "context_lines": context_lines,
            "from_file": from_file,
            "to_file": to_file,
        },
    )
    return result["diff"]


# =============================================================================
# Convenience Aliases
# =============================================================================

# Shorter names for common operations
replace = text_replace
fuzzy_match = text_fuzzy_match
unified_diff = text_unified_diff
