"""Version check plugin - checks for code_puppy updates on startup."""

import logging
from importlib.metadata import version as get_version

from code_puppy.callbacks import register_callback
from code_puppy.version_checker import default_version_mismatch_behavior

logger = logging.getLogger(__name__)


def _on_version_check(*args, **kwargs):
    """Check for newer version on PyPI using the existing version_checker module."""
    try:
        # The current version is passed as the first positional arg by app_runner.py
        current = args[0] if args else get_version("codepp")
        default_version_mismatch_behavior(current)
    except Exception:
        logger.debug("Version check failed")


register_callback("version_check", _on_version_check)
