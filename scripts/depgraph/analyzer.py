#!/usr/bin/env python3
"""AST-based Python module analyzer with proper import resolution."""

from __future__ import annotations

import ast
from pathlib import Path
from typing import TYPE_CHECKING

from .models import ModuleInfo
from .resolver import find_matching_module
from .stdlib_list import STDLIB_MODULES

if TYPE_CHECKING:
    pass


class ImportVisitor(ast.NodeVisitor):
    """AST visitor to collect import statements with proper resolution.

    Uses Python's import semantics for relative imports:
    - For __init__.py (is_package=True), the package context IS the module itself.
    - For regular modules (is_package=False), the package context is the parent.
    - Resolution uses rsplit like CPython's importlib._bootstrap._resolve_name.
    - Imported symbols/classes are NOT counted as module deps;
      only the containing module is recorded.
    """

    def __init__(
        self,
        package_name: str,
        current_module: str,
        is_package: bool = False,
    ):
        self.package_name = package_name
        self.current_module = current_module
        self.is_package = is_package
        self.internal_imports: set[str] = set()
        self.external_imports: set[str] = set()
        self.stdlib_imports: set[str] = set()

    @property
    def package_context(self) -> str:
        """The package context for relative import resolution.

        Matches Python's __package__ semantics:
        - For __init__.py: the package IS the module (e.g. pkg.sub)
        - For regular modules: the parent package (e.g. pkg.sub for pkg.sub.mod)
        """
        if self.is_package:
            return self.current_module
        parts = self.current_module.split(".")
        return ".".join(parts[:-1]) if len(parts) > 1 else self.current_module

    def _is_stdlib(self, name: str) -> bool:
        """Check if a module is from stdlib."""
        top_level = name.split(".")[0]
        return top_level in STDLIB_MODULES

    def _is_internal(self, name: str) -> bool:
        """Check if a module is from the target package."""
        return name.startswith(self.package_name + ".") or name == self.package_name

    def _resolve_relative(self, level: int, module: str | None) -> str | None:
        """Resolve a relative import using CPython's rsplit algorithm.

        Mirrors importlib._bootstrap._resolve_name:
          bits = package.rsplit('.', level - 1)
          base = bits[0]
          return f'{base}.{name}' if name else base
        """
        if level == 0:
            return module

        pkg = self.package_context
        bits = pkg.rsplit(".", level - 1)

        if len(bits) < level:
            # Would go above package root
            return None

        base = bits[0]
        if not base:
            return None

        if module:
            return f"{base}.{module}"
        return base

    def _add_import(self, full_name: str) -> None:
        """Add an import, classifying it appropriately."""
        if self._is_internal(full_name):
            self.internal_imports.add(full_name)
        elif self._is_stdlib(full_name):
            self.stdlib_imports.add(full_name)
        else:
            self.external_imports.add(full_name)

    def visit_Import(self, node: ast.Import) -> None:  # noqa: N802
        """Handle 'import x' statements."""
        for alias in node.names:
            name = alias.name
            if name:
                self._add_import(name)
        self.generic_visit(node)

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:  # noqa: N802
        """Handle 'from x import y' with Python-correct relative resolution.

        Key rules:
        - 'from .module import Symbol': record dep on module, NOT Symbol.
        - 'from . import leaf': record dep on current_package.leaf (submodule).
        - 'from pkg import sub': record dep on pkg.sub (potential submodule).
        - 'from pkg.module import Class': record dep on pkg.module only.
        Post-processing in build_dependency_graph validates against known modules.
        """
        if node.level > 0:
            # Relative import
            base_module = self._resolve_relative(node.level, node.module)
            if base_module is None:
                self.generic_visit(node)
                return

            if node.module is not None:
                # 'from .module import X' — dep is on base_module (which
                # already includes .module).  X is a symbol, not a module dep.
                # Skip self-imports (package importing from itself).
                if base_module != self.current_module:
                    self._add_import(base_module)
            # else: 'from . import x' — x is the actual dep;
            # base_module.x is added below.  If x turns out to be a
            # symbol rather than a submodule, post-processing collapses
            # it to the longest matching module (which IS base_module).

            for alias in node.names:
                if alias.name == "*":
                    continue
                if node.module is None:
                    # 'from . import x' — x is a submodule of the current package
                    full_name = f"{base_module}.{alias.name}"
                    self._add_import(full_name)
                # else: 'from .module import X' — X is a symbol, not a module dep.
                # The base_module already includes '.module' so the dep is captured.
        else:
            # Absolute import
            if node.module:
                # Skip self-import (e.g. from pkg import submodules)
                if node.module != self.current_module:
                    self._add_import(node.module)

                for alias in node.names:
                    if alias.name == "*":
                        continue
                    # 'from pkg import x' could be a submodule import;
                    # 'from pkg.module import Class' — Class is a symbol.
                    # Record as potential; post-processing validates.
                    full_name = f"{node.module}.{alias.name}"
                    self._add_import(full_name)

        self.generic_visit(node)


