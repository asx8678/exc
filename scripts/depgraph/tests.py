#!/usr/bin/env python3
"""Self-tests for dependency graph generator (using only stdlib).

Thin aggregator — individual test suites live in:
  - tests_resolver.py   (relative import resolution, longest-module matching)
  - tests_porting.py    (cycles, porting order, SCC semantics)
  - tests_integration.py (temp packages, symbol imports, stability)
"""

from __future__ import annotations

import sys

from .tests_integration import (
    test_from_dot_import_leaf,
    test_init_relative_imports,
    test_longest_module_match_in_pipeline,
    test_reproducible_reports,
    test_stable_timestamp,
    test_symbols_not_counted,
)
from .tests_porting import (
    test_deterministic_cycles,
    test_porting_order,
    test_porting_order_acyclic_no_violations,
    test_porting_order_dependency_first,
    test_porting_order_scc_documented,
)
from .tests_resolver import (
    test_longest_module_matching,
    test_module_name_calculation,
    test_resolve_relative_import,
)

# ── Runner ──────────────────────────────────────────────────────────


def run_self_tests() -> int:
    """Run all self-tests."""
    print("=" * 60)
    print("Dependency Graph Generator - Self Tests")
    print("=" * 60)
    print()

    tests = [
        ("Relative Import Resolution", test_resolve_relative_import),
        ("Longest Module Matching", test_longest_module_matching),
        ("Deterministic Cycles", test_deterministic_cycles),
        ("Porting Order", test_porting_order),
        ("Porting Order: Diamond", test_porting_order_dependency_first),
        (
            "Porting Order: Acyclic No Violations",
            test_porting_order_acyclic_no_violations,
        ),
        ("Porting Order: SCC Documented", test_porting_order_scc_documented),
        ("Module Name Calculation", test_module_name_calculation),
        ("Init Relative Imports", test_init_relative_imports),
        ("From-Dot Import Leaf", test_from_dot_import_leaf),
        ("Symbols Not Counted", test_symbols_not_counted),
        ("Longest Match in Pipeline", test_longest_module_match_in_pipeline),
        ("Stable Timestamp", test_stable_timestamp),
        ("Reproducible Reports", test_reproducible_reports),
    ]

    results = []
    for name, test_func in tests:
        print(f"\n--- {name} ---")
        try:
            passed = test_func()
            results.append((name, passed))
        except Exception as e:
            print(f"ERROR: {e}")
            import traceback

            traceback.print_exc()
            results.append((name, False))

    print()
    print("=" * 60)
    print("Test Summary")
    print("=" * 60)

    passed_count = sum(1 for _, p in results if p)
    total_count = len(results)

    for name, passed in results:
        status = "PASS" if passed else "FAIL"
        print(f"  [{status}] {name}")

    print()
    print(f"Total: {passed_count}/{total_count} passed")

    return 0 if passed_count == total_count else 1


if __name__ == "__main__":
    sys.exit(run_self_tests())
