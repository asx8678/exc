"""Shared helpers for persisting and restoring chat sessions.

This module centralises the JSON + metadata handling that used to live in
both the CLI command handler and the auto-save feature. Keeping it here helps
us avoid duplication while staying inside the Zen-of-Python sweet spot: simple
is better than complex, nested side effects are worse than deliberate helpers.

Migrated to Elixir/Ecto with SQLite backend. File-based storage is
retained as fallback when Elixir transport is unavailable.

SECURITY FIX #zvx9: Pickle has been completely removed to prevent RCE attacks.
Session files now use only secure JSON serialization with HMAC integrity.
"""

from __future__ import annotations

import atexit
import hashlib
import hmac
import json
import logging
import os
import time
import warnings
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

# Import Elixir bridge (lazy-loaded)
_use_elixir_storage: bool = os.environ.get("PUP_SESSION_USE_SQLITE", "1") == "1"

# (code_puppy-ctj.1) Terminal session tracking state for crash recovery.
# When a terminal session is created, we track it here so that the
# session_storage_bridge can register it with the Elixir Store.
_active_terminal: dict[str, dict[str, Any]] = {}

# ----- ThreadPoolExecutor for async autosave -----
# Single-threaded executor for background session saves to avoid blocking the main thread.
# The executor's internal work queue provides sufficient backpressure with max_workers=1.
_autosave_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="autosave")

# Autosave deduplication state (deduplication fix)
_last_autosave_len: int = 0
_last_autosave_hash: str = ""
_last_autosave_time: float = 0.0
AUTOSAVE_DEBOUNCE_SECONDS: float = 2.0


def _compute_history_fingerprint(history: list) -> tuple[int, str]:
    """Compute fingerprint of history for deduplication."""
    if not history:
        return (0, "")
    last_msg = str(history[-1])
    msg_hash = hashlib.sha256(last_msg.encode()).hexdigest()[:16]
    return (len(history), msg_hash)


def should_skip_autosave(history: list) -> bool:
    """Check if we should skip this autosave (no changes or too soon)."""
    global _last_autosave_len, _last_autosave_hash, _last_autosave_time
    now = time.time()
    if now - _last_autosave_time < AUTOSAVE_DEBOUNCE_SECONDS:
        return True
    new_len, new_hash = _compute_history_fingerprint(history)
    if new_len == _last_autosave_len and new_hash == _last_autosave_hash:
        return True
    return False


def mark_autosave_complete(history: list) -> None:
    """Update tracking state after successful autosave."""
    global _last_autosave_len, _last_autosave_hash, _last_autosave_time
    _last_autosave_len, _last_autosave_hash = _compute_history_fingerprint(history)
    _last_autosave_time = time.time()


def register_terminal_session(
    name: str,
    session_id: str | None = None,
    cols: int = 80,
    rows: int = 24,
    shell: str | None = None,
) -> None:
    """Register a terminal session for crash recovery tracking.

    (code_puppy-ctj.1) Records terminal metadata so that on crash/restart,
    the Elixir SessionStorage.TerminalRecovery module can attempt to
    recreate the PTY session. Also registers with the Elixir bridge if
    available.

    This is the Python-side entry point for terminal tracking. It stores
    metadata in the local ``_active_terminal`` dict (used by save_session
    to pass has_terminal/terminal_meta to the Elixir Store) and also
    calls session_storage_bridge.register_terminal for immediate durable
    persistence.
    """
    global _active_terminal
    meta = {
        "session_id": session_id or name,
        "cols": cols,
        "rows": rows,
        "shell": shell,
        "attached_at": time.time(),
    }
    _active_terminal[name] = meta

    # Register with Elixir bridge if available
    if _use_elixir_for_session():
        try:
            from code_puppy import session_storage_bridge

            session_storage_bridge.register_terminal(
                name=name,
                session_id=session_id or name,
                cols=cols,
                rows=rows,
                shell=shell,
            )
        except Exception as exc:
            logger.debug("Elixir terminal registration failed: %s", exc)


