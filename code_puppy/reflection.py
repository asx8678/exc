"""Reflection utilities for resolving module:variable paths.

This module provides utilities for dynamically resolving dotted paths
like "code_puppy.callbacks:register_callback" to their corresponding
Python objects, with helpful error messages for missing dependencies.
"""

import importlib
from typing import Any

# Mapping of module names to pip install hints for optional dependencies.
# This helps users understand what to install when a module import fails.
MODULE_TO_PACKAGE_HINTS: dict[str, str] = {
    "langsmith": "langsmith",
    "langfuse": "langfuse",
    "playwright": "playwright",
    "dbos": "dbos",
    "dbos_transact": "dbos",
}


def resolve_variable(path: str, expected_type: type | None = None) -> Any:
    """Resolve a dotted module:variable path to the corresponding Python object.

    Supports paths in the format:
    - "module.submodule:variable_name" (colon separator)
    - "module.submodule.variable_name" (dot separator - last dot treated as separator)

    Args:
        path: The dotted path to resolve (e.g., "code_puppy.callbacks:register_callback")
        expected_type: Optional type to validate the resolved object against.
                       If provided and the resolved object is not an instance
                       of this type, a TypeError is raised.

    Returns:
        The resolved Python object (function, class, variable, etc.)

    Raises:
        ValueError: If the path format is invalid (empty, no separator, etc.)
        ImportError: If the module cannot be imported, with a helpful pip install
                     hint if the module is a known optional dependency
        AttributeError: If the variable cannot be found in the module
        TypeError: If expected_type is provided and the resolved object
                   doesn't match the expected type

    Examples:
        >>> resolve_variable("code_puppy.callbacks:register_callback")
        <function register_callback at ...>

        >>> resolve_variable("code_puppy.config:get_config_value")
        <function get_config_value at ...>

        >>> resolve_variable("os.path:join")
        <function join at ...>
    """
    if not path or not isinstance(path, str):
        raise ValueError(f"Path must be a non-empty string, got: {path!r}")

    # Normalize path: handle both colon and dot separators
    # First, try to find a colon separator (explicit module:variable format)
    if ":" in path:
        module_path, variable_name = path.split(":", 1)
    else:
        # No colon - use the last dot as the separator
        # This handles "module.submodule.variable" format
        if "." not in path:
            raise ValueError(
                f"Invalid path format: {path!r}. "
                "Path must contain a separator (':' or '.') to distinguish "
                "module path from variable name. Example: 'module:variable' or 'module.variable'"
            )
        # Split on the last dot
        module_path, variable_name = path.rsplit(".", 1)

    # Validate extracted parts
    if not module_path:
        raise ValueError(f"Invalid path format: {path!r}. Module path is empty.")
    if not variable_name:
        raise ValueError(f"Invalid path format: {path!r}. Variable name is empty.")

    # Try to import the module
    try:
        module = importlib.import_module(module_path)
    except ImportError as e:
        # Check if this is a known optional dependency and provide a helpful hint
        root_module = module_path.split(".")[0]
        if root_module in MODULE_TO_PACKAGE_HINTS:
            package_hint = MODULE_TO_PACKAGE_HINTS[root_module]
            raise ImportError(
                f"Could not import module '{root_module}'. "
                f"Install with: pip install {package_hint}"
            ) from e
        # Re-raise with context for unknown modules
        raise ImportError(f"Could not import module '{module_path}': {e}") from e
    except ModuleNotFoundError as e:
        # Handle the specific case where the module itself doesn't exist
        root_module = module_path.split(".")[0]
        if root_module in MODULE_TO_PACKAGE_HINTS:
            package_hint = MODULE_TO_PACKAGE_HINTS[root_module]
            raise ImportError(
                f"Could not import module '{root_module}'. "
                f"Install with: pip install {package_hint}"
            ) from e
        raise ImportError(f"Could not import module '{module_path}': {e}") from e

    # Try to get the variable from the module
    try:
        variable = getattr(module, variable_name)
    except AttributeError as e:
        available = dir(module)
        # Filter out private attributes for cleaner error message
        public_available = [name for name in available if not name.startswith("_")]
        raise AttributeError(
            f"Module '{module_path}' has no attribute '{variable_name}'. "
            f"Available public attributes: {', '.join(public_available[:10])}"
            f"{'...' if len(public_available) > 10 else ''}"
        ) from e

    # Type validation if requested
    if expected_type is not None:
        if not isinstance(variable, expected_type):
            actual_type = type(variable).__name__
            expected_name = expected_type.__name__
            raise TypeError(
                f"Resolved variable '{variable_name}' from '{module_path}' "
                f"has type {actual_type!r}, but expected {expected_name!r}"
            )

    return variable
