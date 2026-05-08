"""Dual-home config isolation guard for code_puppy.

Per ADR-003, when the Python process runs as part of pup-ex (the Elixir
runtime), all writes MUST go to ``~/.code_puppy_ex/`` (or whatever
``PUP_EX_HOME`` points to) and NEVER to ``~/.code_puppy/``.  This module
provides:

* Runtime detection of pup-ex mode via the ``PUP_EX_HOME`` env var.
* Path-resolution helpers that respect the active home.
* Guard-wrapped file-mutation helpers that raise
  :class:`ConfigIsolationViolation` on any attempt to write outside the
  current home.
* A test sandbox (``with_sandbox``) for tests that legitimately need to
  write to arbitrary paths.

Design choices
--------------
* **No config flag to disable.**  The guard is always active.
* **Canonical path resolution** — paths are resolved through
  ``os.path.realpath`` to block symlink attacks.
* **Thread-local sandbox** — the sandbox uses ``threading.local()`` so
  it cannot leak between threads.
"""

from __future__ import annotations

import logging
import os
import shutil
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Generator

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Exception
# ---------------------------------------------------------------------------


class ConfigIsolationViolation(RuntimeError):
    """Raised when a write targets a path outside the active home directory.

    Attributes:
        path: The resolved path that was rejected.
        action: The action being attempted (e.g. ``"write"``, ``"mkdir"``).
    """

    def __init__(self, path: str | Path, action: str) -> None:
        self.path = str(path)
        self.action = action
        super().__init__(
            f"Config isolation violation: {action} to {path} is outside the "
            f"active home directory. If running as pup-ex, writes must go "
            f"to {home_dir()} (set via PUP_EX_HOME)."
        )


# ---------------------------------------------------------------------------
# Thread-local sandbox storage
# ---------------------------------------------------------------------------

_local = threading.local()

# Sentinel value for allow-all mode
_ALLOW_ALL_SENTINEL = object()


def _sandbox_paths() -> set[str] | object | None:
    """Return the current thread's sandbox whitelist, or None.

    Returns ``_ALLOW_ALL_SENTINEL`` if in allow-all mode.
    """
    return getattr(_local, "isolation_sandbox", None)


# ---------------------------------------------------------------------------
# pup-ex detection
# ---------------------------------------------------------------------------

_PUP_EX_HOME_ENV = "PUP_EX_HOME"
_PUP_RUNTIME_ENV = "PUP_RUNTIME"
_LEGACY_HOME_NAME = ".code_puppy"
_EX_HOME_NAME = ".code_puppy_ex"


def is_pup_ex() -> bool:
    """Return True if this process is running as the Elixir pup-ex runtime.

    Detection heuristics (in priority order):

    1. ``PUP_EX_HOME`` env var is set → True (pup-ex is always explicit).
    2. ``PUP_RUNTIME=elixir`` → True.
    3. Otherwise → False (standard Python pup).
    """
    if os.environ.get(_PUP_EX_HOME_ENV):
        return True
    if os.environ.get(_PUP_RUNTIME_ENV, "").lower() == "elixir":
        return True
    return False


# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------


def home_dir() -> Path:
    """Return the active home directory.

    When running as pup-ex this is ``$PUP_EX_HOME`` (falling back to
    ``~/.code_puppy_ex/``).  When running as standard Python pup this is
    ``~/.code_puppy/``.
    """
    if is_pup_ex():
        explicit = os.environ.get(_PUP_EX_HOME_ENV)
        if explicit:
            return Path(explicit).expanduser().resolve()
        return Path.home() / _EX_HOME_NAME
    # Standard Python pup — respect PUP_HOME / PUPPY_HOME if set
    for env_var in ("PUP_HOME", "PUPPY_HOME"):
        val = os.environ.get(env_var)
        if val:
            return Path(val).expanduser().resolve()
    return Path.home() / _LEGACY_HOME_NAME


def legacy_home_dir() -> Path:
    """Return the legacy ``~/.code_puppy/`` path.

    This is **read-only** — only the import task may use it for copying
    files.  Any write targeting this path when running as pup-ex will
    raise :class:`ConfigIsolationViolation`.

    .. deprecated::
        Prefer :func:`python_home_dir` which honours ``PUP_HOME`` /
        ``PUPPY_HOME`` precedence.  This function always returns the
        hardcoded ``~/.code_puppy/`` path regardless of environment
        variables.
    """
    return Path.home() / _LEGACY_HOME_NAME


