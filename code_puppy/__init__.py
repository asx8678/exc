"""code_puppy package initialization.

Uses lazy __getattr__ to defer heavy imports until needed.
Speeds up `python -m code_puppy --help` and unit test collection.

This module intentionally avoids eager imports of heavy submodules
(agents, messaging, etc.) to reduce CLI startup time from ~1.1s to
~0.3-0.5s for simple operations like --help and version checks.
"""

import importlib.metadata
from typing import TYPE_CHECKING, Any

# Biscuit was here! 🐶
try:
    _detected_version = importlib.metadata.version("codepp")
    # Ensure we never end up with None or empty string
    __version__ = _detected_version if _detected_version else "0.0.0-dev"
except Exception:
    # Fallback for dev environments where metadata might not be available
    __version__ = "0.0.0-dev"

if TYPE_CHECKING:
    # These imports are for type checkers only — they don't execute at runtime
    from . import agents as _agents_module  # noqa: F401
    from . import messaging as _messaging_module  # noqa: F401

# -----------------------------------------------------------------------------
# Lazy import registry: symbol_name -> (module_path, attribute_name)
# These are heavy submodules that should only load when actually accessed.
# -----------------------------------------------------------------------------
_LAZY_SUBMODULES: dict[str, str] = {
    # Submodules that cascade to heavy dependencies (pydantic_ai, openai, etc.)
    "agents": "code_puppy.agents",
    "messaging": "code_puppy.messaging",
    "model_factory": "code_puppy.model_factory",
    "interactive_loop": "code_puppy.interactive_loop",
    "message_transport": "code_puppy.message_transport",
    "text_ops": "code_puppy.text_ops",
    "agent_pinning_transport": "code_puppy.agent_pinning_transport",
}


def __getattr__(name: str) -> Any:
    """Lazy import heavy submodules on first access.

    This reduces CLI startup time by deferring imports of heavy dependencies
    like pydantic_ai, openai, anthropic, dbos, mcp until they're actually used.

    On first access to code_puppy.agents (or other lazy submodule), this
    function imports the actual module and caches it in sys.modules.
    Subsequent accesses return the cached module directly.

    Args:
        name: The attribute name being accessed on the code_puppy package.

    Returns:
        The requested submodule or raises AttributeError if not found.

    Raises:
        AttributeError: If the requested attribute is not a lazy submodule.

    Example:
        >>> import code_puppy
        >>> # At this point, heavy deps are NOT loaded
        >>> code_puppy.__version__  # Always eager, fast
        '1.0.0'
        >>> code_puppy.agents       # Triggers lazy import of agents module
        <module 'code_puppy.agents' from '...'>
    """
    if name in _LAZY_SUBMODULES:
        module_path = _LAZY_SUBMODULES[name]
        # Import the submodule and return it
        mod = __import__(module_path, fromlist=[""])
        # Cache on the package module for subsequent accesses
        globals()[name] = mod
        return mod

    raise AttributeError(f"module 'code_puppy' has no attribute '{name}'")


def __dir__() -> list[str]:
    """Ensure dir(code_puppy) shows lazy-loaded submodules.

    This makes introspection work correctly — dir() will show both the
    eager attributes (__version__) and the lazy submodules that can be
    accessed without raising AttributeError.
    """
    return sorted(set(globals().keys()) | set(_LAZY_SUBMODULES.keys()))


# Eager exports (always available, lightweight)
__all__ = ["__version__", "__dir__"]