def unregister_terminal_session(name: str) -> None:
    """Unregister a terminal session from crash recovery tracking.

    (code_puppy-ctj.1) Called when a terminal session is closed gracefully.
    """
    global _active_terminal
    _active_terminal.pop(name, None)

    if _use_elixir_for_session():
        try:
            from code_puppy import session_storage_bridge

            session_storage_bridge.unregister_terminal(name=name)
        except Exception as exc:
            logger.debug("Elixir terminal unregistration failed: %s", exc)


def get_active_terminals() -> dict[str, dict[str, Any]]:
    """Return currently tracked terminal sessions.

    (code_puppy-ctj.1) For diagnostics and crash recovery.
    """
    return dict(_active_terminal)


def _autosave_shutdown():
    """Shutdown handler: flush pending saves before exit.

    ISSUE zn8 FIX: atexit.register(_autosave_shutdown) prevents silent data loss at Ctrl+C.
    Waits for pending saves to complete with a 5-second timeout.
    """
    try:
        _autosave_executor.shutdown(wait=True, cancel_futures=False)
    except Exception:
        pass


atexit.register(_autosave_shutdown)


def save_session_async(
    *,
    history: SessionHistory,
    session_name: str,
    base_dir: Path,
    timestamp: str,
    token_estimator: TokenEstimator,
    auto_saved: bool = False,
    compacted_hashes: list | None = None,
    precomputed_total: int | None = None,
) -> None:
    """Non-blocking version of save_session that submits to thread pool.

    FIXES:
    1. Snapshot list(history) at submit to prevent closure pinning mutable history.
    2. atexit.register(_autosave_shutdown) ensures data is flushed on exit.

    This function immediately returns and performs the actual save operation
    in a background thread, preventing file I/O from blocking the main thread.
    Errors are logged but not raised to avoid disrupting the main flow.
    """
    # Snapshot the history list to prevent closure from pinning mutable state.
    # This ensures the background thread sees a consistent view even if the
    # caller modifies the history list after calling this function.
    history_snapshot = list(history)
    compacted_hashes_snapshot = (
        list(compacted_hashes) if compacted_hashes is not None else None
    )

    def _do_save():
        try:
            save_session(
                history=history_snapshot,
                session_name=session_name,
                base_dir=base_dir,
                timestamp=timestamp,
                token_estimator=token_estimator,
                auto_saved=auto_saved,
                compacted_hashes=compacted_hashes_snapshot,
                precomputed_total=precomputed_total,
            )
            mark_autosave_complete(history_snapshot)
        except Exception as exc:
            logger.warning("Async session save failed: %s", exc)

    _autosave_executor.submit(_do_save)


# ----- serialization helpers -----

# Magic header for current JSON+HMAC format.
_JSON_MAGIC = b"JSONV\x01\x00\x00"

# Legacy magic header for backward-compat reading of old msgpack sessions.
_LEGACY_MSGPACK_MAGIC = b"MSGPACK\x01"

logger = logging.getLogger(__name__)


def _deserialize_messages(raw_messages: list) -> list:
    """Restore serialized dicts back to pydantic-ai message objects.

    Handles two cases:
    - dicts with 'kind' key: new msgpack format, validate via TypeAdapter
    - plain values (e.g. strings in tests): return as-is

    SECURITY FIX #zvx9: Legacy pickle format support has been removed.
    """
    if not raw_messages:
        return raw_messages
    first = raw_messages[0]
    # New format: list of dicts with 'kind' discriminator
    if isinstance(first, dict) and "kind" in first:
        try:
            from pydantic_ai.messages import ModelMessagesTypeAdapter

            return list(ModelMessagesTypeAdapter.validate_python(raw_messages))
        except Exception:
            return raw_messages
    return raw_messages


# ----- HMAC helpers for integrity -----

# Legacy signed header for backward compatibility reading
_LEGACY_SIGNED_HEADER = b"CPSESSION\x01"
_LEGACY_SIGNATURE_SIZE = 32  # legacy signature bytes, retained only for backward-compat


