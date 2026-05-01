"""Runtime selector for Python-to-Elixir migration (ADR-004).

Reads ``PUP_RUNTIME`` env var to determine mode:

- ``"python"`` — force Python runtime for all capabilities
- ``"elixir"`` — force Elixir runtime for all capabilities
- ``"auto"`` — delegate to ``FeatureFlagClient`` per capability (default)

Design decisions:
- **No mutable global state** — mode is read from env var each call (env can change).
- **Thread-safe** — pure functions reading from env + FeatureFlagClient.
- **Defensive** — unknown / unrecognised capabilities return ``"python"`` (safe default).
- **Type-annotated** — proper ``Literal`` types throughout.
"""

from __future__ import annotations

import os
from typing import Final, Literal

# Valid capabilities matching FeatureFlags schema.
CAPABILITIES: Final[frozenset[str]] = frozenset(
    {"llm_client", "base_agent", "tools", "plugins", "cli"}
)

RuntimeChoice = Literal["python", "elixir"]
Mode = Literal["python", "elixir", "auto"]

_ENV_VAR: Final[str] = "PUP_RUNTIME"
_DEFAULT_MODE: Final[Mode] = "auto"
_SAFE_CAPABILITY: Final[RuntimeChoice] = "python"


def current_mode() -> Mode:
    """Return the current runtime mode from ``PUP_RUNTIME`` env var.

    Reads the environment variable on every call so that a live process can
    respond to mid-flight configuration changes without a restart.
    """
    return _parse_mode(os.environ.get(_ENV_VAR))


def select_runtime(capability: str) -> RuntimeChoice:
    """Select which runtime should handle *capability*.

    Decision table::

        +-----------+-------------+------------------------------------+
        | Mode      | Capability  | Result                             |
        +-----------+-------------+------------------------------------+
        | ``python``| any         | ``"python"``                       |
        | ``elixir``| any         | ``"elixir"``                       |
        | ``auto``  | known       | feature-flag enabled → ``"elixir"``|
        | ``auto``  | known       | feature-flag disabled → ``"python"``|
        | ``auto``  | unknown     | ``"python"`` (safe default)        |
        | any       | unknown     | ``"python"`` (safe default)        |
        +-----------+-------------+------------------------------------+

    Parameters
    ----------
    capability:
        One of the recognised ADR-004 capabilities (e.g. ``"llm_client"``).

    Returns
    -------
    ``"python"`` or ``"elixir"``.
    """
    if capability not in CAPABILITIES:
        return _SAFE_CAPABILITY

    mode = current_mode()

    if mode == "python":
        return _SAFE_CAPABILITY
    if mode == "elixir":
        return "elixir"

    # mode == "auto" — consult feature flag
    return _resolve_auto(capability)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _parse_mode(raw: str | None) -> Mode:
    """Parse ``PUP_RUNTIME`` env var value to a :data:`Mode`.

    Case-insensitive. Defaults to ``"auto"`` when the variable is unset,
    empty, or contains an unrecognised value.
    """
    if raw is None:
        return _DEFAULT_MODE

    cleaned = raw.strip().lower()

    if cleaned == "python":
        return "python"
    if cleaned == "elixir":
        return "elixir"
    if cleaned == "auto":
        return "auto"

    # Unknown value — fall back to auto so that a typo doesn't silently break.
    return _DEFAULT_MODE


def _resolve_auto(capability: str) -> RuntimeChoice:
    """Check the feature flag for *capability* and return the runtime choice.

    Gracefully degrades to ``"python"`` when:
    - The feature-flags module cannot be imported.
    - The module-level ``enabled`` helper raises.
    """
    try:
        from code_puppy.feature_flags import enabled

        is_enabled = enabled(capability)
    except Exception:  # noqa: BLE001 — broad catch for degraded fallback
        return _SAFE_CAPABILITY

    return "elixir" if is_enabled else _SAFE_CAPABILITY


__all__ = [
    "CAPABILITIES",
    "Mode",
    "RuntimeChoice",
    "current_mode",
    "select_runtime",
]
