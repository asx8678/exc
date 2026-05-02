"""Gitignore-aware path filtering, ported from plandex's approach.

Walks up from a starting directory to find all applicable .gitignore
files and composes them into a :class:`pathspec.PathSpec` that can
answer ``is_ignored(path) -> bool``.

Currently supports only .gitignore (not .plandexignore / .cpignore).

Usage:
    matcher = GitignoreMatcher.for_directory("/my/repo")
    if matcher.is_ignored("build/artifact.o"):
        skip(...)

The matcher is cached via :func:`functools.lru_cache` so repeated
queries on the same directory are O(1).
"""

import functools
import logging
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class GitignoreMatcher:
    """Holds a compiled pathspec and the directory it's rooted at."""

    root: Path
    _spec: object  # pathspec.PathSpec (not typed here to avoid import at module scope)

    def is_ignored(self, path: str | Path) -> bool:
        """Return True if ``path`` matches any gitignore pattern in this spec.

        ``path`` may be absolute or relative. If absolute, it must be a
        descendant of ``self.root``; otherwise returns False (not ignored).
        """
        try:
            import pathspec  # noqa: F401
        except ImportError:
            return False  # pathspec not installed -> fail open

        p = Path(path)
        if p.is_absolute():
            # Resolve to handle symlinks (e.g., macOS /var -> /private/var)
            p = p.resolve()
            try:
                rel = p.relative_to(self.root)
            except ValueError:
                return False  # outside root
        else:
            # For relative paths, use as-is without resolving
            rel = p

        return self._spec.match_file(str(rel))

    @classmethod
    def for_directory(cls, directory: str | Path) -> "GitignoreMatcher | None":
        """Build a matcher for ``directory`` by collecting all .gitignore files.

        Walks from the given directory up to the filesystem root, reading
        every .gitignore file encountered. Returns None if pathspec is
        unavailable.
        """
        try:
            import pathspec
        except ImportError:
            logger.debug("pathspec not installed; gitignore filtering disabled")
            return None

        directory = Path(directory).resolve()
        lines: list[str] = []
        # Walk up from directory to root
        current = directory
        while True:
            gitignore = current / ".gitignore"
            if gitignore.exists():
                try:
                    lines.extend(
                        gitignore.read_text(
                            encoding="utf-8", errors="ignore"
                        ).splitlines()
                    )
                except OSError:
                    pass
            if current.parent == current:
                break
            current = current.parent

        if not lines:
            return None

        spec = pathspec.PathSpec.from_lines("gitignore", lines)
        return cls(root=directory, _spec=spec)


@functools.lru_cache(maxsize=128)
def _cached_matcher_for(directory: str) -> GitignoreMatcher | None:
    """LRU-cached wrapper around :meth:`GitignoreMatcher.for_directory`."""
    return GitignoreMatcher.for_directory(directory)


def is_gitignored(path: str | Path, base_dir: str | Path) -> bool:
    """Top-level helper: returns True if ``path`` is gitignored relative to ``base_dir``.

    Falls back to False on any error (unavailable pathspec, missing files, etc.).
    """
    try:
        matcher = _cached_matcher_for(str(Path(base_dir).resolve()))
        if matcher is None:
            return False
        return matcher.is_ignored(path)
    except Exception as e:
        logger.debug("is_gitignored failed: %s", e)
        return False


def clear_cache() -> None:
    """Clear the LRU cache (useful for tests)."""
    _cached_matcher_for.cache_clear()
