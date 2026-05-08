#!/usr/bin/env python3
"""Porting order computation with proper dependency-before-importer semantics.

Uses SCC condensation + topological levels to guarantee:
  - For acyclic deps, if A imports B, B appears before A in porting_order.
  - For cycles (SCCs), members may be grouped/ordered within the cycle,
    but outside-cycle dependencies still come first.

The old algorithm used a shared ``visited`` set during recursive depth
computation which corrupted memoization on back-edges, producing ~938
violations where importers preceded their own dependencies.
"""

from __future__ import annotations

from collections import deque
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .models import ModuleInfo


# ── SCC computation (iterative Tarjan's algorithm) ───────────────────


def _resolve_import(imp: str, modules: dict[str, ModuleInfo]) -> str | None:
    """Resolve an import name to the longest-matching known module."""
    if imp in modules:
        return imp
    best: str | None = None
    best_len = 0
    for mod_name in modules:
        if imp == mod_name or imp.startswith(f"{mod_name}."):
            if len(mod_name) > best_len:
                best = mod_name
                best_len = len(mod_name)
    return best


def _compute_sccs(modules: dict[str, ModuleInfo]) -> list[set[str]]:
    """Compute strongly connected components via iterative Tarjan's algorithm.

    Returns list of SCCs (each a set of module names).
    Modules with no internal imports still appear as singleton SCCs.
    """
    # Build adjacency: importer -> set of resolved dependencies
    adj: dict[str, set[str]] = {name: set() for name in modules}
    for name, mod in modules.items():
        for imp in mod.imports:
            target = _resolve_import(imp, modules)
            if target and target != name:
                adj[name].add(target)

    # Iterative Tarjan's algorithm
    index_counter = [0]
    stack: list[str] = []
    on_stack: set[str] = set()
    index: dict[str, int] = {}
    lowlink: dict[str, int] = {}
    sccs: list[set[str]] = []

    # Worklist for iterative DFS
    # Each frame: (node, neighbor_list_or_None)
    worklist: list[tuple[str, list[str] | None]] = []

    for start in sorted(modules):
        if start in index:
            continue
        worklist.append((start, None))

        while worklist:
            node, neighbors = worklist[-1]

            if neighbors is None:
                # First visit
                index[node] = index_counter[0]
                lowlink[node] = index_counter[0]
                index_counter[0] += 1
                stack.append(node)
                on_stack.add(node)
                worklist[-1] = (node, sorted(adj[node]))
                continue

            # Process next neighbor
            found_unvisited = False
            while neighbors:
                nxt = neighbors.pop(0)
                if nxt not in index:
                    worklist[-1] = (node, neighbors)
                    worklist.append((nxt, None))
                    found_unvisited = True
                    break
                elif nxt in on_stack:
                    lowlink[node] = min(lowlink[node], index[nxt])

            if found_unvisited:
                continue

            # All neighbors processed — check if this is an SCC root
            if lowlink[node] == index[node]:
                scc: set[str] = set()
                while True:
                    w = stack.pop()
                    on_stack.remove(w)
                    scc.add(w)
                    if w == node:
                        break
                sccs.append(scc)

            # Return to parent: propagate lowlink
            worklist.pop()
            if worklist:
                parent, _ = worklist[-1]
                lowlink[parent] = min(lowlink[parent], lowlink[node])

    return sccs


# ── Porting order computation ────────────────────────────────────────


def compute_porting_order(modules: dict[str, ModuleInfo]) -> list[tuple[str, int]]:
    """Compute recommended porting order (dependency-first).

    Algorithm:
      1. Compute SCCs (strongly connected components) via Tarjan's.
      2. Build condensation DAG where each SCC is a single node.
         Edges: importer-SCC -> dependency-SCC.
      3. Compute topological level via BFS from leaf-SCCs (those with
         no outgoing dependency edges — i.e., they import nothing from
         other SCCs).
      4. Assign each module its SCC's topological level.
      5. Sort by level (ascending), then fan-in (ascending), then name.

    This guarantees that for any **acyclic** import edge A -> B
    (A imports B), B appears strictly before A.  Within an SCC,
    dependency order cannot be guaranteed (by definition of a cycle),
    but outside-cycle dependencies still come first.

    Returns:
        List of (module_name, level) tuples in porting order.
    """
    sccs = _compute_sccs(modules)

    # Map each module to its SCC index
    mod_to_scc: dict[str, int] = {}
    for i, scc in enumerate(sccs):
        for mod in scc:
            mod_to_scc[mod] = i

    # Build condensation DAG: importer-SCC -> dependency-SCC
    scc_deps: dict[int, set[int]] = {i: set() for i in range(len(sccs))}
    for name, mod in modules.items():
        src = mod_to_scc[name]
        for imp in mod.imports:
            target = _resolve_import(imp, modules)
            if target and target in mod_to_scc:
                dst = mod_to_scc[target]
                if dst != src:
                    scc_deps[src].add(dst)

    # Build reverse graph: dependency-SCC -> importer-SCCs
    importers_of: dict[int, set[int]] = {i: set() for i in range(len(sccs))}
    for src, deps in scc_deps.items():
        for dst in deps:
            importers_of[dst].add(src)

    # BFS from leaf-SCCs (no outgoing deps) to compute levels.
    # Level 0 = pure leaves (import nothing from other SCCs).
    # Level N = 1 + max(level of dependency SCCs).
    remaining_deps: dict[int, int] = {
        i: len(scc_deps.get(i, set())) for i in range(len(sccs))
    }
    scc_level: dict[int, int] = {}
    queue: deque[int] = deque()

    # Seed: SCCs with no outgoing dependency edges
    for i in range(len(sccs)):
        if remaining_deps[i] == 0:
            scc_level[i] = 0
            queue.append(i)

    while queue:
        current = queue.popleft()
        current_level = scc_level[current]
        # Notify importer-SCCs that this dependency is satisfied
        for importer in importers_of.get(current, set()):
            # Importer's level must be at least current + 1
            scc_level[importer] = max(scc_level.get(importer, 0), current_level + 1)
            remaining_deps[importer] -= 1
            if remaining_deps[importer] == 0:
                queue.append(importer)

    # Assign module levels from SCC levels
    mod_level: dict[str, int] = {}
    for mod, scc_id in mod_to_scc.items():
        mod_level[mod] = scc_level.get(scc_id, 0)

    # Sort: level ascending, fan-in ascending, name ascending
    ordered = sorted(
        modules.items(),
        key=lambda x: (mod_level.get(x[0], 0), x[1].fan_in, x[0]),
    )

    return [(name, mod_level.get(name, 0)) for name, _ in ordered]
