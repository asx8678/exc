"""Core state and lifecycle management for agent memory plugin.

Handles global state initialization, storage/updater caching,
and startup/shutdown lifecycle callbacks.
"""

import logging
from typing import TYPE_CHECKING

from code_puppy.callbacks import register_callback

from .config import MemoryConfig, load_config
from .storage import FileMemoryStorage
from .updater import MemoryUpdater

if TYPE_CHECKING:
    from .extraction import FactExtractor
    from .signals import SignalDetector

logger = logging.getLogger(__name__)

# Global state (initialized on startup)
_config: MemoryConfig | None = None
_extractor: "FactExtractor" | None = None
_detector: "SignalDetector" | None = None

# Per-agent memory components cache
_storage_cache: dict[str, FileMemoryStorage] = {}
_updater_cache: dict[str, MemoryUpdater] = {}

# Track if memory is enabled (set during startup - Phase 6)
_memory_enabled = False


def is_memory_enabled_global() -> bool:
    """Check if memory is enabled globally."""
    return _memory_enabled


def get_config() -> MemoryConfig | None:
    """Get the current memory configuration."""
    return _config


def get_extractor() -> "FactExtractor" | None:
    """Get the fact extractor instance."""
    return _extractor


def get_detector() -> "SignalDetector" | None:
    """Get the signal detector instance."""
    return _detector


def _get_storage(agent_name: str) -> FileMemoryStorage:
    """Get or create FileMemoryStorage for an agent."""
    if agent_name not in _storage_cache:
        _storage_cache[agent_name] = FileMemoryStorage(agent_name)
    return _storage_cache[agent_name]


def _get_updater(agent_name: str) -> MemoryUpdater:
    """Get or create MemoryUpdater for an agent."""
    if agent_name not in _updater_cache:
        config = _config or load_config()
        storage = _get_storage(agent_name)
        _updater_cache[agent_name] = MemoryUpdater(
            storage, debounce_ms=config.debounce_ms
        )
    return _updater_cache[agent_name]


def _on_startup() -> None:
    """Initialize the memory plugin on startup.

    Phases 5 & 6: Check config (opt-in), and if enabled,
    load configuration and initialize extraction and detection systems.
    """
    global _config, _extractor, _detector, _memory_enabled

    _config = load_config()

    # Phase 6: Check if memory is enabled (OPT-IN)
    # Use loaded config for enabled status (allows tests to mock config)
    _memory_enabled = _config.enabled

    if not _memory_enabled:
        logger.debug(
            "Agent Memory plugin loaded but disabled "
            "(set memory_enabled=true in puppy.cfg to activate)"
        )
        return

    # Phase 5: Initialize components
    from .extraction import FactExtractor
    from .signals import SignalDetector

    _extractor = FactExtractor(min_confidence=_config.min_confidence)
    _detector = SignalDetector()

    logger.debug(
        "Agent Memory plugin activated (Phases 5 & 6: Full Integration + Config/CLI) - "
        f"max_facts={_config.max_facts}, token_budget={_config.token_budget}, "
        f"extraction_enabled={_config.extraction_enabled}"
    )


def _on_shutdown() -> None:
    """Flush pending memory writes and clean up async tasks on shutdown.

    Ensures all debounced facts are persisted and async operations complete
    before the application exits (code-puppy-48p: added async task cleanup).
    """
    if not _memory_enabled or (_config and not _config.enabled):
        # Still clean up async tasks even if memory is disabled
        _cleanup_async_tasks()
        return

    # Flush pending facts
    flushed_count = 0
    for agent_name, updater in _updater_cache.items():
        try:
            items = updater.flush()
            if items:
                flushed_count += len(items)
                logger.debug(f"Flushed {len(items)} pending facts for {agent_name}")
        except Exception as e:
            logger.warning(f"Failed to flush memory for {agent_name}: {e}")

    if flushed_count > 0:
        logger.info(f"Agent Memory: Flushed {flushed_count} pending facts on shutdown")

    # Clean up async tasks (code-puppy-48p)
    _cleanup_async_tasks()


def _cleanup_async_tasks() -> None:
    """Clean up any pending async tasks (code-puppy-48p fix)."""
    try:
        from .processing import cleanup_async_tasks

        task_count = cleanup_async_tasks()
        if task_count > 0:
            logger.debug(f"Cleaned up {task_count} pending async tasks")
    except Exception as e:
        # Don't let cleanup errors break shutdown
        logger.debug(f"Error during async task cleanup: {e}")


def register_core_callbacks() -> None:
    """Register core lifecycle callbacks."""
    register_callback("startup", _on_startup)
    register_callback("shutdown", _on_shutdown)