def python_home_dir() -> Path:
    """Return the Python pup's home directory for **read-only** source
    resolution.

    Precedence (per ADR-003 / MIGRATION.md):

    1. ``PUP_HOME`` — if set, always wins.
    2. ``PUPPY_HOME`` — legacy fallback.
    3. ``~/.code_puppy/`` — built-in default.

    Unlike :func:`home_dir`, this function **never** consults
    ``PUP_EX_HOME`` or :func:`is_pup_ex`.  It is intended exclusively
    for source-path resolution during migration (``/migrate``), where
    the source is always the Python pup home.
    """
    for env_var in ("PUP_HOME", "PUPPY_HOME"):
        val = os.environ.get(env_var)
        if val:
            return Path(val).expanduser().resolve()
    return Path.home() / _LEGACY_HOME_NAME


def _xdg_or_home(xdg_env: str, subpath: str) -> Path:
    """Resolve a directory, respecting XDG vars *relative to the active home*.

    When an XDG env var is explicitly set, it takes precedence — **unless**
    we are in pup-ex mode and the XDG path escapes the active home tree
    (per ADR-003).  In that case the XDG var is ignored and the path is
    computed under the active home instead.

    Otherwise the path is computed under the active home directory.
    """
    xdg_base = os.environ.get(xdg_env)
    if xdg_base:
        candidate = Path(xdg_base) / "code_puppy"
        # ADR-003: In pup-ex mode, XDG-derived paths must remain under
        # the active home tree.  If the XDG var points outside, ignore it.
        if is_pup_ex() and not _is_path_within_home(candidate):
            logger.debug(
                "XDG %s=%s escapes active home in pup-ex mode; ignoring",
                xdg_env,
                xdg_base,
            )
            return home_dir() / subpath
        return candidate
    return home_dir() / subpath


def config_dir() -> Path:
    """Return the config directory (XDG_CONFIG_HOME or active-home/config)."""
    return _xdg_or_home("XDG_CONFIG_HOME", "config")


def data_dir() -> Path:
    """Return the data directory (XDG_DATA_HOME or active-home/data)."""
    return _xdg_or_home("XDG_DATA_HOME", "data")


def cache_dir() -> Path:
    """Return the cache directory (XDG_CACHE_HOME or active-home/cache)."""
    return _xdg_or_home("XDG_CACHE_HOME", "cache")


def state_dir() -> Path:
    """Return the state directory (XDG_STATE_HOME or active-home/state)."""
    return _xdg_or_home("XDG_STATE_HOME", "state")


def resolve_path(*subpath_parts: str) -> Path:
    """Resolve a path under the active home directory.

    This is the **canonical way** to construct paths that respect isolation.
    Instead of writing ``Path.home() / ".code_puppy" / "memory"``, write
    ``resolve_path("memory")`` — it will resolve to the correct home
    regardless of whether the process is running as pup or pup-ex.

    Args:
        *subpath_parts: Path components under the active home.
            e.g. ``resolve_path("memory")`` → ``<home_dir()> / "memory"``
            e.g. ``resolve_path("plugins", "uc")`` → ``<home_dir()> / "plugins" / "uc"``

    Returns:
        Resolved Path under the active home directory.
    """
    base = home_dir()
    for part in subpath_parts:
        base = base / part
    return base


# ---------------------------------------------------------------------------
# Guard helpers
# ---------------------------------------------------------------------------


def _canonical(path: str | Path) -> str:
    """Resolve a path to its canonical (real, no-symlink) absolute form.

    Expands ``~`` and environment variables (``$HOME``, ``${XDG_…}``)
    **before** calling ``realpath`` so that guard checks cannot be
    bypassed by paths that contain unexpanded user/env references.
    """
    expanded = os.path.expanduser(os.path.expandvars(str(path)))
    return os.path.realpath(expanded)


def _is_path_within_home(path: str | Path) -> bool:
    """Return True if *path* resolves within the active home directory.

    Uses canonical resolution (``realpath``) so that symlink-based bypass
    attacks are caught.
    """
    canonical_path = _canonical(path)
    canonical_home = _canonical(home_dir())
    # Check that the path starts with the home prefix
    if canonical_path == canonical_home:
        return True
    return canonical_path.startswith(canonical_home + os.sep)


def assert_write_allowed(path: str | Path, action: str = "write") -> None:
    """Raise :class:`ConfigIsolationViolation` if *path* is outside the home.

    This is the central guard check.  Every file-mutation path in the
    codebase should call this before writing.

    The check is skipped when:
    * A thread-local sandbox is in **allow-all** mode.
    * The path is in the thread-local sandbox whitelist.
    * The process is running as standard Python pup (not pup-ex), AND
      the target path is within ``~/.code_puppy/``.

    Raises:
        ConfigIsolationViolation: If the write would violate isolation.
    """
    # Sandbox escape hatches — for tests only
    sandbox = _sandbox_paths()
    if sandbox is _ALLOW_ALL_SENTINEL:
        return
    if sandbox is not None and isinstance(sandbox, set):
        canonical_path = _canonical(path)
        for allowed in sandbox:
            if canonical_path == allowed or canonical_path.startswith(allowed + os.sep):
                return

    # If running as standard Python pup, writes to ~/.code_puppy/ are fine
    if not is_pup_ex():
        canonical_path = _canonical(path)
        canonical_legacy = _canonical(legacy_home_dir())
        if canonical_path == canonical_legacy or canonical_path.startswith(
            canonical_legacy + os.sep
        ):
            return
        # Standard pup writing outside its own home — allow but log
        logger.debug(
            "Standard pup writing outside ~/.code_puppy/: %s (%s)",
            canonical_path,
            action,
        )
        return

    # pup-ex mode: only writes within the pup-ex home are allowed
    if _is_path_within_home(path):
        return

    # Emit telemetry (per ADR-003)
    _emit_violation_telemetry(path, action)

    raise ConfigIsolationViolation(path, action)


