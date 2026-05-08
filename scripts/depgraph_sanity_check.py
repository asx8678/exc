#!/usr/bin/env python3
"""Semantic sanity check for porting_order in generated artifacts.

Verifies that no acyclic import edge has the importer appearing before
its dependency.  Within-SCC (cycle) violations are reported separately
as expected exceptions.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Add scripts to path for depgraph imports
sys.path.insert(0, str(Path(__file__).parent))
from depgraph import build_dependency_graph, compute_porting_order
from depgraph.porting import _compute_sccs, _resolve_import


def main() -> int:
    pkg_path = Path("code_puppy")
    pkg_name = "code_puppy"

    print("Building dependency graph...")
    modules = build_dependency_graph(pkg_path, pkg_name)
    porting_order = compute_porting_order(modules)

    # Compute SCCs
    sccs = _compute_sccs(modules)
    mod_to_scc: dict[str, int] = {}
    for i, scc in enumerate(sccs):
        for mod in scc:
            mod_to_scc[mod] = i

    # Check violations
    order_map = {name: i for i, (name, _) in enumerate(porting_order)}
    cross_scc_violations: list[tuple[str, str, int, int]] = []
    within_scc_violations: list[tuple[str, str, int, int]] = []

    for name, mod in modules.items():
        for imp in mod.imports:
            target = _resolve_import(imp, modules)
            if target and target in order_map and name in order_map:
                if order_map[target] > order_map[name]:
                    entry = (name, target, order_map[name], order_map[target])
                    if mod_to_scc.get(name) == mod_to_scc.get(target):
                        within_scc_violations.append(entry)
                    else:
                        cross_scc_violations.append(entry)

    # Report
    print(f"\nTotal modules: {len(modules)}")
    print(f"Total SCCs: {len(sccs)}")
    print(f"Non-trivial SCCs (>1 member): {sum(1 for s in sccs if len(s) > 1)}")
    biggest = max(sccs, key=len)
    print(f"Largest SCC: {len(biggest)} modules")

    print(
        f"\nCross-SCC violations (importer before dependency): {len(cross_scc_violations)}"
    )
    if cross_scc_violations:
        print("  FAIL: Cross-SCC violations must be zero!")
        for imp, dep, ip, dp in sorted(
            cross_scc_violations, key=lambda x: x[3] - x[2], reverse=True
        )[:10]:
            print(f"    {imp} (pos {ip}) imports {dep} (pos {dp})")
        return 1

    print(f"Within-SCC violations (expected for cycles): {len(within_scc_violations)}")
    print("  These are expected — cycle members cannot be perfectly ordered.")

    # Verify key modules
    print("\nKey module positions:")
    for name in [
        "code_puppy",
        "code_puppy.agents",
        "code_puppy.messaging",
        "code_puppy.callbacks",
        "code_puppy.config",
    ]:
        if name in order_map:
            idx = order_map[name]
            level = porting_order[idx][1]
            print(f"  {name}: position={idx}, level={level}")

    # Verify code_puppy.messaging (high fan-in hub) appears AFTER its dependents
    # only if they are in different SCCs
    print("\n✓ PASS: Zero cross-SCC dependency-order violations in porting_order")
    print("  Within-SCC violations are expected and documented.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