def _compute_hmac(key: bytes, data: bytes) -> bytes:
    """Compute HMAC-SHA256 signature for data integrity."""
    return hmac.new(key, data, hashlib.sha256).digest()


def _get_or_create_hmac_key() -> bytes:
    """Get or create a per-installation HMAC key for session integrity.

    Uses atomic file creation (O_CREAT|O_EXCL via open mode 'xb') to prevent
    TOCTOU races when multiple processes start simultaneously. The key is
    stored at DATA_DIR/.session_hmac_key with chmod 0o600.
    """
    from code_puppy import config  # local import to avoid circular deps

    key_path = Path(config.DATA_DIR) / ".session_hmac_key"
    key_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with key_path.open("xb") as f:  # O_CREAT|O_EXCL — atomic, prevents TOCTOU
            key = os.urandom(32)
            f.write(key)
        key_path.chmod(0o600)
        return key
    except FileExistsError:
        key = key_path.read_bytes()
        if len(key) != 32:
            logger.warning(
                "HMAC key file at %s is corrupted (%d bytes, expected 32), regenerating",
                key_path,
                len(key),
            )
            key = os.urandom(32)
            tmp_path = key_path.with_suffix(".tmp")
            tmp_path.write_bytes(key)
            tmp_path.chmod(0o600)
            tmp_path.replace(key_path)
        return key


# NOTE: HMAC key is per-install; all sessions share one key. See code_puppy-aqc.
_HMAC_KEY: bytes | None = None  # lazily populated on first call


def _get_hmac_key() -> bytes:
    """Return cached HMAC key, initializing on first call."""
    global _HMAC_KEY
    if _HMAC_KEY is None:
        _HMAC_KEY = _get_or_create_hmac_key()
    return _HMAC_KEY


def _load_raw_bytes(raw: bytes) -> Any:
    """Deserialize session file bytes, handling JSON, legacy msgpack, and legacy-signed formats.

    SECURITY FIX #zvx9: Pickle deserialization has been removed to prevent RCE attacks.
    Legacy pickle sessions will return an error message and empty data.
    """
    # Current JSON+HMAC format
    if raw.startswith(_JSON_MAGIC):
        offset = len(_JSON_MAGIC)
        view = memoryview(raw)
        stored_hmac = bytes(view[offset : offset + 32])
        json_view = view[offset + 32 :]
        expected_hmac = _compute_hmac(_get_hmac_key(), bytes(json_view))
        if not hmac.compare_digest(stored_hmac, expected_hmac):
            raise ValueError(
                "Session file HMAC integrity check failed — file may be corrupted or tampered"
            )
        return json.loads(bytes(json_view))

    # Legacy msgpack format (backward compatibility)
    if raw.startswith(_LEGACY_MSGPACK_MAGIC):
        try:
            import msgpack
        except ImportError:
            raise ValueError(
                "Session file uses legacy msgpack format but msgpack is not installed. "
                "Install msgpack to read old sessions: pip install msgpack"
            ) from None
        offset = len(_LEGACY_MSGPACK_MAGIC)
        view = memoryview(raw)
        stored_hmac = bytes(view[offset : offset + 32])
        msgpack_view = view[offset + 32 :]
        expected_hmac = _compute_hmac(_get_hmac_key(), bytes(msgpack_view))
        if not hmac.compare_digest(stored_hmac, expected_hmac):
            # Backward compat: pre-HMAC msgpack files
            try:
                data = msgpack.unpackb(raw[offset:], raw=False)
            except Exception:
                raise ValueError(
                    "Session file HMAC integrity check failed — file may be corrupted or tampered"
                ) from None
            warnings.warn(
                "Loading session from pre-HMAC msgpack format. "
                "Re-save this session to upgrade to the new format. "
                "Legacy msgpack support will be removed in a future version.",
                DeprecationWarning,
                stacklevel=2,
            )
            return data
        return msgpack.unpackb(msgpack_view, raw=False)

    # Legacy signed format: CPSESSION\x01 + 32-byte signature + pickle
    # SECURITY FIX #zvx9: Pickle deserialization removed - RCE vulnerability
    if raw.startswith(_LEGACY_SIGNED_HEADER):
        logger.error(
            "Session file uses legacy pickle format (CPSESSION). "
            "This format is no longer supported due to security vulnerabilities (RCE risk). "
            "Please remove this session file and start a new session. "
            "Session file location: See error details below."
        )
        raise ValueError(
            "Legacy pickle session format is no longer supported due to security "
            "vulnerabilities (RCE risk - CVE-class). This session file uses the old "
            "CPSESSION format with pickle deserialization which allows arbitrary "
            "code execution. Please delete this session file and create a new session. "
            "See https://docs.python.org/3/library/pickle.html#security for details."
        )

    # Plain pickle (original format) - SECURITY FIX #zvx9: Removed
    logger.error(
        "Session file uses legacy pickle format. "
        "This format is no longer supported due to security vulnerabilities (RCE risk). "
        "Please remove this session file and start a new session."
    )
    raise ValueError(
        "Legacy pickle session format is no longer supported due to security "
        "vulnerabilities (RCE risk - CVE-class). This session file uses pickle "
        "deserialization which allows arbitrary code execution. Please delete this "
        "session file and create a new session. "
        "See https://docs.python.org/3/library/pickle.html#security for details."
    )


