#!/usr/bin/env python3
"""Import resolution utilities with longest-module matching."""

from __future__ import annotations


def resolve_relative_import(
    current_module: str,
    level: int,
    module: str | None,
    *,
    is_package: bool = False,
) -> str | None:
    """
    Resolve a relative import to an absolute module name.

    Uses CPython's rsplit algorithm (importlib._bootstrap._resolve_name).

    Args:
        current_module: The module containing the import (e.g. 'code_puppy.tools.file_ops')
        level: Number of dots (1 for '.', 2 for '..', etc.)
        module: The module name after the dots (e.g. 'utils' in 'from .utils import x')
        is_package: True if current_module is from __init__.py (package context = self).

    Returns:
        Absolute module name or None if resolution fails

    Examples:
        >>> resolve_relative_import("pkg.sub", 1, "leaf", is_package=True)
        'pkg.sub.leaf'
        >>> resolve_relative_import("pkg.sub", 1, None, is_package=True)
        'pkg.sub'
        >>> resolve_relative_import("pkg.sub.mod", 1, "utils", is_package=False)
        'pkg.sub.utils'
        >>> resolve_relative_import("pkg.sub", 2, "sibling", is_package=True)
        'pkg.sibling'
    """
    if level == 0:
        return module

    # Compute package context matching Python's __package__ semantics
    if is_package:
        package_context = current_module
    else:
        parts = current_module.split(".")
        package_context = ".".join(parts[:-1]) if len(parts) > 1 else current_module

    bits = package_context.rsplit(".", level - 1)
    if len(bits) < level:
        return None

    base = bits[0]
    if not base:
        return None

    if module:
        return f"{base}.{module}"
    return base


def find_matching_module(import_name: str, modules: set[str]) -> str | None:
    """
    Find the best matching module for an import using longest-module matching.

    This ensures we match the most specific module, not a broad parent.
    For example, if importing 'code_puppy.tools.file_ops' and both
    'code_puppy.tools' and 'code_puppy.tools.file_ops' exist,
    we return 'code_puppy.tools.file_ops' (the longer/more specific one).

    Args:
        import_name: The imported name (e.g., 'code_puppy.tools.file_ops')
        modules: Set of available module names

    Returns:
        The best matching module name or None
    """
    if import_name in modules:
        return import_name

    best_match = None
    best_len = 0

    for mod_name in modules:
        # Check if import_name is the module or a submodule/symbol of it
        if import_name == mod_name or import_name.startswith(f"{mod_name}."):
            if len(mod_name) > best_len:
                best_match = mod_name
                best_len = len(mod_name)

    return best_match
