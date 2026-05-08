#!/usr/bin/env python3
"""Report generation for dependency graph analysis.

Keeps generated artifacts under 600 lines by using compact JSON
and summarized markdown (top-N sections, trimmed appendix).
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .models import ModuleInfo


def format_timestamp(stable: bool = False) -> str:
    """Generate timestamp for reports."""
    if stable:
        return "2026-01-01T00:00:00+00:00"
    return datetime.now(timezone.utc).isoformat()


def short_name(module_name: str) -> str:
    """Convert full module name to short display name."""
    if module_name.startswith("code_puppy."):
        return module_name[len("code_puppy.") :]
    return module_name


def generate_markdown_report(
    modules: dict[str, ModuleInfo],
    cycles: list[list[str]],
    porting_order: list[tuple[str, int]],
    output_path: Path | None = None,
    stable: bool = False,
) -> str:
    """Generate a markdown report of the dependency analysis."""
    lines: list[str] = []

    # Header
    lines.append("# Python Module Dependency Graph")
    lines.append("")
    lines.append(
        "> Generated for Python-to-Elixir migration planning. "
        "See [ADR-004](adr/ADR-004-python-to-elixir-migration-strategy.md)."
    )
    lines.append("")
    lines.append(f"**Generated**: {format_timestamp(stable)}")
    lines.append(f"**Total modules analyzed**: {len(modules)}")
    lines.append("")

    # Summary statistics
    total_loc = sum(m.lines_of_code for m in modules.values())
    leaf_count = sum(1 for m in modules.values() if m.is_leaf)
    hub_count = sum(1 for m in modules.values() if m.is_hub)

    lines.append("## Summary Statistics")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|--------|-------|")
    lines.append(f"| Total modules | {len(modules)} |")
    lines.append(f"| Total lines of code | {total_loc:,} |")
    lines.append(f"| Leaf modules (no internal deps) | {leaf_count} |")
    lines.append(f"| Hub modules (≥10 importers) | {hub_count} |")
    lines.append(f"| Import cycles detected | {len(cycles)} |")
    lines.append("")

    # High-fan-in hubs (top 15)
    lines.append("## High-Fan-In Hub Modules (High Blast Radius)")
    lines.append("")
    lines.append(
        "> These modules are imported by many others. "
        "Because dependents rely on their interface, they require "
        "compatibility facades and extra review during migration. "
        "Use the dependency-first porting order below rather than "
        "a blanket \u201cport last\u201d rule \u2014 the generated order "
        "already ensures dependencies precede their importers."
    )
    lines.append("")
    hubs = sorted(modules.values(), key=lambda m: (-m.fan_in, m.name))[:15]
    lines.append("| Module | Fan-In | Fan-Out | LOC |")
    lines.append("|--------|--------|---------|-----|")
    for hub in hubs:
        if hub.fan_in >= 5:
            lines.append(
                f"| `{short_name(hub.name)}` | {hub.fan_in} | {hub.fan_out} "
                f"| {hub.lines_of_code:,} |"
            )
    lines.append("")

    # Leaf candidates (top 20)
    lines.append("## Low-Dependency Leaf Candidates (Port FIRST)")
    lines.append("")
    lines.append(
        "> These modules have few or no internal dependencies. Safe to port early."
    )
    lines.append("")
    leaves = sorted(
        [m for m in modules.values() if m.is_leaf],
        key=lambda m: (m.fan_in, -m.lines_of_code, m.name),
    )[:20]
    lines.append("| Module | Fan-In | LOC | Notes |")
    lines.append("|--------|--------|-----|-------|")
    for leaf in leaves:
        sname = short_name(leaf.name)
        notes = "Pure leaf" if leaf.fan_in == 0 else f"Imported by {leaf.fan_in}"
        lines.append(
            f"| `{sname}` | {leaf.fan_in} | {leaf.lines_of_code:,} | {notes} |"
        )
    lines.append("")

    # Cycles (top 10)
    if cycles:
        lines.append("## Import Cycles Detected")
        lines.append("")
        lines.append(
            "> Cycles must be broken before porting (refactor to remove circular deps)."
        )
        lines.append("")
        for i, cycle in enumerate(cycles[:10], 1):
            cycle_str = " → ".join(short_name(c) for c in cycle)
            lines.append(f"{i}. `{cycle_str}`")
        if len(cycles) > 10:
            lines.append(f"\n... and {len(cycles) - 10} more cycles")
        lines.append("")
    else:
        lines.append("## Import Cycles")
        lines.append("")
        lines.append("No import cycles detected.")
        lines.append("")

    # Porting order
    lines.append("## Recommended Porting Order")
    lines.append("")
    lines.append(
        "> Ordered by topological level (dependencies first). "
        "For acyclic dependencies, if A imports B, B appears before A. "
        "Within an SCC (import cycle), members may be grouped/ordered "
        "arbitrarily, but outside-cycle dependencies still come first. "
        "Within each level, sorted by fan-in (lowest first)."
    )
    lines.append("")
    lines.append("| Phase | Modules | Criteria |")
    lines.append("|-------|---------|----------|")

    from collections import defaultdict

    depth_groups: dict[int, list[str]] = defaultdict(list)
    for mod, depth in porting_order:
        depth_groups[depth].append(mod)

    phase_names = ["Foundation", "Utilities", "Core Services", "Agents", "Integration"]
    for depth in sorted(depth_groups.keys()):
        phase_name = phase_names[min(depth, len(phase_names) - 1)]
        mods = depth_groups[depth][:5]
        mod_str = ", ".join(f"`{short_name(m)}`" for m in mods)
        if len(depth_groups[depth]) > 5:
            mod_str += f" (+{len(depth_groups[depth]) - 5} more)"
        lines.append(f"| {phase_name} (depth={depth}) | {mod_str} | Leaves → Hubs |")

    lines.append("")

    # Limitations
    lines.append("## Limitations")
    lines.append("")
    lines.append(
        "1. **Static analysis only**: Dynamic imports (importlib, __import__) not detected."
    )
    lines.append(
        "2. **Conditional imports**: Imports inside try/except or TYPE_CHECKING treated equally."
    )
    lines.append(
        "3. **Star imports**: `from x import *` dependencies may be incomplete."
    )
    lines.append(
        "4. **External dependencies**: Third-party package internals not analyzed."
    )
    lines.append(
        "5. **Runtime dependencies**: Plugin loading, config-driven imports not captured."
    )
    lines.append("")

    # Compact appendix: top-N table per depth, JSON has full data
    lines.append("## Appendix: Modules by Depth")
    lines.append("")
    lines.append(
        "Full module data in [python_dependency_graph.json](python_dependency_graph.json)."
    )
    lines.append("")

    top_n = 20
    for depth in sorted(depth_groups.keys()):
        group = depth_groups[depth]
        lines.append(f"### Depth {depth} ({len(group)} modules)")
        lines.append("")
        shown = sorted(group, key=lambda m: (-modules[m].fan_in, m))[:top_n]
        lines.append("| Module | Fan-In | Fan-Out | LOC |")
        lines.append("|--------|--------|---------|-----|")
        for mod_name in shown:
            m = modules[mod_name]
            lines.append(
                f"| `{short_name(mod_name)}` | {m.fan_in} | {m.fan_out} "
                f"| {m.lines_of_code:,} |"
            )
        if len(group) > top_n:
            lines.append(f"\n> ... {len(group) - top_n} more at this depth")
        lines.append("")

    content = "\n".join(lines)

    if output_path:
        output_path.write_text(content)
        print(f"Report written to: {output_path}")

    return content


def generate_json_report(
    modules: dict[str, ModuleInfo],
    cycles: list[list[str]],
    porting_order: list[tuple[str, int]],
    output_path: Path | None = None,
    stable: bool = False,
) -> str:
    """Generate a compact JSON report for programmatic use.

    Uses separators=(',',':') to keep file size manageable.
    """
    data = {
        "metadata": {
            "generated_at": format_timestamp(stable),
            "total_modules": len(modules),
            "package": "code_puppy",
        },
        "summary": {
            "total_lines_of_code": sum(m.lines_of_code for m in modules.values()),
            "leaf_count": sum(1 for m in modules.values() if m.is_leaf),
            "hub_count": sum(1 for m in modules.values() if m.is_hub),
            "cycle_count": len(cycles),
        },
        "hubs": [
            m.to_dict()
            for m in sorted(modules.values(), key=lambda x: (-x.fan_in, x.name))[:15]
            if m.fan_in >= 5
        ],
        "leaves": [
            m.to_dict()
            for m in sorted(
                [m for m in modules.values() if m.is_leaf],
                key=lambda x: (x.fan_in, -x.lines_of_code, x.name),
            )[:20]
        ],
        "cycles": cycles[:20],
        "porting_order": [
            {"module": mod, "depth": depth, "priority": i + 1}
            for i, (mod, depth) in enumerate(porting_order)
        ],
        "all_modules": {name: mod.to_dict() for name, mod in sorted(modules.items())},
    }

    # Compact JSON: no whitespace between separators
    content = json.dumps(data, separators=(",", ":"))

    if output_path:
        output_path.write_text(content)
        print(f"JSON report written to: {output_path}")

    return content