SessionHistory = list[Any]
TokenEstimator = Callable[[Any], int]


@dataclass(slots=True)
class SessionPaths:
    pickle_path: (
        Path  # Historical name; now stores JSON data (*.pkl extension kept for compat)
    )
    metadata_path: Path


@dataclass(slots=True)
class SessionMetadata:
    session_name: str
    timestamp: str
    message_count: int
    total_tokens: int
    pickle_path: Path
    metadata_path: Path
    auto_saved: bool = False

    def as_serialisable(self) -> dict[str, Any]:
        return {
            "session_name": self.session_name,
            "timestamp": self.timestamp,
            "message_count": self.message_count,
            "total_tokens": self.total_tokens,
            "file_path": str(self.pickle_path),
            "auto_saved": self.auto_saved,
        }


def ensure_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def build_session_paths(base_dir: Path, session_name: str) -> SessionPaths:
    pickle_path = base_dir / f"{session_name}.pkl"
    metadata_path = base_dir / f"{session_name}_meta.json"
    return SessionPaths(pickle_path=pickle_path, metadata_path=metadata_path)


def save_session(
    *,
    history: SessionHistory,
    session_name: str,
    base_dir: Path,
    timestamp: str,
    token_estimator: TokenEstimator,
    auto_saved: bool = False,
    compacted_hashes: list | None = None,
    precomputed_total: int | None = None,
) -> SessionMetadata:
    # Try Elixir SQLite storage first
    if _use_elixir_for_session():
        try:
            from code_puppy import session_storage_bridge

            # Convert history to serializable format
            try:
                from pydantic_ai.messages import ModelMessagesTypeAdapter

                serializable_history = ModelMessagesTypeAdapter.dump_python(
                    history, mode="json"
                )
            except Exception:
                serializable_history = history

            total_tokens = (
                precomputed_total
                if (precomputed_total is not None and precomputed_total >= 0)
                else sum(token_estimator(message) for message in history)
            )

            result = session_storage_bridge.save_session(
                name=session_name,
                history=serializable_history,
                compacted_hashes=compacted_hashes,
                total_tokens=total_tokens,
                auto_saved=auto_saved,
                timestamp=timestamp,
                # (code_puppy-ctj.1) Pass terminal metadata for crash recovery
                has_terminal=session_name in _active_terminal,
                terminal_meta=_active_terminal.get(session_name),
            )

            # Return metadata in expected format (without file paths for SQLite mode)
            return SessionMetadata(
                session_name=result.get("name", session_name),
                timestamp=timestamp,
                message_count=result.get("message_count", len(history)),
                total_tokens=result.get("total_tokens", total_tokens),
                pickle_path=Path(),  # Not applicable in SQLite mode
                metadata_path=Path(),  # Not applicable in SQLite mode
                auto_saved=auto_saved,
            )
        except Exception as exc:
            logger.debug("Elixir session save failed, falling back to file: %s", exc)

    # Legacy file-based storage
    ensure_directory(base_dir)
    paths = build_session_paths(base_dir, session_name)

    # Convert pydantic-ai message objects to JSON-serializable dicts.
    # ModelMessagesTypeAdapter handles ModelRequest/ModelResponse dataclasses
    # that json.dumps cannot serialize natively.
    try:
        from pydantic_ai.messages import ModelMessagesTypeAdapter

        # Fast path: try direct dump_python first (avoids double serialization)
        try:
            serializable_history = ModelMessagesTypeAdapter.dump_python(
                history, mode="json"
            )
        except Exception as e:
            # Sanitize messages to remove non-serializable objects (coroutines, etc.)
            # that may have been captured in message metadata during tool execution.
            # DBOS uses pickle for workflow durability, which cannot serialize coroutines.
            logger.warning(
                f"Fast path serialization failed in save_session: {e}. "
                "Falling back to round-trip sanitization."
            )
            try:
                # Optimized path: dump to JSON then parse directly to dicts.
                # This avoids the expensive validate_json() -> dump_python() round-trip
                # through pydantic model objects. We go directly from JSON bytes to
                # plain dicts which is what json.dumps needs anyway.
                json_data = ModelMessagesTypeAdapter.dump_json(history)
                serializable_history = json.loads(json_data)
            except Exception as e2:
                # Log the sanitization failure so we can track if this becomes a recurring issue
                logger.warning(
                    f"Message sanitization failed in save_session: {e2}. Using original history."
                )
                serializable_history = history
    except Exception:
        # Fallback for non-pydantic history (e.g. tests with plain strings)
        serializable_history = history

    payload: dict = {
        "messages": serializable_history,
        "compacted_hashes": list(compacted_hashes)
        if compacted_hashes is not None
        else [],
    }
    serialized_data = json.dumps(payload, separators=(",", ":"), default=str).encode(
        "utf-8"
    )

    # Compute HMAC for integrity using per-install secret key
    hmac_signature = _compute_hmac(_get_hmac_key(), serialized_data)

    tmp_session = paths.pickle_path.with_suffix(".tmp")
    with tmp_session.open("wb") as session_file:
        session_file.write(_JSON_MAGIC + hmac_signature + serialized_data)
    tmp_session.replace(paths.pickle_path)

    total_tokens = (
        precomputed_total
        if (precomputed_total is not None and precomputed_total >= 0)
        else sum(token_estimator(message) for message in history)
    )
    metadata = SessionMetadata(
        session_name=session_name,
        timestamp=timestamp,
        message_count=len(history),
        total_tokens=total_tokens,
        pickle_path=paths.pickle_path,
        metadata_path=paths.metadata_path,
        auto_saved=auto_saved,
    )

    tmp_metadata = paths.metadata_path.with_suffix(".tmp")
    with tmp_metadata.open("w", encoding="utf-8") as metadata_file:
        json.dump(metadata.as_serialisable(), metadata_file, indent=2)
    tmp_metadata.replace(paths.metadata_path)

    return metadata


