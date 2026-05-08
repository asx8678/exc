"""Plugin-level config helpers for session_logger."""

import logging
from pathlib import Path

from code_puppy.config_package import env_bool, get_puppy_config

logger = logging.getLogger(__name__)


def get_session_logger_enabled() -> bool:
    """Check if session logging is enabled.

    Returns:
        True if session_logger_enabled is set to true/yes/1/on, False otherwise.
        Default: False (opt-in for privacy).

    Priority: PUPPY_SESSION_LOGGER_ENABLED env var > puppy.cfg setting > default False
    """
    cfg = get_puppy_config()
    # Env var takes priority over config file for easy dogfooding toggle
    return env_bool("PUPPY_SESSION_LOGGER_ENABLED", default=cfg.session_logger_enabled)


def get_session_logger_dir() -> Path:
    """Get the session log directory.

    Returns:
        Path to write session directories. Always uses the canonical
        cfg.sessions_dir (defaults to DATA_DIR / "sessions", typically
        ~/.code_puppy/sessions).
    """
    cfg = get_puppy_config()
    # Always use the canonical sessions_dir from PuppyConfig.
    # There is no separate session_logger_dir config option.
    return cfg.sessions_dir
