"""Error logging utility for code_puppy.

Logs unexpected errors to XDG_STATE_HOME/code_puppy/logs/ for debugging purposes.
Per XDG spec, logs are "state data" (actions history), not configuration.
Because even good puppies make mistakes sometimes! 🐶
"""

import json as _json_for_display
import re as _re_for_display
import sys
import traceback
from datetime import datetime
from pathlib import Path

from code_puppy.config import STATE_DIR

# Pre-compiled regex patterns for error display formatting
_ERROR_PREFIX_PATTERNS: list[_re_for_display.Pattern[str]] = [
    # Short exception type prefix: "ValueError: foo" -> "foo"
    _re_for_display.compile(r"^[A-Z][A-Za-z0-9]*Error: "),
    # Fully-qualified exception: "foo.bar.BazError: msg" -> "msg"
    _re_for_display.compile(r"^[a-zA-Z_][\w.]*\.[A-Z][A-Za-z0-9]*Error: "),
    # HTTP/API style: "API 500: something" -> "something"
    _re_for_display.compile(r"^API \d+:\s*"),
    # Generic status prefix: "HTTP 404: foo" -> "foo"
    _re_for_display.compile(r"^HTTP \d+:\s*"),
]

_WHITESPACE_RUN = _re_for_display.compile(r"\s+")

# Logs directory within the state directory (per XDG spec, logs are state data)
LOGS_DIR = Path(STATE_DIR) / "logs"
ERROR_LOG_FILE = LOGS_DIR / "errors.log"
MAX_LOG_SIZE = 5 * 1024 * 1024  # 5MB


def _rotate_log_if_needed() -> None:
    """Rotate the error log file if it exceeds MAX_LOG_SIZE."""
    try:
        if ERROR_LOG_FILE.exists() and ERROR_LOG_FILE.stat().st_size > MAX_LOG_SIZE:
            rotated = ERROR_LOG_FILE.parent / (ERROR_LOG_FILE.name + ".1")
            ERROR_LOG_FILE.replace(rotated)
    except OSError:
        pass


def _ensure_logs_dir() -> None:
    """Create the logs directory if it doesn't exist (with 0700 perms per XDG spec)."""
    Path(LOGS_DIR).mkdir(parents=True, exist_ok=True, mode=0o700)


