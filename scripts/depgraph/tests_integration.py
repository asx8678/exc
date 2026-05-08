#!/usr/bin/env python3
"""Integration tests: temp packages, symbol imports, stability/reproducibility."""

from __future__ import annotations

import tempfile
from pathlib import Path

from .analyzer import build_dependency_graph
from .cycles import find_cycles
from .porting import compute_porting_order
from .reports import format_timestamp, generate_json_report, generate_markdown_report

# ── Temp package factory ────────────────────────────────────────────


def _make_temp_pkg(tmpdir: Path) -> Path:
    """Create a temp package with __init__.py relative imports."""
    pkg = tmpdir / "my_pkg"
    pkg.mkdir()

    # my_pkg/__init__.py: from . import leaf; from .sub import Sub
    (pkg / "__init__.py").write_text("from . import leaf\nfrom . import sub\n")

    # my_pkg/leaf.py: standalone module
    (pkg / "leaf.py").write_text("VALUE = 42\n")

    # my_pkg/sub/__init__.py: from .leaf import Leaf; from .. import leaf
    sub = pkg / "sub"
    sub.mkdir()
    (sub / "__init__.py").write_text(
        "from .leaf import Leaf\nfrom .. import leaf as parent_leaf\n"
    )

    # my_pkg/sub/leaf.py
    (sub / "leaf.py").write_text("class Leaf: pass\n")

    # my_pkg/sub/sibling.py: from .. import leaf
    (sub / "sibling.py").write_text("from .. import leaf as top_leaf\n")

    return pkg


# ── Integration tests ───────────────────────────────────────────────


def test_init_relative_imports() -> bool:
    """Test that __init__.py relative imports resolve correctly via build_dependency_graph."""
    with tempfile.TemporaryDirectory() as tmpdir:
        pkg = _make_temp_pkg(Path(tmpdir))
        modules = build_dependency_graph(pkg, "my_pkg")

        # my_pkg.__init__ should import my_pkg.leaf and my_pkg.sub
        init = modules.get("my_pkg")
        if not init:
            print("FAIL: my_pkg not found in modules")
            return False

        expected_imports = {"my_pkg.leaf", "my_pkg.sub"}
        if init.imports != expected_imports:
            print(f"FAIL: my_pkg imports = {init.imports}, expected {expected_imports}")
            return False

        # my_pkg.sub.__init__ should import my_pkg.sub.leaf and my_pkg.leaf
        sub_init = modules.get("my_pkg.sub")
        if not sub_init:
            print("FAIL: my_pkg.sub not found")
            return False

        expected_sub_imports = {"my_pkg.sub.leaf", "my_pkg.leaf"}
        if sub_init.imports != expected_sub_imports:
            print(
                f"FAIL: my_pkg.sub imports = {sub_init.imports}, expected {expected_sub_imports}"
            )
            return False

        # my_pkg.sub.sibling should import my_pkg.leaf (not my_pkg.sub.leaf or other)
        sibling = modules.get("my_pkg.sub.sibling")
        if not sibling:
            print("FAIL: my_pkg.sub.sibling not found")
            return False

        if "my_pkg.leaf" not in sibling.imports:
            print(f"FAIL: sibling imports = {sibling.imports}, expected my_pkg.leaf")
            return False

        print("PASS: __init__.py relative imports resolve correctly")
        return True


def test_from_dot_import_leaf() -> bool:
    """Test that 'from . import leaf' in __init__.py counts pkg.sub.leaf."""
    with tempfile.TemporaryDirectory() as tmpdir:
        pkg = _make_temp_pkg(Path(tmpdir))
        modules = build_dependency_graph(pkg, "my_pkg")

        sub_init = modules.get("my_pkg.sub")
        if not sub_init:
            print("FAIL: my_pkg.sub not found")
            return False

        # from .leaf import Leaf → dep on my_pkg.sub.leaf (NOT my_pkg.sub.leaf.Leaf)
        if "my_pkg.sub.leaf" not in sub_init.imports:
            print(f"FAIL: missing my_pkg.sub.leaf dep, got: {sub_init.imports}")
            return False

        # Ensure no class-level deps leaked
        for imp in sub_init.imports:
            if imp.endswith(".Leaf"):
                print(f"FAIL: class-level dep leaked: {imp}")
                return False

        print("PASS: 'from . import leaf' / 'from .leaf import X' correct")
        return True