def calculate_module_name(
    file_path: Path, package_root: Path, package_name: str
) -> str | None:
    """Calculate the full module name from a file path."""
    try:
        relative_path = file_path.relative_to(package_root)
    except ValueError:
        return None

    parts = list(relative_path.parts)

    # Handle __init__.py
    if parts[-1] == "__init__.py":
        parts = parts[:-1]
    else:
        parts[-1] = parts[-1].replace(".py", "")

    if not parts:
        # This is the package root __init__.py
        return package_name

    return f"{package_name}.{'.'.join(parts)}"


def analyze_file(
    file_path: Path, package_root: Path, package_name: str
) -> ModuleInfo | None:
    """Analyze a single Python file and return its module info."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            source = f.read()
    except UnicodeDecodeError, IOError:
        return None

    try:
        tree = ast.parse(source)
    except SyntaxError:
        return None

    module_name = calculate_module_name(file_path, package_root, package_name)
    if module_name is None:
        return None

    is_package = file_path.name == "__init__.py"
    visitor = ImportVisitor(package_name, module_name, is_package=is_package)
    visitor.visit(tree)

    lines_of_code = len(source.splitlines())

    # Calculate relative path for cleaner output
    try:
        rel_path = file_path.relative_to(package_root.parent)
    except ValueError:
        rel_path = file_path

    return ModuleInfo(
        name=module_name,
        file_path=rel_path,
        imports=visitor.internal_imports,
        external_imports=visitor.external_imports,
        stdlib_imports=visitor.stdlib_imports,
        lines_of_code=lines_of_code,
    )


def _validate_imports(modules: dict[str, ModuleInfo]) -> None:
    """Validate and collapse imports against known module list.

    For each module's imports:
    1. Replace symbol-level imports with the longest matching actual module.
    2. Remove self-imports (a module listing itself as a dep).
    """
    known = set(modules.keys())

    for mod_name, mod_info in modules.items():
        validated: set[str] = set()
        for imp in mod_info.imports:
            match = find_matching_module(imp, known)
            if match and match != mod_name:
                validated.add(match)
        mod_info.imports = validated


def build_dependency_graph(
    package_path: Path, package_name: str = "code_puppy"
) -> dict[str, ModuleInfo]:
    """Build dependency graph for all modules in package."""
    modules: dict[str, ModuleInfo] = {}

    # Find all Python files
    for py_file in package_path.rglob("*.py"):
        # Skip common non-source directories
        if any(
            part.startswith(".")
            or part in {"__pycache__", "node_modules", "venv", ".venv"}
            for part in py_file.parts
        ):
            continue

        info = analyze_file(py_file, package_path, package_name)
        if info and info.name:
            modules[info.name] = info

    # Validate imports: collapse symbol-level to longest module match
    _validate_imports(modules)

    # Build reverse dependencies (imported_by) using longest-module matching
    for mod_name, mod_info in modules.items():
        for imp in mod_info.imports:
            match = find_matching_module(imp, set(modules.keys()))
            if match and match != mod_name:
                modules[match].imported_by.add(mod_name)

    return modules