def log_error(
    error: Exception, context: str | None = None, include_traceback: bool = True
) -> None:
    """Log an error to the error log file.

    Args:
        error: The exception to log
        context: Optional context string describing where the error occurred
        include_traceback: Whether to include the full traceback (default True)
    """
    try:
        _ensure_logs_dir()
        _rotate_log_if_needed()

        timestamp = datetime.now().isoformat()
        error_type = type(error).__name__
        error_msg = str(error)

        log_entry_parts = [
            f"\n{'=' * 80}",
            f"Timestamp: {timestamp}",
            f"Error Type: {error_type}",
            f"Error Message: {error_msg}",
        ]

        if context:
            log_entry_parts.append(f"Context: {context}")

        if include_traceback:
            tb = traceback.format_exception(type(error), error, error.__traceback__)
            log_entry_parts.append(f"Traceback:\n{''.join(tb)}")

        if hasattr(error, "args") and error.args:
            log_entry_parts.append(f"Args: {error.args}")

        log_entry_parts.append(f"{'=' * 80}\n")

        log_entry = "\n".join(log_entry_parts)

        with open(ERROR_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(log_entry)

    except Exception as _log_exc:
        # Last-resort: write to stderr so the failure isn't invisible.
        try:
            sys.stderr.write(
                f"[code_puppy] error_logging.log_error() failed: {_log_exc}\n"
            )
        except Exception:
            pass  # truly nothing we can do


def log_error_message(message: str, context: str | None = None) -> None:
    """Log a simple error message without an exception object.

    Args:
        message: The error message to log
        context: Optional context string describing where the error occurred
    """
    try:
        _ensure_logs_dir()
        _rotate_log_if_needed()

        timestamp = datetime.now().isoformat()

        log_entry_parts = [
            f"\n{'=' * 80}",
            f"Timestamp: {timestamp}",
            f"Message: {message}",
        ]

        if context:
            log_entry_parts.append(f"Context: {context}")

        log_entry_parts.append(f"{'=' * 80}\n")

        log_entry = "\n".join(log_entry_parts)

        with open(ERROR_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(log_entry)

    except Exception as _log_exc:
        # Last-resort: write to stderr so the failure isn't invisible.
        try:
            sys.stderr.write(
                f"[code_puppy] error_logging.log_error_message() failed: {_log_exc}\n"
            )
        except Exception:
            pass  # truly nothing we can do


def get_log_file_path() -> Path:
    """Return the path to the error log file."""
    return ERROR_LOG_FILE


def get_logs_dir() -> Path:
    """Return the path to the logs directory."""
    return LOGS_DIR


def _maybe_json(s: str) -> bool:
    """Return True if s looks like a JSON object or array."""
    s = s.strip()
    if s.startswith("{") and s.endswith("}"):
        return True
    if s.startswith("[") and s.endswith("]"):
        return True
    return False


def _pretty_json(s: str) -> str:
    """Pretty-print a JSON string; return s unchanged on parse failure."""
    try:
        parsed = _json_for_display.loads(s)
    except ValueError, _json_for_display.JSONDecodeError:
        return s
    return _json_for_display.dumps(parsed, indent=2)


def _format_chained_error(msg: str) -> str:
    """Split a `: `-chained error message into an indented tree.

    Mirrors plandex's app/cli/term/errors.go OutputErrorAndExit segment walker:
    - Splits by ': '
    - Dedupes repeated segments (case-insensitive)
    - Collapses very short segments (< 10 chars) into the previous one
    - Detects JSON tails and pretty-prints them
    - Indents successive segments with '  → ' prefix
    """
    # Normalize common noise patterns
    msg = msg.replace("status code:", "status code")
    msg = msg.replace(", body:", ":")

    parts = msg.split(": ")
    if len(parts) <= 1:
        return msg

    seen: set[str] = set()
    out_lines: list[str] = []
    indent_level = 0
    last_part = ""

    for idx, part in enumerate(parts):
        key = part.lower()
        if key in seen:
            continue

        # Check if the remaining tail is JSON — if so, pretty-print it and stop
        tail = ": ".join(parts[idx:])
        if _maybe_json(tail):
            pretty = _pretty_json(tail)
            indent = "  " * indent_level
            # Prepend indent to each line of the pretty JSON
            indented_pretty = pretty.replace("\n", "\n" + indent + "  ")
            out_lines.append("\n" + indent + "→ " + indented_pretty)
            break

        # Collapse short segments (< 10 chars) into the previous one
        if len(last_part) < 10 and indent_level > 0 and out_lines:
            last_part = last_part + ": " + part
            out_lines[-1] = out_lines[-1] + ": " + part
            seen.add(last_part.lower())
            seen.add(key)
            continue

        # Normal segment — add with indent
        prefix = ""
        if indent_level > 0:
            prefix = "\n" + ("  " * indent_level) + "→ "
        # Capitalize first letter of segment (plandex uses shared.Capitalize)
        display = part[:1].upper() + part[1:] if part else part
        out_lines.append(prefix + display)

        seen.add(key)
        last_part = part
        indent_level += 1

    return "".join(out_lines)


def format_error_for_display(
    exc: BaseException,
    *,
    include_type: bool = False,
    max_length: int = 500,
) -> str:
    """Format an exception for user-facing display.

    Strips common noisy prefixes (exception type names, HTTP status codes),
    collapses whitespace, and truncates to a reasonable length. Never raises —
    falls back to repr(exc) if str(exc) itself fails.

    Args:
        exc: The exception to format.
        include_type: If True, prefix the cleaned message with "[ExcType] ".
        max_length: Maximum length; longer messages are truncated with "...".

    Returns:
        A cleaned, user-friendly message string.

    Examples:
        >>> format_error_for_display(ValueError("bad input"))
        'bad input'
        >>> format_error_for_display(ValueError("bad input"), include_type=True)
        '[ValueError] bad input'
    """
    try:
        raw = str(exc)
    except Exception:  # pragma: no cover - defensive
        try:
            raw = repr(exc)
        except Exception:
            return f"<unrepresentable {type(exc).__name__}>"

    if not raw:
        raw = type(exc).__name__

    cleaned = raw.strip()

    # Strip noisy prefixes (loop in case multiple apply)
    # Apply the longest-prefix patterns first. Since we're walking the list,
    # we iterate until no pattern matches in a single pass.
    for _ in range(3):  # max 3 passes to prevent pathological loops
        changed = False
        for pattern in _ERROR_PREFIX_PATTERNS:
            new = pattern.sub("", cleaned, count=1)
            if new != cleaned:
                cleaned = new.lstrip()
                changed = True
                break
        if not changed:
            break

    # NEW: Apply chained-error formatting for messages with ": " segments.
    # This re-introduces newlines for readability, so we skip the aggressive
    # whitespace collapse for chained errors (they have structure we want to keep).
    if ": " in cleaned:
        cleaned = _format_chained_error(cleaned)
    else:
        # Collapse whitespace runs (including newlines) to single spaces
        cleaned = _WHITESPACE_RUN.sub(" ", cleaned).strip()

    if not cleaned:
        cleaned = type(exc).__name__

    # Truncate if needed (line-by-line for multi-line output)
    if len(cleaned) > max_length:
        # For multi-line output, try to truncate gracefully
        if "\n" in cleaned:
            lines = cleaned.split("\n")
            truncated_lines = []
            current_len = 0
            for line in lines:
                if current_len + len(line) + 1 > max_length - 3:
                    truncated_lines.append("...")
                    break
                truncated_lines.append(line)
                current_len += len(line) + 1
            cleaned = "\n".join(truncated_lines)
        else:
            # Leave room for ellipsis
            cleaned = cleaned[: max_length - 3].rstrip() + "..."

    if include_type:
        cleaned = f"[{type(exc).__name__}] {cleaned}"

    return cleaned