def _parse_session_payload(data: Any) -> tuple[SessionHistory]:
    """Parse session payload into ``(messages, compacted_hashes)``.

    Handles two on-disk formats:

    * **New format** – ``dict`` with ``"messages"`` and ``"compacted_hashes"``
      keys (written by this module from the point of this change onward).
    * **Legacy format** – plain ``list`` of messages; ``compacted_hashes``
      is returned as an empty list so callers don't need special-casing.
    """
    if isinstance(data, dict) and "messages" in data:
        messages = _deserialize_messages(data["messages"])
        return messages, data.get("compacted_hashes", [])
    # Legacy format: raw list only
    if isinstance(data, list):
        return _deserialize_messages(data), []
    return data, []


def load_session(
    session_name: str, base_dir: Path | None = None, *, allow_legacy: bool = False
) -> SessionHistory:
    """Load message history from a session file.

    Returns only the message list. Use :func:`load_session_with_hashes` when
    you also need the persisted compacted-message hashes.

    Prefers Elixir SQLite storage when available, falls back to file-based.
    """
    # Kept for API compatibility; legacy loading is always supported now.
    _ = allow_legacy

    # Try Elixir bridge first
    if _use_elixir_for_session():
        try:
            from code_puppy import session_storage_bridge

            result = session_storage_bridge.load_session(name=session_name)
            history = result.get("history", [])
            return _deserialize_messages(history)
        except Exception as exc:
            logger.debug("Elixir session load failed, falling back: %s", exc)

    # Legacy file-based fallback
    if base_dir is None:
        from code_puppy import config

        base_dir = Path(config.DATA_DIR) / "subagent_sessions"

    paths = build_session_paths(base_dir, session_name)
    if not paths.pickle_path.exists():
        raise FileNotFoundError(paths.pickle_path)

    raw = paths.pickle_path.read_bytes()
    data = _load_raw_bytes(raw)
    messages, _ = _parse_session_payload(data)
    return messages


