"""Version checking utilities for Code Puppy."""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import httpx

from code_puppy.config import STATE_DIR
from code_puppy.messaging import emit_info, emit_success, emit_warning, get_message_bus
from code_puppy.messaging.messages import VersionCheckMessage

logger = logging.getLogger(__name__)

CACHE_TTL_HOURS = 24
CACHE_FILE = Path(STATE_DIR) / "version_cache.json"


def normalize_version(version_str: Optional[str]) -> Optional[str]:
    if not version_str:
        return version_str
    version_str = version_str.lstrip("v")
    return version_str


def _version_tuple(version_str: Optional[str]) -> Optional[tuple[int, ...]]:
    """Convert version string to tuple of ints for proper comparison."""
    try:
        return tuple(int(x) for x in version_str.split("."))
    except ValueError, AttributeError:
        return None


def version_is_newer(latest: Optional[str], current: Optional[str]) -> bool:
    """Return True if latest version is strictly newer than current."""
    latest_tuple = _version_tuple(normalize_version(latest))
    current_tuple = _version_tuple(normalize_version(current))
    if latest_tuple is None or current_tuple is None:
        return False
    return latest_tuple > current_tuple


def versions_are_equal(current: Optional[str], latest: Optional[str]) -> bool:
    current_norm = normalize_version(current)
    latest_norm = normalize_version(latest)
    # Try numeric tuple comparison first
    current_tuple = _version_tuple(current_norm)
    latest_tuple = _version_tuple(latest_norm)
    if current_tuple is not None and latest_tuple is not None:
        return current_tuple == latest_tuple
    # Fallback to string comparison
    return current_norm == latest_norm


# ---------------------------------------------------------------------------
# Cache helpers
# ---------------------------------------------------------------------------


def _read_cache() -> Optional[dict]:
    """Read version cache file, returning None on any error."""
    try:
        if not CACHE_FILE.exists():
            return None
        data = json.loads(CACHE_FILE.read_text(encoding="utf-8"))
        checked_at = datetime.fromisoformat(data["checked_at"])
        age_hours = (datetime.now(timezone.utc) - checked_at).total_seconds() / 3600
        if age_hours > CACHE_TTL_HOURS:
            logger.debug("Version cache expired (%.1f hours old)", age_hours)
            return None
        logger.debug("Version cache hit: %s", data.get("version"))
        return data
    except (json.JSONDecodeError, KeyError, ValueError, OSError) as e:
        logger.debug("Failed to read version cache: %s", e)
        return None


def _write_cache(version: str) -> None:
    """Write version to cache file."""
    try:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        cache_data = {
            "version": version,
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }
        CACHE_FILE.write_text(json.dumps(cache_data), encoding="utf-8")
        logger.debug("Version cache written: %s", version)
    except OSError as e:
        logger.debug("Failed to write version cache: %s", e)


# ---------------------------------------------------------------------------
# Sync + async version fetchers
# ---------------------------------------------------------------------------


def fetch_latest_version(package_name: str) -> Optional[str]:
    """Fetch latest version from PyPI (sync fallback). Checks cache first."""
    cache = _read_cache()
    if cache:
        return cache["version"]
    try:
        response = httpx.get(f"https://pypi.org/pypi/{package_name}/json", timeout=2.0)
        response.raise_for_status()
        version = response.json()["info"]["version"]
        _write_cache(version)
        return version
    except Exception as e:
        emit_warning(f"Error fetching version: {e}")
        return None


async def fetch_latest_version_async(package_name: str) -> Optional[str]:
    """Fetch latest version from PyPI using async HTTP with short timeout."""
    cache = _read_cache()
    if cache:
        return cache["version"]
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"https://pypi.org/pypi/{package_name}/json", timeout=2.0
            )
            response.raise_for_status()
            version = response.json()["info"]["version"]
            _write_cache(version)
            return version
    except Exception as e:
        logger.debug("Async version fetch failed: %s", e)
        return None


async def check_version_background(current_version: str) -> None:
    """Background version check — fire-and-forget via asyncio.create_task().

    Fetches the latest version asynchronously and emits a version message
    if an update is available.
    """
    latest_version = await fetch_latest_version_async("codepp")
    if not latest_version:
        return
    update_available = version_is_newer(latest_version, current_version)
    version_msg = VersionCheckMessage(
        current_version=current_version,
        latest_version=latest_version,
        update_available=update_available,
    )
    get_message_bus().emit(version_msg)
    if update_available:
        emit_info(f"Latest version: {latest_version}")
        emit_warning(f"A new version of code puppy is available: {latest_version}")
        emit_success("Please consider updating!")


# ---------------------------------------------------------------------------
# Main entry-point (sync)
# ---------------------------------------------------------------------------


def default_version_mismatch_behavior(current_version: Optional[str]) -> None:
    """Check version mismatch using cache first, never blocking on network.

    If cache is fresh, use it for an instant update notification.
    If cache is stale, show current version immediately and return —
    the caller should fire check_version_background() separately.
    """
    if current_version is None:
        current_version = "0.0.0-unknown"
        emit_warning("Could not detect current version, using fallback")

    cache = _read_cache()
    if cache:
        latest_version = cache["version"]
        update_available = version_is_newer(latest_version, current_version)
        version_msg = VersionCheckMessage(
            current_version=current_version,
            latest_version=latest_version,
            update_available=update_available,
        )
        get_message_bus().emit(version_msg)
        emit_info(f"Current version: {current_version}")
        if update_available:
            emit_info(f"Latest version: {latest_version}")
            emit_warning(f"A new version of code puppy is available: {latest_version}")
            emit_success("Please consider updating!")
        return

    # Cache miss — show current version immediately, don't block
    emit_info(f"Current version: {current_version}")
    version_msg = VersionCheckMessage(
        current_version=current_version,
        latest_version=current_version,
        update_available=False,
    )
    get_message_bus().emit(version_msg)
