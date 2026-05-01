"""Python mirror of the Elixir ADR-004 feature-flag client.

This module reads the same ``flags.json`` file as
``CodePuppyControl.FeatureFlags`` and exposes a conservative local mirror for
Python code paths. It intentionally reads the file directly rather than going
through the Elixir bridge: no feature-flag JSON-RPC method exists today, and
feature flags must degrade safely to all-disabled when Elixir is unavailable.

All capabilities default to ``False`` (0%) when the file is missing, empty,
malformed, or otherwise unusable. Unknown JSON keys are ignored so future
Elixir-only flags do not break older Python clients.

Note: warnings for malformed input (non-object root, non-boolean, non-integer
values) are de-duplicated per client instance to avoid log spam in long-running
processes. This is an intentional improvement over the Elixir reference, which
logs every parse. Flag state semantics still match Elixir exactly.
"""

from __future__ import annotations

import json
import logging
import os
import random
import threading
from collections.abc import Mapping
from pathlib import Path
from typing import Any, Final, TypeAlias

from code_puppy.persistence import atomic_write_text

logger = logging.getLogger(__name__)

# Internal: 0..100 percentage per capability.
FlagState: TypeAlias = dict[str, int]
FlagEntry: TypeAlias = tuple[str, int, str]
SerializedFlags: TypeAlias = dict[str, bool | int]

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
    """Return a fresh all-disabled (0%) flag state."""
    return {capability: 0 for capability in CAPABILITIES}


def _serialize_flags(flags: Mapping[str, int]) -> SerializedFlags:
    """Serialize internal flag percentages to canonical ``elixir.`` JSON keys.

    0 → ``false``, 100 → ``true``, 1..99 → integer (gradual rollout).
    """
    result: SerializedFlags = {}
    for capability in CAPABILITIES:
        pct = flags.get(capability, 0)
        key = json_key(capability)
        if pct == 0:
            result[key] = False
        elif pct == 100:
            result[key] = True
        else:
            result[key] = pct
    return result


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

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def enabled(self, capability: str) -> bool:
        """Return whether ``capability`` is probabilistically enabled.

        The check is based on the stored percentage (0..100):

        - 0 → always ``False``
        - 100 → always ``True``
        - 1..99 → ``random.randint(1, 100) <= percentage``

        Unknown capabilities raise ``ValueError``, matching Elixir's public API
        raising ``ArgumentError``.
        """
        pct = self.percentage(capability)
        if pct <= 0:
            return False
        if pct >= 100:
            return True
        return random.randint(1, 100) <= pct

    def is_enabled(self, capability: str) -> bool:
        """Backward-compatible alias for :meth:`enabled`."""
        return self.enabled(capability)

    def percentage(self, capability: str) -> int:
        """Return the rollout percentage (0..100) for ``capability``.

        ``0`` means fully disabled. ``100`` means fully enabled. Values in
        between represent gradual rollout.
        """
        resolved = resolve(capability)
        with self._lock:
            return self._flags.get(resolved, 0)

    def list(self) -> list[FlagEntry]:
        """Return all capabilities as ``(name, percentage, description)`` tuples."""
        with self._lock:
            snapshot = self._flags.copy()
        return [
            (name, snapshot.get(name, 0), description)
            for name, description in CAPABILITIES.items()
        ]

    def reload(self) -> None:
        """Reload flag state from disk, falling back to all-disabled on errors."""
        with self._lock:
            self._flags = self._load_from_disk()

    def reset(self) -> None:
        """Persist and cache the default all-disabled (0%) state."""
        fresh = _default_flags()
        with self._lock:
            self._persist_to_disk(fresh)
            self._flags = fresh

    def set(self, capability: str, value: bool | int) -> None:
        """Set ``capability`` to ``value``, persisting canonical JSON to disk.

        ``True`` → 100%, ``False`` → 0%. An integer 0..100 sets the rollout
        percentage directly.

        Raises:
            TypeError: If ``value`` is neither ``bool`` nor ``int``.
            ValueError: If ``value`` is an ``int`` outside 0..100, or if
                ``capability`` is unknown.
            OSError: If the atomic write fails.
            RuntimeError: If the target path is under the legacy Python home.
        """
        pct = _to_percentage(value, capability)

        resolved = resolve(capability)
        with self._lock:
            fresh = self._flags.copy()
            fresh[resolved] = pct
            self._persist_to_disk(fresh)
            self._flags = fresh

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _load_from_disk(self) -> FlagState:
        """Load flags from disk using the Elixir-compatible fallback rules."""
        path = self.path
        try:
            if not path.exists() or path.stat().st_size < 2:
                return _default_flags()
            raw = path.read_text(encoding="utf-8")
        except OSError:
            return _default_flags()
        except UnicodeError:
            return _default_flags()

        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError:
            return _default_flags()

        return self._parse_decoded(decoded)

    def _parse_decoded(self, decoded: Any) -> FlagState:
        """Merge decoded JSON into an all-disabled (0%) default state.

        Accepts ``bool`` (``True`` → 100, ``False`` → 0) and ``int`` (0..100).
        """
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
                flags[resolved] = 100 if value else 0
            elif isinstance(value, int) and 0 <= value <= 100:
                flags[resolved] = value
            else:
                self._warn_once(
                    f"non-flag-value:{resolved}",
                    "FeatureFlags: expected boolean or integer 0..100 for %s, "
                    "got %r. Ignoring.",
                    key,
                    value,
                )

        return flags

    def _persist_to_disk(self, flags: Mapping[str, int]) -> None:
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