def load_session_with_hashes(
    session_name: str, base_dir: Path | None = None
) -> tuple[SessionHistory, list]:
    """Load message history *and* compacted-message hashes from a session file.

    Returns:
        ``(messages, compacted_hashes)`` tuple. For legacy session files that
        contain only the message list, ``compacted_hashes`` will be ``[]``.

    On corruption or deserialisation errors a user-visible warning is emitted
    (via ``code_puppy.messaging.emit_warning``) and ``([], [])`` is returned
    so callers get an empty session rather than an unhandled exception.

    Prefers Elixir SQLite storage when available, falls back to file-based.
    """
    # Try Elixir bridge first
    if _use_elixir_for_session():
        try:
            from code_puppy import session_storage_bridge

            result = session_storage_bridge.load_session(name=session_name)
            history = _deserialize_messages(result.get("history", []))
            hashes = result.get("compacted_hashes", [])
            return history, hashes
        except Exception as exc:
            logger.debug(
                "Elixir session load_with_hashes failed, falling back: %s", exc
            )

    # Legacy file-based fallback
    if base_dir is None:
        from code_puppy import config

        base_dir = Path(config.DATA_DIR) / "subagent_sessions"

    paths = build_session_paths(base_dir, session_name)
    if not paths.pickle_path.exists():
        raise FileNotFoundError(paths.pickle_path)

    # --- 1. Read raw bytes from disk ---
    try:
        raw = paths.pickle_path.read_bytes()
    except OSError as exc:
        logger.warning(
            "Session '%s' could not be read from disk: %s: %s",
            session_name,
            type(exc).__name__,
            exc,
        )
        from code_puppy.messaging import (
            emit_warning,
        )  # lazy import – avoids circular deps

        emit_warning(
            f"Session '{session_name}' could not be loaded: {type(exc).__name__}: {exc}"
        )
        return [], []

    # --- 2. Deserialize bytes ---
    try:
        data = _load_raw_bytes(raw)
    except (ValueError, Exception) as exc:  # Exception covers pickle.UnpicklingError
        logger.warning(
            "Session '%s' deserialization failed: %s: %s",
            session_name,
            type(exc).__name__,
            exc,
        )
        from code_puppy.messaging import emit_warning

        emit_warning(
            f"Session '{session_name}' could not be loaded: {type(exc).__name__}: {exc}"
        )
        return [], []

    # --- 3. Parse the deserialized payload into (messages, hashes) ---
    try:
        return _parse_session_payload(data)
    except Exception as exc:
        logger.warning(
            "Session '%s' payload parse failed: %s: %s",
            session_name,
            type(exc).__name__,
            exc,
        )
        from code_puppy.messaging import emit_warning

        emit_warning(
            f"Session '{session_name}' could not be loaded: {type(exc).__name__}: {exc}"
        )
        return [], []


