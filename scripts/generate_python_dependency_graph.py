#!/usr/bin/env python3
"""
Generate a dependency graph of Python modules for Elixir migration planning.

This script statically analyzes the code_puppy package to identify:
- High-fan-in hub modules (port last)
- Low-dependency leaf modules (port first)
- Import cycles (break before porting)
- Recommended porting order

Usage:
    python scripts/generate_python_dependency_graph.py
    python scripts/generate_python_dependency_graph.py --format json
    python scripts/generate_python_dependency_graph.py --output docs/python_dependency_graph.md
    python scripts/generate_python_dependency_graph.py --self-test

Limitations:
    - Static analysis only; dynamic imports (importlib, __import__) are missed
    - Conditional imports (try/except) are treated equally with regular imports
    - Type-only imports (TYPE_CHECKING blocks) are included
    - External package imports are tracked but not resolved
    - Relative imports within packages are resolved to absolute paths
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Add the scripts directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

try:
    from depgraph import (
        build_dependency_graph,
        compute_porting_order,
        find_cycles,
        generate_json_report,
        generate_markdown_report,
    )
    from depgraph.tests import run_self_tests
except ImportError as e:
    print(f"Error importing depgraph module: {e}", file=sys.stderr)
    print(
        "Make sure the depgraph/ directory is in the same location as this script.",
        file=sys.stderr,
    )
    sys.exit(1)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate Python dependency graph for migration planning"
    )
    parser.add_argument(
        "--package-path",
        type=Path,
        default=Path("code_puppy"),
        help="Path to Python package (default: code_puppy)",
    )
    parser.add_argument(
        "--package-name",
        default="code_puppy",
        help="Package name for imports (default: code_puppy)",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        help="Output file path (default: stdout)",
    )
    parser.add_argument(
        "--format",
        choices=["markdown", "json"],
        default="markdown",
        help="Output format (default: markdown)",
    )
    parser.add_argument(
        "--stable",
        action="store_true",
        help="Use stable timestamp for reproducible output",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run self-tests and exit",
    )

    args = parser.parse_args()

    if args.self_test:
        return run_self_tests()

    # Resolve package path
    package_path = args.package_path.resolve()
    if not package_path.exists():
        print(f"Error: Package path not found: {package_path}", file=sys.stderr)
        return 1

    print(f"Analyzing {args.package_name} at {package_path}...")

    # Build dependency graph
    modules = build_dependency_graph(package_path, args.package_name)
    print(f"Found {len(modules)} modules")

    # Find cycles
    cycles = find_cycles(modules)
    print(f"Found {len(cycles)} import cycles")

    # Compute porting order
    porting_order = compute_porting_order(modules)

    # Generate report
    if args.format == "json":
        content = generate_json_report(
            modules, cycles, porting_order, args.output, args.stable
        )
    else:
        content = generate_markdown_report(
            modules, cycles, porting_order, args.output, args.stable
        )

    if not args.output:
        print(content)

    return 0


def generate_both(
    package_path: Path,
    package_name: str = "code_puppy",
    md_path: Path | None = None,
    json_path: Path | None = None,
    stable: bool = False,
) -> int:
    """Generate both markdown and JSON reports in a single analysis pass."""
    modules = build_dependency_graph(package_path, package_name)
    cycles = find_cycles(modules)
    porting_order = compute_porting_order(modules)

    if md_path:
        generate_markdown_report(modules, cycles, porting_order, md_path, stable)
    if json_path:
        generate_json_report(modules, cycles, porting_order, json_path, stable)

    print(f"Analyzed {len(modules)} modules, {len(cycles)} cycles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
