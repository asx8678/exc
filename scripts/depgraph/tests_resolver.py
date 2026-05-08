#!/usr/bin/env python3
"""Unit tests: resolver, longest-module matching, module name calculation."""

from __future__ import annotations

from pathlib import Path

from .analyzer import calculate_module_name
from .resolver import find_matching_module, resolve_relative_import

# ── Relative import resolution ──────────────────────────────────────


def test_resolve_relative_import() -> bool:
    """Test relative import resolution with is_package semantics."""
    tests = [
        # Regular module: current_module's package context = parent
        ("code_puppy.tools.file_ops", 1, "utils", False, "code_puppy.tools.utils"),
        ("code_puppy.tools.file_ops", 2, "utils", False, "code_puppy.utils"),
        ("code_puppy.tools.file_ops", 1, None, False, "code_puppy.tools"),
        ("code_puppy.tools.file_ops", 2, None, False, "code_puppy"),
        # Package __init__.py: package context = self
        ("code_puppy.sub", 1, "leaf", True, "code_puppy.sub.leaf"),
        ("code_puppy.sub", 1, None, True, "code_puppy.sub"),
        ("code_puppy.sub", 2, "sibling", True, "code_puppy.sibling"),
        ("code_puppy.sub", 2, None, True, "code_puppy"),
        # Edge cases
        ("code_puppy", 1, "config", True, "code_puppy.config"),
        ("code_puppy", 2, None, True, None),  # Can't go above root
        ("code_puppy", 1, None, True, "code_puppy"),
        # Triple-dot import from nested
        ("code_puppy.cmd.mcp.stop", 3, "agents", False, "code_puppy.agents"),
    ]

    all_passed = True
    for current, level, module, is_pkg, expected in tests:
        result = resolve_relative_import(current, level, module, is_package=is_pkg)
        if result != expected:
            print(
                f"FAIL: resolve({current!r}, {level}, {module!r}, is_package={is_pkg})"
            )
            print(f"  Expected: {expected!r}")
            print(f"  Got:      {result!r}")
            all_passed = False
        else:
            print(
                f"PASS: resolve({current}, {level}, {module}, pkg={is_pkg}) = {result}"
            )

    return all_passed


def test_longest_module_matching() -> bool:
    """Test longest-module matching for imports."""
    modules = {
        "code_puppy",
        "code_puppy.tools",
        "code_puppy.tools.file_ops",
        "code_puppy.utils",
    }

    tests = [
        ("code_puppy.tools.file_ops", "code_puppy.tools.file_ops"),
        ("code_puppy.tools.file_ops.read", "code_puppy.tools.file_ops"),
        ("code_puppy.tools.utils", "code_puppy.tools"),
        ("code_puppy.config", "code_puppy"),
        ("code_puppy.utils.helper", "code_puppy.utils"),
        ("nonexistent", None),
        # Symbol import should match the module, not create a new dep
        ("code_puppy.tools.ask_user_question.models", "code_puppy.tools"),
    ]

    all_passed = True
    for import_name, expected in tests:
        result = find_matching_module(import_name, modules)
        if result != expected:
            print(f"FAIL: find_matching_module({import_name!r})")
            print(f"  Expected: {expected!r}")
            print(f"  Got:      {result!r}")
            all_passed = False
        else:
            print(f"PASS: longest match for {import_name} = {result}")

    return all_passed


# ── Module name calculation ─────────────────────────────────────────


def test_module_name_calculation() -> bool:
    """Test module name calculation from file paths."""
    tests = [
        (
            Path("/pkg/code_puppy/__init__.py"),
            Path("/pkg/code_puppy"),
            "code_puppy",
            "code_puppy",
        ),
        (
            Path("/pkg/code_puppy/tools.py"),
            Path("/pkg/code_puppy"),
            "code_puppy",
            "code_puppy.tools",
        ),
        (
            Path("/pkg/code_puppy/utils/file.py"),
            Path("/pkg/code_puppy"),
            "code_puppy",
            "code_puppy.utils.file",
        ),
        (
            Path("/pkg/code_puppy/agents/__init__.py"),
            Path("/pkg/code_puppy"),
            "code_puppy",
            "code_puppy.agents",
        ),
    ]

    all_passed = True
    for file_path, package_root, package_name, expected in tests:
        result = calculate_module_name(file_path, package_root, package_name)
        if result != expected:
            print(
                f"FAIL: calculate_module_name({file_path}, {package_root}, {package_name})"
            )
            print(f"  Expected: {expected!r}")
            print(f"  Got:      {result!r}")
            all_passed = False
        else:
            print(f"PASS: {file_path.name} -> {result}")

    return all_passed
