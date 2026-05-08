"""Skill discovery - scans directories for valid skills with layered precedence.

Skills are loaded in precedence order (lowest to highest):
  1. user-level: ~/.code_puppy/skills
  2. project config: ./.code_puppy/skills
  3. project workspace: ./skills (highest priority)

When skills share the same name, higher-precedence sources override lower ones.
"""

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from code_puppy.config_paths import resolve_path
from code_puppy.plugins.agent_skills.config import get_skill_directories

logger = logging.getLogger(__name__)

SourceLevel = Literal["builtin", "user", "project_config", "project"]


@dataclass
class SkillInfo:
    """Basic skill information from discovery."""

    name: str
    path: Path
    has_skill_md: bool
    source_level: SourceLevel = "project"


def get_default_skill_directories() -> list[Path]:
    """Return default directories to scan for skills.

    Returns:
        - ~/.code_puppy/skills (user skills)
        - ./.code_puppy/skills (project config skills)
        - ./skills (project skills)
    """
    return [
        resolve_path("skills"),
        Path.cwd() / ".code_puppy" / "skills",
        Path.cwd() / "skills",
    ]


def is_valid_skill_directory(path: Path) -> bool:
    """Check if a directory contains a valid SKILL.md file."""
    if not path.is_dir():
        return False
    return (path / "SKILL.md").is_file()


def _scan_directory(directory: Path, source_level: SourceLevel) -> list[SkillInfo]:
    """Scan a single directory for skills."""
    skills = []
    if not directory.exists() or not directory.is_dir():
        return skills

    for skill_dir in directory.iterdir():
        if not skill_dir.is_dir() or skill_dir.name.startswith("."):
            continue
        has_skill_md = is_valid_skill_directory(skill_dir)
        skills.append(
            SkillInfo(
                name=skill_dir.name,
                path=skill_dir,
                has_skill_md=has_skill_md,
                source_level=source_level,
            )
        )
    return skills


def discover_skills(directories: list[Path] | None = None) -> list[SkillInfo]:
    """Scan directories for valid skills with layered precedence.

    When called without arguments, loads from standard directories in
    precedence order (user → project_config → project). Higher-precedence
    sources override lower ones when skills share the same name.

    Args:
        directories: Explicit directories to scan (all treated as "project"
                     level). If None, uses standard precedence ordering.

    Returns:
        Deduplicated list of SkillInfo objects (one per name, highest
        precedence wins).
    """
    if directories is not None:
        # Explicit directories — all "project" level, use dict for dedup
        ordered_sources: list[tuple[Path, SourceLevel]] = [
            (d, "project") for d in directories
        ]
    else:
        # Standard precedence ordering: lowest to highest
        ordered_sources = [
            (resolve_path("skills"), "user"),
            (Path.cwd() / ".code_puppy" / "skills", "project_config"),
            (Path.cwd() / "skills", "project"),
        ]
        # Merge with any additional configured directories
        configured = [Path(d) for d in get_skill_directories()]
        seen_resolved = {p.resolve() for p, _ in ordered_sources}
        for d in configured:
            if d.resolve() not in seen_resolved:
                ordered_sources.append((d, "project"))
                seen_resolved.add(d.resolve())

    # Build deduplicated map: later sources override earlier ones by name
    skill_map: dict[str, SkillInfo] = {}

    for directory, source_level in ordered_sources:
        for skill in _scan_directory(directory, source_level):
            existing = skill_map.get(skill.name)
            if existing and existing.path.resolve() != skill.path.resolve():
                logger.warning(
                    'Skill "%s" from %s overrides %s (%s -> %s)',
                    skill.name,
                    skill.path,
                    existing.path,
                    existing.source_level,
                    source_level,
                )
            skill_map[skill.name] = skill

    discovered_skills = list(skill_map.values())

    logger.info(
        "Discovered %d skills (deduplicated by name) from %d sources",
        len(discovered_skills),
        len(ordered_sources),
    )
    return discovered_skills


def refresh_skill_cache() -> list[SkillInfo]:
    """Force re-discovery of all skills."""
    return discover_skills()
