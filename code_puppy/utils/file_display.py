"""File display utilities for formatting and truncating content.

Ported from deepagents analysis (ADOPT #3, #4, #6).
"""

import os
from typing import overload

# ---------------------------------------------------------------------------
# Line number formatting with continuation for long lines (ADOPT #4)
# ---------------------------------------------------------------------------

MAX_LINE_LENGTH = 5000
LINE_NUMBER_WIDTH = 6


def format_content_with_line_numbers(
    content: str | list[str],
    start_line: int = 1,
    max_line_length: int = MAX_LINE_LENGTH,
    line_number_width: int = LINE_NUMBER_WIDTH,
) -> str:
    """Format file content with line numbers (cat -n style).

    For lines exceeding max_line_length, splits into chunks with
    continuation markers (e.g., "5.1", "5.2", "5.3").

    Args:
        content: File content as string or list of lines
        start_line: Starting line number (1-based)
        max_line_length: Maximum length before splitting into chunks
        line_number_width: Width for line number column

    Returns:
        Formatted content with line numbers and continuation markers

    Example:
        >>> format_content_with_line_numbers("hello\\nworld")
        '     1\\thello\\n     2\\tworld'

        >>> # Long lines get continuation markers
        >>> long_line = "a" * 12000
        >>> result = format_content_with_line_numbers([long_line])
        >>> "1.1" in result and "1.2" in result
        True
    """
    lines = content.split("\n") if isinstance(content, str) else content
    result_lines = []

    for i, line in enumerate(lines):
        line_num = i + start_line
        if len(line) <= max_line_length:
            result_lines.append(f"{line_num:{line_number_width}d}\t{line}")
        else:
            num_chunks = (len(line) + max_line_length - 1) // max_line_length
            for chunk_idx in range(num_chunks):
                start = chunk_idx * max_line_length
                end = min(start + max_line_length, len(line))
                chunk = line[start:end]
                if chunk_idx == 0:
                    result_lines.append(f"{line_num:{line_number_width}d}\t{chunk}")
                else:
                    continuation_marker = f"{line_num}.{chunk_idx}"
                    result_lines.append(
                        f"{continuation_marker:>{line_number_width}}\t{chunk}"
                    )

    return "\n".join(result_lines)


# ---------------------------------------------------------------------------
# Sticky-scroll scope context injection (ADOPT from Agentless)
# ---------------------------------------------------------------------------

_SCOPE_KEYWORDS = frozenset(
    {
        "class ",
        "def ",
        "async def ",
        # JS/TS
        "function ",
        "export function ",
        "export default function ",
        "export class ",
        "export default class ",
        # Rust
        "fn ",
        "pub fn ",
        "impl ",
        "pub struct ",
        "struct ",
        "enum ",
        "pub enum ",
        "mod ",
        "pub mod ",
        "trait ",
        "pub trait ",
        # Go
        "func ",
        "type ",
    }
)


def _is_scope_line(line: str) -> bool:
    """Check if a line starts a new scope (class, function, etc.).

    Uses indent-stripped keyword matching — language-agnostic heuristic
    that works for Python, JS/TS, Rust, Go, Java, C/C++, and most
    brace-delimited languages.
    """
    stripped = line.lstrip()
    return any(stripped.startswith(kw) for kw in _SCOPE_KEYWORDS)


def _indent_level(line: str) -> int:
    """Return the indentation level (number of leading spaces/tabs)."""
    return len(line) - len(line.lstrip())


