"""Core types for the capability-based config discovery system.

Inspired by oh-my-pi's capability registry pattern.
"""

from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable


@dataclass
class LoadContext:
    """Context passed to every provider loader."""

    cwd: str  # project root
    home: str  # user home directory

    def __hash__(self) -> int:
        return hash((self.cwd, self.home))

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, LoadContext):
            return NotImplemented
        return self.cwd == other.cwd and self.home == other.home


@dataclass
class SourceMeta:
    """Source metadata attached to every loaded item."""

    provider: str  # provider ID
    provider_name: str  # display name
    path: str  # source file path
    level: str  # "user", "project", or "builtin"


@dataclass
class LoadResult:
    """Result from a provider's load function."""

    items: list[Any]
    warnings: list[str] = field(default_factory=list)


@runtime_checkable
class Provider(Protocol):
    """Protocol for capability providers.

    Providers supply items for a specific capability. They are
    sorted by priority (highest first), and higher-priority providers
    shadow same-key items from lower-priority ones.
    """

    id: str
    display_name: str
    description: str
    priority: int  # higher = checked first

    def load(self, ctx: LoadContext) -> LoadResult:
        """Load items for this capability.

        May be sync or async.  The registry detects and awaits coroutines.
        """
        ...


@dataclass
class Capability:
    """A named capability with registered providers."""

    id: str
    display_name: str
    description: str
    key_fn: Callable[[Any], str | None]  # extract dedup key; None means never dedup
    providers: list[Provider] = field(default_factory=list)


@dataclass
class CapabilityResult:
    """Result of loading a capability from all providers."""

    items: list[Any]  # deduplicated, priority ordered
    all_items: list[Any]  # including shadowed duplicates
    warnings: list[str]
    contributing_providers: list[str]  # provider IDs that contributed items
