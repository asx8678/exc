#!/usr/bin/env python3
"""Unit tests: cycles, porting order, SCC semantics."""

from __future__ import annotations

import tempfile
from pathlib import Path

from .analyzer import build_dependency_graph
from .cycles import find_cycles
from .models import ModuleInfo
from .porting import _compute_sccs, _resolve_import, compute_porting_order

# ── Helpers ─────────────────────────────────────────────────────────


def _check_no_acyclic_violations(
    modules: dict[str, ModuleInfo],
    porting_order: list[tuple[str, int]],
) -> list[tuple[str, str]]:
    """Return list of (importer, dependency) pairs where importer precedes dep.

    Only checks cross-SCC edges; within-SCC violations are expected
    because cycle members cannot be ordered consistently.
    """
    sccs = _compute_sccs(modules)
    mod_to_scc: dict[str, int] = {}
    for i, scc in enumerate(sccs):
        for mod in scc:
            mod_to_scc[mod] = i

    order_map = {name: i for i, (name, _) in enumerate(porting_order)}
    violations: list[tuple[str, str]] = []

    for name, mod in modules.items():
        for imp in mod.imports:
            target = _resolve_import(imp, modules)
            if (
                target
                and target in order_map
                and name in order_map
                and mod_to_scc.get(name) != mod_to_scc.get(target)
            ):
                if order_map[target] > order_map[name]:
                    violations.append((name, target))

    return violations


# ── Deterministic cycles ────────────────────────────────────────────


def test_deterministic_cycles() -> bool:
    """Test that cycle detection is deterministic."""
    modules = {
        "mod_a": ModuleInfo(name="mod_a", file_path=Path("a.py"), imports={"mod_b"}),
        "mod_b": ModuleInfo(name="mod_b", file_path=Path("b.py"), imports={"mod_c"}),
        "mod_c": ModuleInfo(name="mod_c", file_path=Path("c.py"), imports={"mod_a"}),
        "mod_d": ModuleInfo(name="mod_d", file_path=Path("d.py"), imports=set()),
    }
    for mod_name, mod_info in modules.items():
        for imp in mod_info.imports:
            if imp in modules:
                modules[imp].imported_by.add(mod_name)

    cycles_runs = [find_cycles(modules) for _ in range(3)]

    all_same = all(c == cycles_runs[0] for c in cycles_runs)
    if not all_same:
        print("FAIL: Cycle detection is not deterministic")
        for i, c in enumerate(cycles_runs):
            print(f"  Run {i + 1}: {c}")
        return False

    if cycles_runs[0]:
        first_cycle = cycles_runs[0][0]
        if first_cycle[0] != min(first_cycle[:-1]):
            print(f"FAIL: Cycle not normalized: {first_cycle}")
            return False

    print(f"PASS: Cycle detection is deterministic ({len(cycles_runs[0])} cycles)")
    return True


# ── Porting order ───────────────────────────────────────────────────


def test_porting_order() -> bool:
    """Test that porting order puts dependencies before importers."""
    modules = {
        "hub": ModuleInfo(
            name="hub",
            file_path=Path("hub.py"),
            imports=set(),
            imported_by={f"middle{i}" for i in range(10)},
        ),
        "middle1": ModuleInfo(
            name="middle1",
            file_path=Path("m1.py"),
            imports={"hub"},
            imported_by={"leaf"},
        ),
        "leaf": ModuleInfo(
            name="leaf",
            file_path=Path("leaf.py"),
            imports={"middle1"},
            imported_by=set(),
        ),
    }

    porting_order = compute_porting_order(modules)
    ordered_names = [name for name, _ in porting_order]

    hub_idx = ordered_names.index("hub")
    leaf_idx = ordered_names.index("leaf")
    mid_idx = ordered_names.index("middle1")

    # Dependency-before-importer: hub before middle1 before leaf
    if hub_idx > mid_idx:
        print("FAIL: hub appears after middle1 (its importer)")
        print(f"  Order: {ordered_names}")
        return False
    if mid_idx > leaf_idx:
        print("FAIL: middle1 appears after leaf (its importer)")
        print(f"  Order: {ordered_names}")
        return False

    violations = _check_no_acyclic_violations(modules, porting_order)
    if violations:
        print(f"FAIL: {len(violations)} cross-SCC violations: {violations}")
        return False

    print(f"PASS: Porting order correct: {ordered_names}")
    return True