def inject_scope_context(
    lines: list[str],
    start_line: int,
    end_line: int,
    *,
    max_context_lines: int = 5,
    context_prefix: str = "// ",
) -> list[str]:
    """Inject enclosing scope context when displaying a code fragment.

    When showing lines ``start_line..end_line`` of a file, this function
    scans preceding lines to find enclosing scope declarations (class,
    function, method, impl block, etc.) and prepends them as context
    headers — similar to VS Code's "sticky scroll" feature.

    This prevents "floating code" where a fragment is shown without any
    indication of which class or function it belongs to.

    Ported from Agentless ``preprocess_data.py:16-55`` (sticky_scroll).
    Adapted to be multi-language via keyword heuristics instead of
    Python-only indent detection.

    Args:
        lines: All lines of the file (0-indexed list).
        start_line: First line to display (1-based, inclusive).
        end_line: Last line to display (1-based, inclusive).
        max_context_lines: Maximum number of scope context lines to inject.
        context_prefix: Prefix for context lines (default: ``"// "``).

    Returns:
        A list of strings: context lines (prefixed) followed by the
        requested fragment lines. If no enclosing scopes are found,
        returns just the fragment lines.

    Examples:
        >>> lines = [
        ...     "class MyClass:",
        ...     "    def my_method(self):",
        ...     "        x = 1",
        ...     "        y = 2",
        ...     "        return x + y",
        ... ]
        >>> result = inject_scope_context(lines, 3, 5)
        >>> result[0]  # context: class
        '// class MyClass:'
        >>> result[1]  # context: method
        '//     def my_method(self):'
        >>> result[2]  # actual line 3
        '        x = 1'

        >>> # No enclosing scope → just the fragment
        >>> lines = ["x = 1", "y = 2"]
        >>> inject_scope_context(lines, 1, 2)
        ['x = 1', 'y = 2']
    """
    # Convert to 0-based
    start_idx = max(0, start_line - 1)
    end_idx = min(len(lines), end_line)

    if start_idx >= len(lines):
        return []

    # Fragment lines
    fragment = lines[start_idx:end_idx]
    if not fragment:
        return []

    # Scan lines BEFORE the fragment to build scope stack
    # The scope stack tracks enclosing scopes at decreasing indent levels
    scopes: list[tuple[int, str]] = []  # (indent_level, line_text)

    for i in range(start_idx):
        line = lines[i]
        if not line.strip():
            continue
        if _is_scope_line(line):
            indent = _indent_level(line)
            # Pop any scopes at same or deeper indent level
            while scopes and scopes[-1][0] >= indent:
                scopes.pop()
            scopes.append((indent, line.rstrip()))

    # Filter: only keep scopes that are at a shallower indent than
    # the first non-empty line of the fragment
    first_non_empty = next((line for line in fragment if line.strip()), None)
    if first_non_empty is not None:
        fragment_indent = _indent_level(first_non_empty)
        scopes = [(lvl, text) for lvl, text in scopes if lvl < fragment_indent]

    # Limit context lines
    if len(scopes) > max_context_lines:
        scopes = scopes[-max_context_lines:]

    # Build result: context lines + fragment
    context = [f"{context_prefix}{text}" for _, text in scopes]
    return context + list(fragment)


# ---------------------------------------------------------------------------
# Truncation with guidance message (ADOPT #6)
# ---------------------------------------------------------------------------

DEFAULT_TRUNCATION_HINT = (
    "... [output truncated at {limit} chars, try being more specific or paginating]"
)

# Tool-specific hints for better UX
TRUNCATION_HINTS = {
    "grep": (
        "... [output truncated, be more specific with pattern "
        "or use directory path to narrow search]"
    ),
    "list_files": (
        "... [output truncated, directory has too many entries, "
        "try a subdirectory or non-recursive listing]"
    ),
    "read_file": (
        "... [output truncated, file is too large, "
        "use start_line/num_lines parameters to read in chunks]"
    ),
    "shell": (
        "... [output truncated, command produced too much output, "
        "try filtering with grep or redirecting to a file]"
    ),
}


@overload
def truncate_with_guidance(
    result: str,
    *,
    limit_chars: int = 80_000,
    hint: str | None = None,
    tool_name: str | None = None,
) -> str: ...


@overload
def truncate_with_guidance(
    result: list[str],
    *,
    limit_chars: int = 80_000,
    hint: str | None = None,
    tool_name: str | None = None,
) -> list[str]: ...


