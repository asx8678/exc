#!/usr/bin/env python3
"""Dependency graph generator package for Python-to-Elixir migration planning."""

from .analyzer import analyze_file, build_dependency_graph
from .cycles import find_cycles
from .models import ModuleInfo
from .porting import compute_porting_order
from .reports import generate_json_report, generate_markdown_report
from .resolver import find_matching_module, resolve_relative_import
from .tests import run_self_tests

__all__ = [
    "ModuleInfo",
    "analyze_file",
    "build_dependency_graph",
    "resolve_relative_import",
    "find_matching_module",
    "find_cycles",
    "compute_porting_order",
    "generate_markdown_report",
    "generate_json_report",
    "run_self_tests",
]
