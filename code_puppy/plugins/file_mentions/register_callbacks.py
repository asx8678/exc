"""Auto-read file mentions from user prompts.

Ported from oh-my-pi's file-mentions.ts pattern.

When users reference files with @path syntax (e.g., "@src/foo.py"),
this plugin automatically injects the file contents into the system
prompt context so the agent can see them without needing explicit
read_file tool calls — reducing round trips.

Registers:
  - ``load_prompt`` hook: injects instructions about @file support
  - ``custom_command`` hook: handles /file-mentions command

Config (puppy.cfg):
    [file_mentions]
    enabled = true
    max_file_size_bytes = 5242880   # 5MB
    max_files_per_prompt = 10
    max_dir_entries = 500
"""

import logging
import os
import re

from code_puppy.callbacks import register_callback

logger = logging.getLogger(__name__)

# --- Configuration defaults ---
_DEFAULT_MAX_FILE_SIZE = 5 * 1024 * 1024  # 5MB
_DEFAULT_MAX_FILES = 10
_DEFAULT_MAX_DIR_ENTRIES = 500

# --- Regex patterns ---
# Match @filepath patterns — require at least one path separator or dot
# to avoid false positives on @mentions in natural language
_FILE_MENTION_RE = re.compile(r"@((?:[a-zA-Z0-9_\-.][\w\-.]*/)*[\w\-]+(?:\.\w+)?)")
_LEADING_PUNCT_RE = re.compile(r"^[`\"'\(\[\{<]+")
_TRAILING_PUNCT_RE = re.compile(r"[)\]}>.,;:!\"'`]+$")
_MENTION_BOUNDARY_RE = re.compile(r"[\s(\[\{<\"'`]")

# State
_enabled = True
_stats = {"mentions_found": 0, "files_resolved": 0, "files_failed": 0}


def _is_mention_boundary(text: str, index: int) -> bool:
    """Check if the character before @mention is a valid boundary."""
    if index == 0:
        return True
    return bool(_MENTION_BOUNDARY_RE.match(text[index - 1]))


def _sanitize_mention_path(raw_path: str) -> str | None:
    """Clean up a raw mention path by stripping surrounding punctuation."""
    cleaned = raw_path.strip()
    cleaned = _LEADING_PUNCT_RE.sub("", cleaned)
    cleaned = _TRAILING_PUNCT_RE.sub("", cleaned)
    cleaned = cleaned.strip()
    return cleaned if cleaned else None


def extract_file_mentions(text: str) -> list[str]:
    """Extract @filepath mentions from text.

    Returns deduplicated list of cleaned file paths found in the text.
    Only includes mentions that have a path-like structure (contain
    a dot or slash) to avoid false positives on @username patterns.

    Args:
        text: User prompt text to scan.

    Returns:
        List of unique file paths mentioned with @ prefix.
    """
    mentions: list[str] = []
    seen: set[str] = set()

    for match in _FILE_MENTION_RE.finditer(text):
        index = match.start()
        if not _is_mention_boundary(text, index):
            continue

        raw = match.group(1)
        cleaned = _sanitize_mention_path(raw)
        if not cleaned:
            continue

        # Require path-like structure: must have a dot or slash
        # This filters out @username, @mention etc.
        if "." not in cleaned and "/" not in cleaned:
            continue

        if cleaned not in seen:
            seen.add(cleaned)
            mentions.append(cleaned)

    return mentions


def resolve_mention_path(file_path: str, cwd: str | None = None) -> str | None:
    """Resolve a mention path to an absolute path if the file exists.

    Args:
        file_path: Relative or absolute path from the @mention.
        cwd: Working directory to resolve relative paths against.

    Returns:
        Absolute path if the file exists, or None.
    """
    if cwd is None:
        cwd = os.getcwd()

    # Try as-is first (relative to cwd)
    candidate = os.path.join(cwd, file_path)
    if os.path.exists(candidate):
        return os.path.abspath(candidate)

    # Try absolute
    if os.path.isabs(file_path) and os.path.exists(file_path):
        return file_path

    return None


def _read_file_content(
    abs_path: str,
    max_size: int = _DEFAULT_MAX_FILE_SIZE,
) -> str | None:
    """Read file content with size limit.

    Args:
        abs_path: Absolute path to the file.
        max_size: Maximum file size in bytes.

    Returns:
        File content as string, or None if too large or unreadable.
    """
    try:
        size = os.path.getsize(abs_path)
        if size > max_size:
            logger.debug(
                "file_mentions: skipping %s (%.1f MB > %.1f MB limit)",
                abs_path,
                size / (1024 * 1024),
                max_size / (1024 * 1024),
            )
            return None

        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError as exc:
        logger.debug("file_mentions: cannot read %s: %s", abs_path, exc)
        return None