def _emit_violation_telemetry(path: str | Path, action: str) -> None:
    """Emit a telemetry event for an isolation violation (per ADR-003).

    Uses logging as a reliable fallback — the ADR specifies
    ``:telemetry.execute`` but that is Elixir-side.  On the Python side
    we log a structured warning.  This is best-effort and never raises.
    """
    try:
        logger.warning(
            "isolation_violation path=%s action=%s pid=%s",
            _canonical(path),
            action,
            os.getpid(),
        )
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Safe file-mutation wrappers
# ---------------------------------------------------------------------------


def safe_write(path: str | Path, content: str, encoding: str = "utf-8") -> None:
    """Write *content* to *path* after validating the isolation guard.

    Raises:
        ConfigIsolationViolation: If *path* is outside the active home.
    """
    assert_write_allowed(path, "write")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding=encoding)


def safe_mkdir_p(path: str | Path) -> None:
    """Create directory tree at *path* after validating the isolation guard.

    Raises:
        ConfigIsolationViolation: If *path* is outside the active home.
    """
    assert_write_allowed(path, "mkdir")
    os.makedirs(str(path), mode=0o700, exist_ok=True)


def safe_rm(path: str | Path) -> None:
    """Remove a single file at *path* after validating the isolation guard.

    Raises:
        ConfigIsolationViolation: If *path* is outside the active home.
    """
    assert_write_allowed(path, "rm")
    Path(path).unlink(missing_ok=True)


def safe_rm_rf(path: str | Path) -> None:
    """Recursively remove *path* after validating the isolation guard.

    Raises:
        ConfigIsolationViolation: If *path* is outside the active home.
    """
    assert_write_allowed(path, "rm_rf")
    p = Path(path)
    if p.is_dir():
        shutil.rmtree(str(p))
    elif p.exists():
        p.unlink()


def safe_atomic_write(path: str | Path, content: str, encoding: str = "utf-8") -> None:
    """Write *content* to *path* atomically after validating the isolation guard.

    Uses :func:`code_puppy.persistence.atomic_write_text` under the hood
    so that the file is never in a half-written state.

    Raises:
        ConfigIsolationViolation: If *path* is outside the active home.
    """
    assert_write_allowed(path, "atomic_write")
    from code_puppy.persistence import atomic_write_text

    atomic_write_text(Path(path), content, encoding=encoding)


def safe_append(path: str | Path, content: str, encoding: str = "utf-8") -> None:
    """Append *content* to *path* after validating the isolation guard.

    Unlike :func:`safe_atomic_write`, this is a plain append (not atomic)
    because append-mode cannot be made atomic without full-file rewrite.
    The isolation guard is checked *before* opening the file.

    Raises:
        ConfigIsolationViolation: If *path* is outside the active home.
    """
    assert_write_allowed(path, "append")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding=encoding) as f:
        f.write(content)


# ---------------------------------------------------------------------------
# Test sandbox
# ---------------------------------------------------------------------------


@contextmanager
def with_sandbox(
    paths: list[str | Path] | None = None,
    allow_all: bool = False,
) -> Generator[None, None, None]:
    """Context manager that temporarily lifts the isolation guard for tests.

    Usage::

        with with_sandbox(allow_all=True):
            # Any write is allowed
            safe_write("/tmp/test_data", "hello")

        with with_sandbox(paths=["/tmp/test_dir"]):
            # Only /tmp/test_dir is allowed
            safe_write("/tmp/test_dir/file.txt", "data")

    Args:
        paths: Whitelist of canonical paths to allow writes to.
        allow_all: If True, bypass the guard entirely (use sparingly).

    Yields:
        None
    """
    prev = getattr(_local, "isolation_sandbox", None)
    try:
        if allow_all:
            _local.isolation_sandbox = _ALLOW_ALL_SENTINEL
        else:
            canonical_paths = {_canonical(p) for p in (paths or [])}
            _local.isolation_sandbox = canonical_paths
        yield
    finally:
        _local.isolation_sandbox = prev
