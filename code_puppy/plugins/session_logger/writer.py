"""SessionWriter - manages log files for a single agent run session."""

import json
import logging
import re
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Module-level compiled regexes for sensitive key detection (SECURITY FIX rtq)
# Uses word boundaries to avoid false positives like "secretary" or "tokenizer"
# Also handles underscore-delimited keys like AWS_SECRET_ACCESS_KEY
_SENSITIVE_KEY_PATTERN = re.compile(
    r"(?:^|[\b_\-])(password|secret|token|api[_-]?key|credential|access[_-]?key|"
    r"private[_-]?key|auth|authorization|bearer|connection[_-]?string)(?:$|[\b_\-])",
    re.IGNORECASE,
)

# Pattern for repr() redaction (key=value style patterns)
# Matches keys in quotes followed by colon, or key=value patterns
_REPR_SENSITIVE_KEY_PATTERN = re.compile(
    r"(?:^|[\b_\-])(password|secret|token|api[_-]?key|credential|access[_-]?key|"
    r"private[_-]?key|auth|authorization|bearer|connection[_-]?string)(?:$|[\b_\-])",
    re.IGNORECASE,
)


class SessionWriter:
    """Manages log files for a single agent run session.

    Thread-safe writer that holds file handles for one session.
    Creates three files:
    - main_agent.log: human-readable conversation transcript
    - tool_calls.jsonl: machine-readable tool invocations
    - manifest.json: session metadata
    """

    def __init__(
        self, session_dir: Path, agent_name: str, model_name: str, session_id: str
    ):
        """Initialize session writer.

        Args:
            session_dir: Directory to write session files
            agent_name: Name of the agent running
            model_name: Name of the model being used
            session_id: Unique session identifier
        """
        self.session_dir = session_dir
        self._lock = threading.Lock()
        self._start_time = datetime.now(timezone.utc)
        self._tool_count = 0
        self._pending_tool_calls: dict[
            str, dict[str, Any]
        ] = {}  # For handling missing post_tool_call
        self._manifest_data: dict[str, Any] = {
            "session_id": session_id,
            "agent_name": agent_name,
            "model_name": model_name,
            "started_at": self._start_time.isoformat(),
            "ended_at": None,
            "duration_seconds": None,
            "success": None,
            "error": None,
            "tool_call_count": 0,
        }

        # Create directory and write initial manifest
        try:
            self.session_dir.mkdir(parents=True, exist_ok=True)
            self._write_manifest()
            logger.debug(
                f"SessionWriter initialized for session {session_id} in {session_dir}"
            )
        except OSError as e:
            logger.error(f"Failed to create session directory {session_dir}: {e}")
            raise

    def append_log(self, text: str) -> None:
        """Append to main_agent.log (human-readable).

        Args:
            text: Text to append with automatic timestamp prefix
        """
        with self._lock:
            try:
                line = f"[{datetime.now(timezone.utc).isoformat()}] {text}\n"
                log_path = self.session_dir / "main_agent.log"
                with log_path.open("a", encoding="utf-8") as f:
                    f.write(line)
            except OSError as e:
                logger.warning(f"Failed to write to main_agent.log: {e}")

    def record_pre_tool_call(
        self, tool_name: str, tool_args: dict, context: Any = None
    ) -> str:
        """Record that a tool call is starting.

        Args:
            tool_name: Name of the tool being called
            tool_args: Arguments passed to the tool
            context: Optional context data

        Returns:
            call_id: Unique identifier for this tool call to match with post_tool_call
        """
        import uuid

        call_id = f"{tool_name}-{uuid.uuid4().hex[:8]}"
        timestamp = datetime.now(timezone.utc).isoformat()

        with self._lock:
            self._pending_tool_calls[call_id] = {
                "timestamp": timestamp,
                "tool_name": tool_name,
                "args": _safe_serialize(tool_args),
                "context": _safe_serialize(context) if context else None,
            }

        return call_id

    def append_tool_call(
        self,
        tool_name: str,
        tool_args: dict,
        result: Any = None,
        duration_ms: float | None = None,
        error: str | None = None,
        call_id: str | None = None,
    ) -> None:
        """Append a tool call record to tool_calls.jsonl.

        Args:
            tool_name: Name of the tool
            tool_args: Arguments passed to the tool
            result: Result returned by the tool (optional)
            duration_ms: Execution time in milliseconds (optional)
            error: Error message if tool failed (optional)
            call_id: Optional call ID from record_pre_tool_call for matching
        """
        with self._lock:
            # Check if we have pending data from pre_tool_call
            pending = self._pending_tool_calls.pop(call_id, None) if call_id else None

            record: dict[str, Any] = {
                "timestamp": pending["timestamp"]
                if pending
                else datetime.now(timezone.utc).isoformat(),
                "tool_name": tool_name,
                "args": pending["args"] if pending else _safe_serialize(tool_args),
                "result": _safe_serialize(result) if result is not None else None,
                "duration_ms": duration_ms,
                "error": error,
            }

            self._tool_count += 1

            try:
                jsonl_path = self.session_dir / "tool_calls.jsonl"
                with jsonl_path.open("a", encoding="utf-8") as f:
                    f.write(json.dumps(record, ensure_ascii=False) + "\n")
            except OSError as e:
                logger.warning(f"Failed to write to tool_calls.jsonl: {e}")

    def finalize(self, success: bool, error: str | None = None) -> None:
        """Write final manifest with duration and outcome.

        Also handles any pending tool calls that didn't get a post_tool_call
        (e.g., if tool raised exception).

        Args:
            success: Whether the session completed successfully
            error: Error message if session failed
        """
        with self._lock:
            # Handle any pending tool calls without matching post_tool_call
            for call_id, pending in list(self._pending_tool_calls.items()):
                # Record them with incomplete status
                record = {
                    "timestamp": pending["timestamp"],
                    "tool_name": pending["tool_name"],
                    "args": pending["args"],
                    "result": None,
                    "duration_ms": None,
                    "error": "Tool call incomplete (no post_tool_call received - possible exception)",
                }
                try:
                    jsonl_path = self.session_dir / "tool_calls.jsonl"
                    with jsonl_path.open("a", encoding="utf-8") as f:
                        f.write(json.dumps(record, ensure_ascii=False) + "\n")
                    self._tool_count += 1
                except OSError as e:
                    logger.warning(f"Failed to write pending tool call: {e}")

            self._pending_tool_calls.clear()

            end_time = datetime.now(timezone.utc)
            self._manifest_data["ended_at"] = end_time.isoformat()
            self._manifest_data["duration_seconds"] = (
                end_time - self._start_time
            ).total_seconds()
            self._manifest_data["success"] = success
            self._manifest_data["error"] = error
            self._manifest_data["tool_call_count"] = self._tool_count

            try:
                self._write_manifest()
                logger.debug(
                    f"Session finalized: success={success}, duration={self._manifest_data['duration_seconds']:.2f}s, tools={self._tool_count}"
                )
            except OSError as e:
                logger.warning(f"Failed to write final manifest: {e}")

    def _write_manifest(self) -> None:
        """Write the manifest.json file atomically."""
        manifest_path = self.session_dir / "manifest.json"
        tmp_path = manifest_path.with_suffix(".tmp")

        try:
            # Write to temp file first, then rename for atomicity
            with tmp_path.open("w", encoding="utf-8") as f:
                json.dump(self._manifest_data, f, indent=2, default=str)

            # Atomic rename on most systems
            tmp_path.rename(manifest_path)
        except OSError as e:
            logger.warning(f"Failed to write manifest atomically: {e}")
            # Fallback: direct write
            with manifest_path.open("w", encoding="utf-8") as f:
                json.dump(self._manifest_data, f, indent=2, default=str)