def _list_directory(
    abs_path: str,
    max_entries: int = _DEFAULT_MAX_DIR_ENTRIES,
) -> str | None:
    """List directory contents for @dir mentions.

    Args:
        abs_path: Absolute path to the directory.
        max_entries: Maximum number of entries to list.

    Returns:
        Formatted directory listing, or None on error.
    """
    try:
        entries = sorted(os.listdir(abs_path))[:max_entries]
        lines = []
        for entry in entries:
            full = os.path.join(abs_path, entry)
            suffix = "/" if os.path.isdir(full) else ""
            lines.append(f"{entry}{suffix}")
        if len(os.listdir(abs_path)) > max_entries:
            lines.append(f"... ({len(os.listdir(abs_path)) - max_entries} more)")
        return "\n".join(lines) if lines else "(empty directory)"
    except OSError as exc:
        logger.debug("file_mentions: cannot list %s: %s", abs_path, exc)
        return None


def generate_file_mention_context(
    text: str,
    cwd: str | None = None,
    max_files: int = _DEFAULT_MAX_FILES,
) -> str | None:
    """Generate context from @file mentions in text.

    Extracts @filepath mentions, reads the referenced files, and
    returns a formatted context block for injection into the prompt.

    Args:
        text: User prompt text to scan for mentions.
        cwd: Working directory for relative path resolution.
        max_files: Maximum number of files to include.

    Returns:
        Formatted context string, or None if no files were resolved.
    """
    if not _enabled:
        return None

    mentions = extract_file_mentions(text)
    if not mentions:
        return None

    _stats["mentions_found"] += len(mentions)
    parts: list[str] = []

    for mention in mentions[:max_files]:
        resolved = resolve_mention_path(mention, cwd)
        if resolved is None:
            _stats["files_failed"] += 1
            continue

        _stats["files_resolved"] += 1

        if os.path.isdir(resolved):
            listing = _list_directory(resolved)
            if listing:
                parts.append(
                    f'<file_mention path="{mention}" type="directory">\n'
                    f"{listing}\n"
                    f"</file_mention>"
                )
        else:
            content = _read_file_content(resolved)
            if content is not None:
                line_count = content.count("\n") + 1
                parts.append(
                    f'<file_mention path="{mention}" lines="{line_count}">\n'
                    f"{content}\n"
                    f"</file_mention>"
                )

    if not parts:
        return None

    return (
        "\n\n## Auto-loaded @file mentions\n\n"
        "The following files were referenced with @path syntax "
        "and auto-loaded for context:\n\n" + "\n\n".join(parts)
    )


# --- Callback hooks ---


def _on_load_prompt() -> str | None:
    """Inject @file mention support instructions into the system prompt."""
    if not _enabled:
        return None

    return (
        "\n\n## @file mention support\n\n"
        "Users can reference files with @path syntax (e.g., @src/main.py). "
        "When they do, the file contents are automatically loaded and "
        "included in the context above. You do not need to use read_file "
        "for @-mentioned files — their contents are already available."
    )


def _on_custom_command(command: str, name: str) -> bool | str | None:
    """Handle /file-mentions command."""
    global _enabled

    if name != "file-mentions":
        return None

    parts = command.strip().split()
    if len(parts) == 1:
        # Show status
        status = "enabled" if _enabled else "disabled"
        return (
            f"@file mentions: {status}\n"
            f"Stats: {_stats['mentions_found']} found, "
            f"{_stats['files_resolved']} resolved, "
            f"{_stats['files_failed']} failed"
        )

    action = parts[1].lower() if len(parts) > 1 else ""
    if action in ("on", "enable"):
        _enabled = True
        return True
    elif action in ("off", "disable"):
        _enabled = False
        return True
    elif action == "reset":
        _stats["mentions_found"] = 0
        _stats["files_resolved"] = 0
        _stats["files_failed"] = 0
        return True

    return None


def _on_custom_command_help() -> list[tuple[str, str]]:
    """Provide help text for /file-mentions command."""
    return [
        ("/file-mentions", "Show @file mention status and stats"),
        ("/file-mentions on|off", "Enable/disable @file auto-reading"),
    ]


# --- Registration ---

register_callback("load_prompt", _on_load_prompt)
register_callback("custom_command", _on_custom_command)
register_callback("custom_command_help", _on_custom_command_help)

logger.debug("file_mentions plugin registered")
