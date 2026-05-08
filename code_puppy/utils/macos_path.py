"""macOS path variant resolution for filesystem encoding quirks.

Ported from pi-mono-main packages/coding-agent/src/core/tools/path-utils.ts.

macOS filenames can use different Unicode encodings than what LLMs output:
- Screenshot files use narrow no-break space (U+202F) before AM/PM
- HFS+ normalizes filenames to NFD (decomposed Unicode)
- French locale macOS uses curly right single quote (U+2019) for apostrophes

This module provides a fallback chain that tries variant encodings when
a file path doesn't exist, transparently resolving these quirks.
"""

import os
import re
import sys
import unicodedata

__all__ = ["resolve_path_with_variants"]

# Regex to match space before AM/PM in screenshot filenames
# e.g., "Screenshot 2024-01-15 at 2.30.15 PM.png"
_AM_PM_PATTERN = re.compile(r" (AM|PM)\.")

# Narrow no-break space used by macOS in screenshot filenames
_NARROW_NBSP = "\u202f"

# Unicode space characters that LLMs might use instead of regular spaces
_UNICODE_SPACES = re.compile(r"[\u00a0\u2000-\u200a\u202f\u205f\u3000]")


def _try_macos_screenshot_variant(path: str) -> str:
    """Replace regular space before AM/PM with narrow no-break space.

    macOS screenshot filenames use U+202F (narrow no-break space) before
    AM/PM, but LLMs output regular spaces.
    """
    return _AM_PM_PATTERN.sub(f"{_NARROW_NBSP}\\1.", path)


def _try_nfd_variant(path: str) -> str:
    """Normalize to NFD (decomposed Unicode).

    macOS HFS+ stores filenames in NFD normalization form, but LLMs
    typically output NFC (composed). Characters like é (U+00E9) become
    e + combining acute accent (U+0065 U+0301) in NFD.
    """
    return unicodedata.normalize("NFD", path)


def _try_curly_quote_variant(path: str) -> str:
    """Replace straight apostrophe with curly right single quote.

    French locale macOS uses U+2019 (right single quotation mark) where
    English uses U+0027 (apostrophe). LLMs output straight quotes.
    """
    return path.replace("'", "\u2019")


def _normalize_unicode_spaces(path: str) -> str:
    """Replace all Unicode space variants with regular ASCII space.

    LLMs might output non-breaking spaces or other Unicode space characters
    that don't match the actual filename.
    """
    return _UNICODE_SPACES.sub(" ", path)


def resolve_path_with_variants(file_path: str) -> str:
    """Try to resolve a file path using macOS-specific encoding variants.

    When the original path doesn't exist, tries up to 5 variant encodings
    that handle common macOS filesystem quirks. Returns the first variant
    that exists, or the original path if none match.

    The fallback chain:
    1. Original path (already checked by caller, but verified here too)
    2. Unicode space normalization (non-breaking → regular space)
    3. macOS screenshot variant (space → narrow NBSP before AM/PM)
    4. NFD normalization (NFC → NFD decomposed Unicode)
    5. Curly quote variant (straight ' → curly ')
    6. NFD + curly quote combined

    This is a no-op on non-macOS platforms (returns original path immediately).

    Args:
        file_path: The file path to resolve.

    Returns:
        The resolved path (possibly a variant), or the original if no
        variant exists either.

    Examples:
        >>> # If the file exists with NFD encoding on macOS:
        >>> resolve_path_with_variants("/path/to/café.txt")  # NFC input
        '/path/to/cafe\\u0301.txt'  # NFD on disk (hypothetical)
    """
    # Fast path: if file exists, return immediately
    if os.path.exists(file_path):
        return file_path

    # Only apply macOS-specific variants on macOS
    # (other platforms don't have these encoding quirks)
    if sys.platform != "darwin":
        return file_path

    # Try each variant in order of likelihood
    variants = [
        _normalize_unicode_spaces(file_path),
        _try_macos_screenshot_variant(file_path),
        _try_nfd_variant(file_path),
        _try_curly_quote_variant(file_path),
        _try_nfd_variant(_try_curly_quote_variant(file_path)),  # Combined
    ]

    for variant in variants:
        if variant != file_path and os.path.exists(variant):
            return variant

    return file_path
