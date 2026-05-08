"""Universal Constructor - Dynamic tool creation and management plugin.

This plugin enables users to create, manage, and deploy custom tools
that extend Code Puppy's capabilities. Tools are stored in the user's
config directory and can be organized into namespaces via subdirectories.
"""

from pathlib import Path

from code_puppy.config_paths import resolve_path


# User tools directory - where user-created UC tools live
# Respects pup-ex isolation (ADR-003) — resolves under active home
def _user_uc_dir() -> Path:
    """Return the UC tools directory under the active home."""
    return resolve_path("plugins", "universal_constructor")


def __getattr__(name: str):
    """Lazy resolution of env-sensitive module-level names."""
    if name == "USER_UC_DIR":
        return _user_uc_dir()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


__all__ = ["USER_UC_DIR"]
