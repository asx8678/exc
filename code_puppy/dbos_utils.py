"""DBOS initialization management utilities for Code Puppy.

Provides helper functions for checking, initializing, and managing DBOS state
with proper error handling and graceful fallbacks when DBOS is unavailable.
"""

import os
import time
from typing import TYPE_CHECKING

from code_puppy import __version__
from code_puppy.config import DBOS_DATABASE_URL, get_use_dbos
from code_puppy.error_logging import log_error
from code_puppy.messaging import emit_info, emit_warning

if TYPE_CHECKING:
    from dbos import DBOSConfig


def is_dbos_initialized() -> bool:
    """Check if DBOS has an active instance.

    Returns True if DBOS is available and has been launched.
    Returns False if DBOS is not available, no instance exists, or not launched.

    Returns:
        bool: True if DBOS is initialized and active
    """
    try:
        from dbos._dbos import _dbos_global_instance

        # Check if global instance exists AND has been launched
        if _dbos_global_instance is None:
            return False

        return getattr(_dbos_global_instance, "_launched", False)
    except ImportError:
        # DBOS not available
        return False
    except Exception:
        # Any other error means not properly initialized
        return False


def initialize_dbos() -> bool:
    """Initialize DBOS with the standard configuration.

    Uses the same configuration pattern as app_runner.py:
    - Reads DBOS_DATABASE_URL from config
    - Uses environment variables for DBOS_CONDUCTOR_KEY, DBOS_LOG_LEVEL
    - App version format: f"{current_version}-{int(time.time() * 1000)}"
      or from DBOS_APP_VERSION env var

    Returns:
        bool: True if DBOS was successfully initialized, False otherwise
    """
    try:
        from dbos import DBOS
    except ImportError:
        emit_warning("DBOS not available - skipping initialization")
        return False

    current_version = __version__
    dbos_app_version = os.environ.get(
        "DBOS_APP_VERSION", f"{current_version}-{int(time.time() * 1000)}"
    )

    dbos_config: "DBOSConfig" = {
        "name": "dbos-code-puppy",
        "system_database_url": DBOS_DATABASE_URL,
        "run_admin_server": False,
        "conductor_key": os.environ.get("DBOS_CONDUCTOR_KEY"),
        "log_level": os.environ.get("DBOS_LOG_LEVEL", "ERROR"),
        "application_version": dbos_app_version,
    }

    try:
        DBOS(config=dbos_config)
        DBOS.launch()
        emit_info(f"DBOS initialized (version: {dbos_app_version})")
        return True
    except Exception as e:
        emit_warning(f"Error initializing DBOS: {e}")
        log_error(e, context="DBOS initialization error")
        return False


def initialize_dbos_if_needed() -> bool:
    """Check if DBOS needs initialization and initialize if required.

    Checks if DBOS is enabled (get_use_dbos() is True) AND not already initialized.
    If both conditions are met, calls initialize_dbos().

    Returns:
        bool: True if DBOS is ready (either was already initialized
              or successfully initialized now), False otherwise
    """
    # Check if DBOS is enabled in config
    if not get_use_dbos():
        return False

    # Check if already initialized
    if is_dbos_initialized():
        return True

    # Need to initialize
    return initialize_dbos()


def reinitialize_dbos() -> bool:
    """Destroy existing DBOS instance if it exists, then reinitialize.

    Performs a clean shutdown of any existing DBOS instance followed by
    fresh initialization. Handles cases where destroy fails gracefully.

    Returns:
        bool: True if DBOS was successfully reinitialized, False otherwise
    """
    try:
        from dbos._dbos import _dbos_global_instance
    except ImportError:
        emit_warning("DBOS not available - cannot reinitialize")
        return False

    # Attempt to destroy existing instance if it exists
    if _dbos_global_instance is not None:
        try:
            from dbos import DBOS

            DBOS.destroy()
            emit_info("Existing DBOS instance destroyed")
        except Exception as e:
            emit_warning(f"Could not destroy existing DBOS instance: {e}")
            log_error(e, context="DBOS destroy during reinitialization")
            # Continue with initialization attempt anyway

    # Initialize fresh
    return initialize_dbos()
