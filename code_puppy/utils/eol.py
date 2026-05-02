"""End-of-line normalization with binary-file detection.

Ported from plandex's ``shared/utils.go`` ``NormalizeEOL`` + ``looksTextish``
heuristic.  Applies CRLF → LF conversion **only** when the input looks like
a text file, preventing corruption of binary content that happens to contain
``\\r\\n`` byte sequences.

The heuristic is intentionally conservative:
  1. No NUL (``\x00``) bytes anywhere — NUL is the strongest binary signal.
  2. Valid UTF-8 decode (Python ``str`` already guarantees this when content
     was read with ``errors="replace"`` or ``errors="surrogatepass"``).
  3. At least 90 % of characters are printable (letters, digits, punctuation,
     whitespace).  This catches raw binary that survived UTF-8 decoding.

If any check fails the content is returned unchanged.
"""

__all__ = ["normalize_eol", "looks_textish", "strip_bom", "restore_bom"]


def looks_textish(content: str) -> bool:
    """Return True if *content* looks like human-readable text.

    The check is designed to be fast on typical source files (early-exit on
    NUL) and reasonably accurate on binary blobs.

    Args:
        content: The string to inspect.  An empty string is considered text.

    Returns:
        ``True`` when the content is likely text, ``False`` when it appears
        to be binary.
    """
    if not content:
        return True  # empty is text

    # 1. NUL byte → binary
    if "\x00" in content:
        return False

    # 2. Printable-ratio check.  We count characters that are NOT control
    #    characters (categories Cc/Cf minus common whitespace).
    #    Common whitespace (\t, \n, \r, space) is treated as printable.
    total = len(content)
    printable = 0
    for ch in content:
        cp = ord(ch)
        if cp >= 0x20:
            # 0x20 (space) and above — most are printable.
            # 0x7F (DEL) and 0x80-0x9F (C1 controls) are the main exceptions
            # but they're rare enough in real text that a 90% threshold
            # handles them fine.
            printable += 1
        elif ch in "\t\n\r":
            printable += 1
        # else: raw control character, counts against printable ratio

    ratio = printable / total
    return ratio >= 0.90


def normalize_eol(content: str) -> str:
    r"""Normalize line endings to ``\n`` if the content looks like text.

    Applies CRLF (``\r\n``) → LF (``\n``) conversion and strips orphan CRs
    (``\r`` not followed by ``\n``).  Binary-looking content is returned
    unchanged — see :func:`looks_textish` for the detection heuristic.

    Args:
        content: File content to normalize.

    Returns:
        The content with consistent ``\n`` line endings, or the original
        content unchanged if it looks binary.
    """
    if not content:
        return content

    if not looks_textish(content):
        return content

    # CRLF → LF first, then orphan CR → LF
    result = content.replace("\r\n", "\n")
    result = result.replace("\r", "\n")
    return result


# --- BOM Handling ---
# Ported from pi-mono-main packages/coding-agent/src/core/tools/edit-diff.ts:137-139
# The BOM (Byte Order Mark) is an invisible character at the start of files
# created by some Windows editors. LLMs never include BOM in their output,
# so string matching fails silently on BOM-encoded files without this handling.

# UTF-8 BOM: EF BB BF (decoded as U+FEFF)
_UTF8_BOM = "\ufeff"


def strip_bom(content: str) -> tuple[str, str]:
    """Strip the Unicode BOM from the beginning of content.

    Returns a tuple of (stripped_content, bom_string). The bom_string is
    empty if no BOM was present, or the BOM character(s) if one was found.
    This allows callers to re-prepend the BOM after modifications.

    Only handles UTF-8 BOM (U+FEFF) since Python's str type means the
    content has already been decoded — UTF-16/32 BOMs become U+FEFF during
    decoding.

    Args:
        content: File content that may start with a BOM.

    Returns:
        Tuple of (content_without_bom, bom_prefix).

    Examples:
        >>> strip_bom("\\ufeffhello")
        ('hello', '\\ufeff')
        >>> strip_bom("hello")
        ('hello', '')
    """
    if content.startswith(_UTF8_BOM):
        return content[1:], _UTF8_BOM
    return content, ""


def restore_bom(content: str, bom: str) -> str:
    """Re-prepend a BOM to content if one was originally present.

    Args:
        content: Modified content without BOM.
        bom: The BOM string from a prior ``strip_bom()`` call (empty if none).

    Returns:
        Content with BOM restored (or unchanged if bom is empty).

    Examples:
        >>> restore_bom("hello", "\\ufeff")
        '\\ufeffhello'
        >>> restore_bom("hello", "")
        'hello'
    """
    if bom:
        return bom + content
    return content
