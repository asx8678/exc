#!/usr/bin/env python3
"""Data models for dependency graph analysis."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class ModuleInfo:
    """Information about a Python module."""

    name: str  # Full dotted path (e.g., code_puppy.agents.base_agent)
    file_path: Path
    imports: set[str] = field(default_factory=set)  # Internal imports only
    imported_by: set[str] = field(default_factory=set)  # Reverse dependencies
    external_imports: set[str] = field(default_factory=set)  # 3rd party packages
    stdlib_imports: set[str] = field(default_factory=set)  # Standard library
    lines_of_code: int = 0

    @property
    def fan_in(self) -> int:
        """Number of modules that import this module."""
        return len(self.imported_by)

    @property
    def fan_out(self) -> int:
        """Number of internal modules this module imports."""
        return len(self.imports)

    @property
    def is_leaf(self) -> bool:
        """True if module has no internal dependencies."""
        return len(self.imports) == 0

    @property
    def is_hub(self, threshold: int = 10) -> bool:
        """True if module is imported by many others."""
        return self.fan_in >= threshold

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "name": self.name,
            "file_path": str(self.file_path),
            "fan_in": self.fan_in,
            "fan_out": self.fan_out,
            "imports": sorted(self.imports),
            "imported_by": sorted(self.imported_by),
            "external_imports": sorted(self.external_imports),
            "stdlib_imports": sorted(self.stdlib_imports),
            "lines_of_code": self.lines_of_code,
            "is_leaf": self.is_leaf,
            "is_hub": self.is_hub,
        }