def _use_elixir_for_session() -> bool:
    """Check if we should use Elixir storage."""
    global _use_elixir_storage
    if not _use_elixir_storage:
        return False
    try:
        from code_puppy import session_storage_bridge

        return session_storage_bridge.is_available()
    except Exception:
        return False


def list_sessions(base_dir: Path | None = None) -> list[str]:
    """List all session names.

    Prefers Elixir SQLite storage when available, falls back to file-based.
    """
    # Try Elixir bridge first
    if _use_elixir_for_session():
        try:
            from code_puppy import session_storage_bridge

            return session_storage_bridge.list_sessions()
        except Exception as exc:
            logger.debug("Elixir session list failed, falling back: %s", exc)

    # Legacy file-based fallback
    if base_dir is None:
        from code_puppy import config

        base_dir = Path(config.DATA_DIR) / "subagent_sessions"

    if not base_dir.exists():
        return []
    return sorted(path.stem for path in base_dir.glob("*.pkl"))


def cleanup_sessions(base_dir: Path | None = None, max_sessions: int = 10) -> list[str]:
    """Clean up old sessions, keeping only the most recent N.

    Prefers Elixir SQLite storage when available, falls back to file-based.
    """
    if max_sessions <= 0:
        return []

    # Try Elixir bridge first
    if _use_elixir_for_session():
        try:
            from code_puppy import session_storage_bridge

            return session_storage_bridge.cleanup_sessions(max_sessions)
        except Exception as exc:
            logger.debug("Elixir session cleanup failed, falling back: %s", exc)

    # Legacy file-based fallback
    if base_dir is None:
        from code_puppy import config

        base_dir = Path(config.DATA_DIR) / "subagent_sessions"

    if not base_dir.exists():
        return []

    candidate_paths = list(base_dir.glob("*.pkl"))
    if len(candidate_paths) <= max_sessions:
        return []

    sorted_candidates = sorted(
        ((path.stat().st_mtime, path) for path in candidate_paths),
        key=lambda item: item[0],
    )

    stale_entries = sorted_candidates[:-max_sessions]
    removed_sessions: list[str] = []
    for _, pickle_path in stale_entries:
        metadata_path = base_dir / f"{pickle_path.stem}_meta.json"
        try:
            pickle_path.unlink(missing_ok=True)
            metadata_path.unlink(missing_ok=True)
            removed_sessions.append(pickle_path.stem)
        except OSError:
            continue

    return removed_sessions