def _redact_secrets_from_dict(obj: dict) -> dict:
    """Return a copy of dict with sensitive values redacted.

    SECURITY FIX rtq: Recursively redact values under sensitive-looking keys.
    Uses word boundaries to avoid false positives (e.g., "secretary" won't match "secret").
    """
    result = {}
    for key, value in obj.items():
        # Use word boundary matching to avoid false positives like "secretary", "tokenizer"
        if _SENSITIVE_KEY_PATTERN.search(str(key)):
            # Redact values for sensitive keys (but keep small ints/bools for context)
            if isinstance(value, (str, bytes)) and len(str(value)) > 0:
                result[key] = "[REDACTED]"
            elif isinstance(value, dict):
                result[key] = _redact_secrets_from_dict(value)
            elif isinstance(value, list):
                result[key] = [_redact_if_dict(v) for v in value]
            else:
                result[key] = value  # Keep numbers/bools as-is
        elif isinstance(value, dict):
            result[key] = _redact_secrets_from_dict(value)
        elif isinstance(value, list):
            result[key] = [_redact_if_dict(v) for v in value]
        else:
            result[key] = value
    return result


def _redact_if_dict(v: Any) -> Any:
    """Helper to recursively redact dicts inside lists."""
    if isinstance(v, dict):
        return _redact_secrets_from_dict(v)
    elif isinstance(v, list):
        return [_redact_if_dict(item) for item in v]
    return v


