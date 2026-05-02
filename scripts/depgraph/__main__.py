#!/usr/bin/env python3
"""CLI entry point for dependency graph generator."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .analyzer import build_dependency_graph
from .cycles import find_cycles
from .porting import compute_porting_order
from .reports import generate_json_report, generate_markdown_report
from .tests import run_self_tests


def main() -> int:
    """Main entry point."""
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


if __name__ == "__main__":
    sys.exit(main())