def truncate_with_guidance(
    result: str | list[str],
    *,
    limit_chars: int = 80_000,
    hint: str | None = None,
    tool_name: str | None = None,
) -> str | list[str]:
    """Truncate content if it exceeds a character limit, with helpful guidance.

    Args:
        result: Content to potentially truncate (string or list of strings)
        limit_chars: Maximum character limit before truncation
        hint: Custom hint message (uses default if None). Can use {limit} placeholder.
        tool_name: Name of tool for tool-specific hints (e.g., "grep", "read_file")

    Returns:
        Truncated content with guidance message appended if truncated

    Examples:
        >>> truncate_with_guidance("short text", limit_chars=1000)
        'short text'

        >>> result = truncate_with_guidance("a" * 100000, limit_chars=80_000)
        >>> result.endswith("try being more specific or paginating]")
        True
        >>> len(result) <= 80_000 + 100  # Plus guidance message
        True
    """
    # Resolve hint message
    if hint is None:
        if tool_name and tool_name in TRUNCATION_HINTS:
            hint = TRUNCATION_HINTS[tool_name]
        else:
            hint = DEFAULT_TRUNCATION_HINT

    # Replace placeholder if present
    hint = hint.format(limit=limit_chars)

    if isinstance(result, list):
        total_chars = sum(len(item) for item in result)
        if total_chars > limit_chars:
            # Keep proportional subset
            if total_chars > 0:
                keep = len(result) * limit_chars // total_chars
                # Ensure at least one item if possible
                keep = max(1, min(keep, len(result) - 1)) if len(result) > 1 else 0
                return result[:keep] + [hint]
            return [hint]
        return result

    if len(result) > limit_chars:
        # Truncate and add guidance
        truncation_point = limit_chars
        # Don't cut off in the middle of a wide character if possible
        # Just cut at the limit for simplicity
        return result[:truncation_point] + "\n" + hint

    return result


# ---------------------------------------------------------------------------
# O_NOFOLLOW safe file write helper (ADOPT #3)
# ---------------------------------------------------------------------------


def open_nofollow(
    path: str,
    mode: str = "w",
    encoding: str = "utf-8",
) -> object:
    """Open a file with O_NOFOLLOW flag to prevent symlink attacks.

    Uses os.open() with O_NOFOLLOW flag when available (Unix-like systems),
    then wraps the file descriptor with os.fdopen() for normal file operations.
    Gracefully degrades on Windows where O_NOFOLLOW may not exist.

    SECURITY: This prevents symlink attacks where an attacker creates a
    symlink from a trusted path to a sensitive file (e.g., /etc/passwd).

    Args:
        path: File path to open
        mode: File mode (only "w" and "wb" supported currently)
        encoding: Text encoding (for text mode)

    Returns:
        File object suitable for use with 'with' statement

    Raises:
        OSError: If the file is a symlink (ELOOP) or other open error
        ValueError: If unsupported mode is specified

    Example:
        >>> with open_nofollow("/tmp/test.txt", "w") as f:
        ...     f.write("safe content")

    Note:
        On Windows, falls back to regular open() since O_NOFOLLOW may not
        be available. The symlink risk is primarily on Unix-like systems.
    """
    # Only supporting write modes for security context
    if mode not in ("w", "wb"):
        raise ValueError(f"Unsupported mode: {mode}. Only 'w' and 'wb' are supported.")

    # Check for O_NOFOLLOW support (Unix-like systems)
    if hasattr(os, "O_NOFOLLOW"):
        # Build flags: write-only, create, truncate, don't follow symlinks
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
        # Default permissions: rw-r--r-- (readable by all, writable by owner)
        fd = os.open(path, flags, 0o644)

        # Convert file descriptor to file object
        # Use binary mode if requested, otherwise text mode with encoding
        if mode == "wb":
            return os.fdopen(fd, "wb")
        else:
            return os.fdopen(fd, "w", encoding=encoding)
    else:
        # Graceful degradation on Windows or other systems without O_NOFOLLOW
        return open(path, mode, encoding=encoding if mode != "wb" else None)


def safe_write_file(path: str, content: str, encoding: str = "utf-8") -> None:
    """Write content to file with O_NOFOLLOW protection.

    This is the recommended way to create or overwrite files in security-sensitive
    contexts. Prevents symlink attacks by refusing to follow symlinks.

    Args:
        path: Target file path
        content: Content to write
        encoding: Text encoding for the file

    Raises:
        OSError: If the path is a symlink (errno.ELOOP) or other error
    """
    with open_nofollow(path, "w", encoding=encoding) as f:
        f.write(content)