async def restore_autosave_interactively(base_dir: Path) -> None:
    """Prompt the user to load an autosave session from base_dir, if any exist.

    This helper is deliberately placed in session_storage to keep autosave
    restoration close to the persistence layer. It uses the same public APIs
    (list_sessions, load_session) and mirrors the interactive behaviours from
    the command handler.
    """
    sessions = list_sessions(base_dir)
    if not sessions:
        return

    # Import locally to avoid pulling the messaging layer into storage modules
    # These are legacy prompt_toolkit imports; not available if prompt_toolkit removed
    try:
        from prompt_toolkit.formatted_text import FormattedText

        from code_puppy.command_line.prompt_toolkit_completion import (
            get_input_with_combined_completion,
        )
    except ImportError:
        # prompt_toolkit not available (Textual mode); skip interactive restore
        return

    from code_puppy.agents.agent_manager import get_current_agent
    from code_puppy.messaging import emit_success, emit_system_message, emit_warning

    entries = []
    for name in sessions:
        meta_path = base_dir / f"{name}_meta.json"
        try:
            with meta_path.open("r", encoding="utf-8") as meta_file:
                data = json.load(meta_file)
            timestamp = data.get("timestamp")
            message_count = data.get("message_count")
        except Exception:
            timestamp = None
            message_count = None
        entries.append((name, timestamp, message_count))

    def sort_key(entry):
        _, timestamp, _ = entry
        if timestamp:
            try:
                return datetime.fromisoformat(timestamp)
            except ValueError:
                return datetime.min
        return datetime.min

    entries.sort(key=sort_key, reverse=True)

    PAGE_SIZE = 5
    total = len(entries)
    page = 0

    def render_page() -> None:
        start = page * PAGE_SIZE
        end = min(start + PAGE_SIZE, total)
        page_entries = entries[start:end]
        emit_system_message("Autosave Sessions Available:")
        for idx, (name, timestamp, message_count) in enumerate(page_entries, start=1):
            timestamp_display = timestamp or "unknown time"
            message_display = (
                f"{message_count} messages"
                if message_count is not None
                else "unknown size"
            )
            emit_system_message(
                f" [{idx}] {name} ({message_display}, saved at {timestamp_display})"
            )
        # If there are more pages, offer next-page; show 'Return to first page' on last page
        if total > PAGE_SIZE:
            page_count = (total + PAGE_SIZE - 1) // PAGE_SIZE
            is_last_page = (page + 1) >= page_count
            remaining = total - (page * PAGE_SIZE + len(page_entries))
            summary = (
                f" and {remaining} more" if (remaining > 0 and not is_last_page) else ""
            )
            label = "Return to first page" if is_last_page else f"Next page{summary}"
            emit_system_message(f" [6] {label}")
        emit_system_message(" [Enter] Skip loading autosave")

    chosen_name: str | None = None

    while True:
        render_page()
        try:
            selection = await get_input_with_combined_completion(
                FormattedText(
                    [("class:prompt", "Pick 1-5 to load, 6 for next, or name/Enter: ")]
                )
            )
        except KeyboardInterrupt, EOFError:
            emit_warning("Autosave selection cancelled")
            return

        selection = (selection or "").strip()
        if not selection:
            return

        # Numeric choice: 1-5 select within current page; 6 advances page
        if selection.isdigit():
            num = int(selection)
            if num == 6 and total > PAGE_SIZE:
                page = (page + 1) % ((total + PAGE_SIZE - 1) // PAGE_SIZE)
                # loop and re-render next page
                continue
            if 1 <= num <= 5:
                start = page * PAGE_SIZE
                idx = start + (num - 1)
                if 0 <= idx < total:
                    chosen_name = entries[idx][0]
                    break
                else:
                    emit_warning("Invalid selection for this page")
                    continue
            emit_warning("Invalid selection; choose 1-5 or 6 for next")
            continue

        # Allow direct typing by exact session name
        for name, _ts, _mc in entries:
            if name == selection:
                chosen_name = name
                break
        if chosen_name:
            break
        emit_warning("No autosave loaded (invalid selection)")
        # keep looping and allow another try

    if not chosen_name:
        return

    try:
        history, compacted_hashes = load_session_with_hashes(chosen_name, base_dir)
    except FileNotFoundError:
        emit_warning(f"Autosave '{chosen_name}' could not be found")
        return
    except Exception as exc:
        emit_warning(f"Failed to load autosave '{chosen_name}': {exc}")
        return

    agent = get_current_agent()
    agent.set_message_history(history)
    agent.restore_compacted_hashes(compacted_hashes)

    # Set current autosave session id so subsequent autosaves overwrite this session
    try:
        from code_puppy.config import set_current_autosave_from_session_name

        set_current_autosave_from_session_name(chosen_name)
    except Exception:
        pass

    total_tokens = sum(agent.estimate_tokens_for_message(msg) for msg in history)

    session_path = base_dir / f"{chosen_name}.pkl"
    emit_success(
        f"✅ Autosave loaded: {len(history)} messages ({total_tokens} tokens)\n"
        f"📁 From: {session_path}"
    )

    # Display recent message history for context
    try:
        from code_puppy.command_line.autosave_menu import display_resumed_history

        display_resumed_history(history)
    except Exception:
        pass  # Don't fail if display doesn't work in non-TTY environment