def _safe_serialize(obj: Any) -> Any:
    """Convert obj to JSON-serializable form, falling back to repr for unsupported types.

    SECURITY FIX rtq: Scrubs secrets from repr() fallback before writing to logs.

    Args:
        obj: Object to serialize

    Returns:
        JSON-serializable representation, or truncated repr string with secrets redacted
    """
    if obj is None:
        return None

    # Handle common serializable types
    if isinstance(obj, (str, int, float, bool)):
        return obj

    # Try standard JSON serialization
    try:
        json.dumps(obj)
        # SECURITY FIX rtq: For dicts/mappings, redact sensitive values before returning
        if isinstance(obj, dict):
            return _redact_secrets_from_dict(obj)
        return obj
    except TypeError, ValueError:
        pass

    # Convert Path objects
    if isinstance(obj, Path):
        return str(obj)

    # Handle bytes
    if isinstance(obj, bytes):
        return f"<bytes:{len(obj)}>"

    # For other types, use repr with length cap
    _repr = repr(obj)[:1000]

    # SECURITY FIX rtq: Redact password/secret/token/api-key/credential patterns
    # Uses word boundaries to avoid false positives like "secretary", "tokenizer"
    # Handles underscore-delimited keys like AWS_SECRET_ACCESS_KEY
    # Redact key=value style patterns where key looks sensitive
    # Pattern 1: key=value or key:value (including function call style like Config(api_key='xxx'))
    _repr = re.sub(
        r"([\w\-]*?(?:password|secret|token|api[_-]?key|credential|access[_-]?key|"
        r"private[_-]?key|auth|authorization|bearer|connection[_-]?string)[\w\-]*)"
        r'["\'\s]*[=:]+["\'\s]*([^"\'\s,}\]]{3,})',
        r"\1=[REDACTED]",
        _repr,
        flags=re.IGNORECASE,
    )
    # Redact values in dict-looking structures under sensitive keys
    # Matches 'key': 'value' or "key": "value" or Config(key='value') patterns
    _repr = re.sub(
        r"(['\"])"
        r"([\w\-]*?(?:password|secret|token|api[_-]?key|credential|access[_-]?key|"
        r"private[_-]?key|auth|authorization|bearer|connection[_-]?string)[\w\-]*?)"
        r"\1\s*:\s*['\"]?([^'\"},\]]{3,})['\"]?",
        r"'\2': '[REDACTED]'",
        _repr,
        flags=re.IGNORECASE,
    )

    return f"<non-serializable:{_repr}>"