def test_symbols_not_counted() -> bool:
    """Test that imported classes/functions are NOT counted as module deps."""
    with tempfile.TemporaryDirectory() as tmpdir:
        pkg_dir = Path(tmpdir) / "sym_pkg"
        pkg_dir.mkdir()

        (pkg_dir / "__init__.py").write_text("")
        (pkg_dir / "models.py").write_text("class AskUserQuestionInput: pass\n")
        (pkg_dir / "consumer.py").write_text(
            "from .models import AskUserQuestionInput\n"
        )

        modules = build_dependency_graph(pkg_dir, "sym_pkg")
        consumer = modules.get("sym_pkg.consumer")
        if not consumer:
            print("FAIL: sym_pkg.consumer not found")
            return False

        # Should depend on sym_pkg.models, NOT sym_pkg.models.AskUserQuestionInput
        if "sym_pkg.models.AskUserQuestionInput" in consumer.imports:
            print(f"FAIL: class-level dep in imports: {consumer.imports}")
            return False

        if "sym_pkg.models" not in consumer.imports:
            print(f"FAIL: missing module-level dep, got: {consumer.imports}")
            return False

        print("PASS: imported symbols not counted as module deps")
        return True


def test_longest_module_match_in_pipeline() -> bool:
    """Test that longest-module matching works end-to-end in build_dependency_graph."""
    with tempfile.TemporaryDirectory() as tmpdir:
        pkg_dir = Path(tmpdir) / "long_pkg"
        pkg_dir.mkdir()

        (pkg_dir / "__init__.py").write_text("")
        (pkg_dir / "tools.py").write_text("pass\n")
        (pkg_dir / "tools_file_ops.py").write_text("pass\n")
        # consumer imports long_pkg.tools.file_ops (doesn't exist as module),
        # should match long_pkg.tools (parent), not add a phantom dep
        (pkg_dir / "consumer.py").write_text("from long_pkg.tools import nonexistent\n")

        modules = build_dependency_graph(pkg_dir, "long_pkg")
        consumer = modules.get("long_pkg.consumer")
        if not consumer:
            print("FAIL: long_pkg.consumer not found")
            return False

        # Should match long_pkg.tools, not a non-existent submodule
        for imp in consumer.imports:
            if imp not in modules:
                print(f"FAIL: import '{imp}' doesn't match any known module")
                return False

        if "long_pkg.tools" not in consumer.imports:
            print(f"FAIL: missing tools dep, got: {consumer.imports}")
            return False

        print("PASS: longest-module matching in pipeline")
        return True


# ── Stability / reproducibility tests ───────────────────────────────


def test_stable_timestamp() -> bool:
    """Test stable timestamp generation."""
    ts1 = format_timestamp(stable=True)
    ts2 = format_timestamp(stable=True)
    if ts1 != ts2 or "2026-01-01" not in ts1:
        print(f"FAIL: Stable timestamps: {ts1} vs {ts2}")
        return False
    print(f"PASS: Stable timestamp: {ts1}")
    return True


def test_reproducible_reports() -> bool:
    """Test that stable reports are byte-identical across runs."""
    with tempfile.TemporaryDirectory() as tmpdir:
        pkg = _make_temp_pkg(Path(tmpdir))
        modules = build_dependency_graph(pkg, "my_pkg")
        cycles = find_cycles(modules)
        porting = compute_porting_order(modules)

        md1 = generate_markdown_report(modules, cycles, porting, stable=True)
        md2 = generate_markdown_report(modules, cycles, porting, stable=True)

        if md1 != md2:
            print("FAIL: Markdown reports differ between runs")
            return False

        json1 = generate_json_report(modules, cycles, porting, stable=True)
        json2 = generate_json_report(modules, cycles, porting, stable=True)

        if json1 != json2:
            print("FAIL: JSON reports differ between runs")
            return False

        print("PASS: Reports are reproducible")
        return True
