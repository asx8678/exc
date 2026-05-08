#!/usr/bin/env python3
"""Deterministic import cycle detection."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .models import ModuleInfo


def find_cycles(modules: dict[str, ModuleInfo]) -> list[list[str]]:
    """
    Find import cycles using DFS with deterministic output.

    Returns cycles sorted lexicographically for reproducibility.
    Each cycle is normalized to start from its smallest element.
    """
    cycles: list[list[str]] = []
    visited: set[str] = set()
    rec_stack: set[str] = set()
    path: list[str] = []

    # Get sorted module list for deterministic traversal
    sorted_modules = sorted(modules.keys())

    def get_base_module(import_name: str) -> str | None:
        """Find the base module for an import using longest match."""
        if import_name in modules:
            return import_name

        best_match = None
        best_len = 0

        for mod_name in modules:
            if import_name == mod_name or import_name.startswith(f"{mod_name}."):
                if len(mod_name) > best_len:
                    best_match = mod_name
                    best_len = len(mod_name)

        return best_match

    def dfs(node: str) -> None:
        visited.add(node)
        rec_stack.add(node)
        path.append(node)

        if node in modules:
            # Sort imports for deterministic traversal
            sorted_imports = sorted(modules[node].imports)
            for imp in sorted_imports:
                neighbor = get_base_module(imp)
                if neighbor is None or neighbor not in modules:
                    continue

                if neighbor not in visited:
                    dfs(neighbor)
                elif neighbor in rec_stack:
                    # Found a cycle
                    try:
                        cycle_start = path.index(neighbor)
                        cycle = path[cycle_start:] + [neighbor]

                        # Normalize: start from smallest element
                        min_val = min(cycle[:-1])
                        min_idx = cycle[:-1].index(min_val)
                        normalized = (
                            cycle[min_idx:-1] + cycle[:min_idx] + [cycle[min_idx]]
                        )

                        if normalized not in cycles:
                            cycles.append(normalized)
                    except ValueError:
                        pass

        path.pop()
        rec_stack.remove(node)

    # Process modules in sorted order for determinism
    for mod in sorted_modules:
        if mod not in visited:
            dfs(mod)

    # Sort cycles lexicographically for reproducible output
    cycles.sort()

    return cycles