def test_porting_order_dependency_first() -> bool:
    """Test dependency-before-importer on a diamond dependency graph.

    Graph:   base
              / \\
           left  right
              \\ /
             consumer

    Porting order must be: base → left/right → consumer.
    """
    modules = {
        "base": ModuleInfo(
            name="base",
            file_path=Path("base.py"),
            imports=set(),
            imported_by={"left", "right"},
        ),
        "left": ModuleInfo(
            name="left",
            file_path=Path("left.py"),
            imports={"base"},
            imported_by={"consumer"},
        ),
        "right": ModuleInfo(
            name="right",
            file_path=Path("right.py"),
            imports={"base"},
            imported_by={"consumer"},
        ),
        "consumer": ModuleInfo(
            name="consumer",
            file_path=Path("consumer.py"),
            imports={"left", "right"},
            imported_by=set(),
        ),
    }

    porting_order = compute_porting_order(modules)
    order_map = {name: i for i, (name, _) in enumerate(porting_order)}

    # base must come before left and right
    if order_map["base"] > order_map["left"]:
        print(f"FAIL: base after left — {porting_order}")
        return False
    if order_map["base"] > order_map["right"]:
        print(f"FAIL: base after right — {porting_order}")
        return False
    # left and right must come before consumer
    if order_map["left"] > order_map["consumer"]:
        print(f"FAIL: left after consumer — {porting_order}")
        return False
    if order_map["right"] > order_map["consumer"]:
        print(f"FAIL: right after consumer — {porting_order}")
        return False

    violations = _check_no_acyclic_violations(modules, porting_order)
    if violations:
        print(f"FAIL: {len(violations)} violations: {violations}")
        return False

    print(f"PASS: Diamond dependency order correct: {[n for n, _ in porting_order]}")
    return True


def test_porting_order_acyclic_no_violations() -> bool:
    """Pipeline test: temp package with no cycles must have zero violations."""
    with tempfile.TemporaryDirectory() as tmpdir:
        pkg_dir = Path(tmpdir) / "order_pkg"
        pkg_dir.mkdir()

        # Create a layered package:
        #   __init__.py imports .utils
        #   utils.py (leaf, no deps)
        #   services.py imports .utils
        #   agents.py imports .services, .utils
        #   cli.py imports .agents, .services
        (pkg_dir / "__init__.py").write_text("from . import utils\n")
        (pkg_dir / "utils.py").write_text("VALUE = 1\n")
        (pkg_dir / "services.py").write_text("from .utils import VALUE\n")
        (pkg_dir / "agents.py").write_text(
            "from .services import VALUE\nfrom . import utils\n"
        )
        (pkg_dir / "cli.py").write_text(
            "from .agents import VALUE\nfrom . import services\n"
        )

        modules = build_dependency_graph(pkg_dir, "order_pkg")
        porting_order = compute_porting_order(modules)

        violations = _check_no_acyclic_violations(modules, porting_order)
        if violations:
            print(f"FAIL: {len(violations)} violations in acyclic graph:")
            for imp, dep in violations:
                print(f"  {imp} before its dep {dep}")
            return False

        # Explicit ordering check
        order_map = {name: i for i, (name, _) in enumerate(porting_order)}
        if order_map.get("order_pkg.utils", 999) > order_map.get(
            "order_pkg.services", 0
        ):
            print(f"FAIL: utils after services — {porting_order}")
            return False

        print("PASS: Acyclic temp package has zero porting-order violations")
        return True


def test_porting_order_scc_documented() -> bool:
    """SCC members may appear in any order; only cross-SCC edges are strict.

    Build a cycle: a→b→c→a, plus leaf d (no deps) imported by a.
    d must appear before a/b/c; a/b/c can be in any order.
    """
    modules = {
        "a": ModuleInfo(name="a", file_path=Path("a.py"), imports={"b", "d"}),
        "b": ModuleInfo(name="b", file_path=Path("b.py"), imports={"c"}),
        "c": ModuleInfo(name="c", file_path=Path("c.py"), imports={"a"}),
        "d": ModuleInfo(name="d", file_path=Path("d.py"), imports=set()),
    }
    # Populate imported_by so fan_in is correct
    for mod_name, mod_info in modules.items():
        for imp in mod_info.imports:
            if imp in modules:
                modules[imp].imported_by.add(mod_name)

    porting_order = compute_porting_order(modules)
    order_map = {name: i for i, (name, _) in enumerate(porting_order)}

    # d (leaf, level 0) must come before a, b, c (cycle, level 1+)
    for cyc_mod in ("a", "b", "c"):
        if order_map["d"] > order_map[cyc_mod]:
            print(
                f"FAIL: leaf 'd' (pos {order_map['d']}) appears after "
                f"cycle member '{cyc_mod}' (pos {order_map[cyc_mod]})"
            )
            return False

    # Cross-SCC violations must be zero
    violations = _check_no_acyclic_violations(modules, porting_order)
    if violations:
        print(f"FAIL: {len(violations)} cross-SCC violations: {violations}")
        return False

    # Within-SCC: a imports b, but a may appear before b — that's OK.
    # Document this explicitly.
    within_scc = []
    for name, mod in modules.items():
        for imp in mod.imports:
            if imp in order_map and name in order_map:
                if order_map[imp] > order_map[name]:
                    within_scc.append((name, imp))

    print(
        f"PASS: SCC order correct (d first, cycle members grouped). "
        f"Within-SCC order: {[n for n, _ in porting_order]}. "
        f"Within-SCC violations (expected): {len(within_scc)}"
    )
    return True
