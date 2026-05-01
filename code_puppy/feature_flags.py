"""Python mirror of the Elixir ADR-004 feature-flag client.

This module reads the same ``flags.json`` file as
``CodePuppyControl.FeatureFlags`` and exposes a conservative local mirror for
Python code paths. It intentionally reads the file directly rather than going
through the Elixir bridge: no feature-flag JSON-RPC method exists today, and
feature flags must degrade safely to all-disabled when Elixir is unavailable.

All capabilities default to ``False`` when the file is missing, empty,
malformed, or otherwise unusable. Unknown JSON keys are ignored so future
Elixir-only flags do not break older Python clients.

Note: warnings for malformed input (non-object root, non-bool values) are
de-duplicated per client instance to avoid log spam in long-running processes.
This is an intentional improvement over the Elixir reference, which logs every
parse. Flag state semantics still match Elixir exactly.
"""

import json
import logging
import os
import threading
from collections.abc import Mapping
from pathlib import Path
from typing import Any, Final, TypeAlias

from code_puppy.persistence import atomic_write_text

logger = logging.getLogger(__name__)

FlagState: TypeAlias = dict[str, bool]
FlagEntry: TypeAlias = tuple[str, bool, str]

CAPABILITIES: Final[dict[str, str]] = {
    "llm_client": "Route LLM client calls to Elixir",
    "base_agent": "Route agent execution to Elixir",
    "tools": "Route tool dispatch to Elixir",
    "plugins": "Load plugins via Elixir loader",
    "cli": "Route CLI/REPL to Elixir",
}

_ENV_PRECEDENCE: Final[tuple[str, ...]] = ("PUP_EX_HOME", "PUP_HOME", "PUPPY_HOME")
_ELIXIR_PREFIX: Final[str] = "elixir."


def elixir_home_dir() -> Path:
    """Mirror ``CodePuppyControl.Config.Paths.home_dir/0``.

    Precedence is ``PUP_EX_HOME`` → ``PUP_HOME`` → ``PUPPY_HOME`` →
    ``~/.code_puppy_ex``. This intentionally does **not** reuse
    ``code_puppy.config_paths.home_dir()``, which resolves the Python home in
    normal Python-pup mode.
    """
    for env_var in _ENV_PRECEDENCE:
        value = os.environ.get(env_var)
        if value is not None:
            return Path(value)
    return Path.home() / ".code_puppy_ex"


def flags_file() -> Path:
    """Return the Elixir feature-flags file path."""
    return elixir_home_dir() / "flags.json"


def resolve(capability: str) -> str:
    """Resolve a user-supplied capability to its canonical name.

    Mirrors the string-handling branch of Elixir ``Flags.resolve/1``: trim
    whitespace, lowercase, strip an optional ``elixir.`` prefix, then validate
    against the known ADR-004 capabilities.

    Raises:
        ValueError: If ``capability`` is not a known feature-flag capability.
    """
    cleaned = capability.strip().lower()
    if cleaned.startswith(_ELIXIR_PREFIX):
        cleaned = cleaned[len(_ELIXIR_PREFIX) :]
    if cleaned not in CAPABILITIES:
        raise ValueError(f"Unknown feature-flag capability: {capability!r}")
    return cleaned


def json_key(capability: str) -> str:
    """Return the canonical JSON key for ``capability``.

    Examples:
        ``json_key("cli")`` returns ``"elixir.cli"``.
    """
    return f"{_ELIXIR_PREFIX}{resolve(capability)}"


def _default_flags() -> FlagState:
    """Return a fresh all-disabled flag state."""
    return {capability: False for capability in CAPABILITIES}


def _serialize_flags(flags: Mapping[str, bool]) -> FlagState:
    """Serialize internal flag names to canonical ``elixir.`` JSON keys."""
    return {
        json_key(capability): flags.get(capability, False)
        for capability in CAPABILITIES
    }


def _ensure_not_legacy_home(path: Path) -> None:
    """Mirror ``CodePuppyControl.Config.Isolation.check_allowed/2``.

    Refuses writes under the legacy Python home (``~/.code_puppy``). That
    directory is reserved for the Python runtime; Elixir feature flags must
    live under the Elixir home.
    """
    legacy = (Path.home() / ".code_puppy").resolve()
    target = path.resolve()
    try:
        target.relative_to(legacy)
    except ValueError:
        return
    raise RuntimeError(
        f"Refusing to write feature flags under legacy Python home: {path} "
        f"(legacy home is {legacy}; set PUP_EX_HOME to a separate directory)"
    )