# ---------------------------------------------------------------------------
# Module-level helpers
# ---------------------------------------------------------------------------


def _to_percentage(value: bool | int, capability: str) -> int:
    """Convert a user-supplied value to an internal percentage (0..100).

    ``True`` → 100, ``False`` → 0.  ``int`` 0..100 passes through.
    """
    if isinstance(value, bool):
        return 100 if value else 0
    if isinstance(value, int):
        if not 0 <= value <= 100:
            raise ValueError(
                f"Feature-flag percentage must be 0..100; "
                f"got {value} for {capability!r}"
            )
        return value
    raise TypeError(
        "Feature-flag values must be bool or int 0..100; "
        f"got {type(value).__name__} for {capability!r}"
    )


# ---------------------------------------------------------------------------
# Singleton / module-level convenience API
# ---------------------------------------------------------------------------

_DEFAULT_CLIENT: FeatureFlagClient | None = None
_DEFAULT_CLIENT_PATH: Path | None = None
_DEFAULT_CLIENT_LOCK = threading.RLock()


def _get_default_client() -> FeatureFlagClient:
    """Return the module-level singleton, rebuilding it if the env path changed."""
    global _DEFAULT_CLIENT, _DEFAULT_CLIENT_PATH  # noqa: PLW0603

    current_path = flags_file()
    with _DEFAULT_CLIENT_LOCK:
        if _DEFAULT_CLIENT is None or _DEFAULT_CLIENT_PATH != current_path:
            _DEFAULT_CLIENT = FeatureFlagClient(path=current_path)
            _DEFAULT_CLIENT_PATH = current_path
        return _DEFAULT_CLIENT


def enabled(capability: str) -> bool:
    """Return whether ``capability`` is probabilistically enabled on the default client."""
    return _get_default_client().enabled(capability)


def list_flags() -> list[FlagEntry]:
    """Return all feature flags from the default client."""
    return _get_default_client().list()


def reload() -> None:
    """Reload the default client's cached flag state from disk."""
    _get_default_client().reload()


def reset() -> None:
    """Reset all known flags to 0% on the default client."""
    _get_default_client().reset()


def set_flag(capability: str, value: bool | int) -> None:
    """Set a feature flag on the default client.

    Named ``set_flag`` instead of ``set`` to avoid shadowing the built-in type.
    Accepts ``bool`` or ``int`` 0..100.
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