class FeatureFlagClient:
    """Direct-file Python mirror of the Elixir FeatureFlags GenServer.

    Args:
        path: Optional explicit path to ``flags.json``. Tests should pass a
            temporary path to avoid singleton or environment bleed. When omitted,
            the Elixir home resolver is used for each disk access.
    """

    def __init__(self, path: Path | None = None) -> None:
        self._path = path
        self._lock = threading.RLock()
        self._warned_messages: set[str] = set()
        self._flags = self._load_from_disk()

    @property
    def path(self) -> Path:
        """Return the effective flags-file path for this client."""
        if self._path is not None:
            return self._path
        return flags_file()

    def enabled(self, capability: str) -> bool:
        """Return whether ``capability`` is enabled.

        Known capabilities default to ``False``. Unknown capabilities raise
        ``ValueError``, matching Elixir's public API raising ``ArgumentError``.
        """
        resolved = resolve(capability)
        with self._lock:
            return self._flags.get(resolved, False)

    def list(self) -> list[FlagEntry]:
        """Return all capabilities as ``(name, enabled, description)`` tuples."""
        with self._lock:
            snapshot = self._flags.copy()
        return [
            (name, snapshot.get(name, False), description)
            for name, description in CAPABILITIES.items()
        ]

    def reload(self) -> None:
        """Reload flag state from disk, falling back to all-disabled on errors."""
        with self._lock:
            self._flags = self._load_from_disk()

    def reset(self) -> None:
        """Persist and cache the default all-disabled state."""
        fresh = _default_flags()
        with self._lock:
            self._persist_to_disk(fresh)
            self._flags = fresh

    def set(self, capability: str, value: bool) -> None:
        """Set ``capability`` to ``value``, persisting canonical JSON to disk.

        Raises:
            TypeError: If ``value`` is not a real ``bool``.
            ValueError: If ``capability`` is unknown.
            OSError: If the atomic write fails.
            RuntimeError: If the target path is under the legacy Python home.
        """
        if not isinstance(value, bool):
            raise TypeError(
                "Feature-flag values must be bool; "
                f"got {type(value).__name__} for {capability!r}"
            )

        resolved = resolve(capability)
        with self._lock:
            fresh = self._flags.copy()
            fresh[resolved] = value
            self._persist_to_disk(fresh)
            self._flags = fresh

    def _load_from_disk(self) -> FlagState:
        """Load flags from disk using the Elixir-compatible fallback rules."""
        path = self.path
        try:
            if not path.exists() or path.stat().st_size < 2:
                return _default_flags()
            raw = path.read_text(encoding="utf-8")
        except OSError, UnicodeError:
            return _default_flags()

        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError:
            return _default_flags()

        return self._parse_decoded(decoded)

    def _parse_decoded(self, decoded: Any) -> FlagState:
        """Merge decoded JSON into an all-disabled default state."""
        flags = _default_flags()
        if not isinstance(decoded, dict):
            self._warn_once(
                "not-object",
                "FeatureFlags: flags.json is not a JSON object. Using defaults.",
            )
            return flags

        for key, value in sorted(
            ((k, v) for k, v in decoded.items() if isinstance(k, str)),
            key=lambda item: item[0],
        ):
            try:
                resolved = resolve(key)
            except ValueError:
                continue

            if isinstance(value, bool):
                flags[resolved] = value
            else:
                self._warn_once(
                    f"non-bool:{resolved}",
                    "FeatureFlags: expected boolean for %s, got %r. Ignoring.",
                    key,
                    value,
                )

        return flags

    def _persist_to_disk(self, flags: Mapping[str, bool]) -> None:
        """Write flags atomically using the canonical Elixir JSON schema."""
        content = json.dumps(
            _serialize_flags(flags),
            indent=2,
            sort_keys=True,
        )
        path = self.path
        _ensure_not_legacy_home(path)
        atomic_write_text(path, content + "\n")

    def _warn_once(self, key: str, message: str, *args: object) -> None:
        """Emit a warning once per client and warning key."""
        if key in self._warned_messages:
            return
        self._warned_messages.add(key)
        logger.warning(message, *args)


_DEFAULT_CLIENT: FeatureFlagClient | None = None
_DEFAULT_CLIENT_PATH: Path | None = None
_DEFAULT_CLIENT_LOCK = threading.RLock()


def _get_default_client() -> FeatureFlagClient:
    """Return the module-level singleton, rebuilding it if the env path changed."""
    global _DEFAULT_CLIENT, _DEFAULT_CLIENT_PATH

    current_path = flags_file()
    with _DEFAULT_CLIENT_LOCK:
        if _DEFAULT_CLIENT is None or _DEFAULT_CLIENT_PATH != current_path:
            _DEFAULT_CLIENT = FeatureFlagClient(path=current_path)
            _DEFAULT_CLIENT_PATH = current_path
        return _DEFAULT_CLIENT


def enabled(capability: str) -> bool:
    """Return whether ``capability`` is enabled on the default client."""
    return _get_default_client().enabled(capability)


def list_flags() -> list[FlagEntry]:
    """Return all feature flags from the default client."""
    return _get_default_client().list()


def reload() -> None:
    """Reload the default client's cached flag state from disk."""
    _get_default_client().reload()


def reset() -> None:
    """Reset all known flags to ``False`` on the default client."""
    _get_default_client().reset()


def set_flag(capability: str, value: bool) -> None:
    """Set a feature flag on the default client.

    Named ``set_flag`` instead of ``set`` to avoid shadowing the built-in type.
    """
    _get_default_client().set(capability, value)


__all__ = [
    "CAPABILITIES",
    "FeatureFlagClient",
    "enabled",
    "elixir_home_dir",
    "flags_file",
    "json_key",
    "list_flags",
    "reload",
    "reset",
    "resolve",
    "set_flag",
]
