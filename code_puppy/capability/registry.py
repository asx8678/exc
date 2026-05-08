"""Capability registry: define, register, and load capability providers.

Callers ask for ``load_capability("mcps")`` and get back a unified
``CapabilityResult`` assembled from every registered provider.

Thread-safety guarantees
------------------------
* Registry mutations (``define_capability``, ``register_provider``) are
  protected by ``_registry_lock``.
* The result cache (``_cache``) is also protected by ``_registry_lock``.
* Concurrent *reads* (``load_capability``) acquire the lock only around
  the final cache write; the actual provider loading happens outside the
  lock so that async providers don't block other threads.

Async support
-------------
Provider ``load()`` methods may be sync *or* async.  The registry
detects coroutines via ``inspect.iscoroutine`` and awaits them when
called from an async context.  When called from a sync context (the
non-async ``load_capability_sync`` helper), a new event-loop run is
used to drive the coroutine.
"""

import inspect
import logging
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .types import Capability, CapabilityResult, LoadContext, LoadResult, Provider

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

_capabilities: dict[str, Capability] = {}
_cache: dict[tuple[str, LoadContext | None], CapabilityResult] = {}
_registry_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Public API – defining capabilities
# ---------------------------------------------------------------------------


def define_capability(
    id: str,
    display_name: str,
    description: str,
    key_fn: Callable[[Any], str | None] = lambda _: None,
) -> Capability:
    """Define a new capability and add it to the registry.

    If a capability with the same *id* already exists it is returned
    unchanged (idempotent).

    Args:
        id: Unique capability identifier (e.g. ``"mcps"``).
        display_name: Human-readable name.
        description: What this capability represents.
        key_fn: Called with each item to extract a deduplication key.
            Returning ``None`` means the item is never deduplicated.

    Returns:
        The :class:`Capability` instance (new or existing).
    """
    with _registry_lock:
        if id in _capabilities:
            return _capabilities[id]
        cap = Capability(
            id=id,
            display_name=display_name,
            description=description,
            key_fn=key_fn,
        )
        _capabilities[id] = cap
        logger.debug("Defined capability: %s", id)
        return cap


# ---------------------------------------------------------------------------
# Public API – registering providers
# ---------------------------------------------------------------------------


def register_provider(capability_id: str, provider: Provider) -> None:
    """Register a provider for a capability.

    Providers are inserted in descending priority order so that the
    first item in ``capability.providers`` always has the highest
    priority.

    Args:
        capability_id: The capability to attach this provider to.
        provider: Any object implementing the :class:`~types.Provider`
            protocol.

    Raises:
        KeyError: If *capability_id* has not been defined yet.
    """
    with _registry_lock:
        if capability_id not in _capabilities:
            raise KeyError(
                f"Capability '{capability_id}' is not defined. "
                "Call define_capability() first."
            )
        cap = _capabilities[capability_id]

        # Insert maintaining descending priority order
        inserted = False
        for i, existing in enumerate(cap.providers):
            if provider.priority > existing.priority:
                cap.providers.insert(i, provider)
                inserted = True
                break
        if not inserted:
            cap.providers.append(provider)

        # Invalidate any cached result for this capability
        keys_to_remove = [k for k in _cache if k[0] == capability_id]
        for k in keys_to_remove:
            del _cache[k]

        logger.debug(
            "Registered provider '%s' for capability '%s' (priority=%d)",
            provider.id,
            capability_id,
            provider.priority,
        )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


async def _call_provider(provider: Provider, ctx: LoadContext) -> LoadResult:
    """Call provider.load(), awaiting the result if it is a coroutine."""
    result = provider.load(ctx)
    if inspect.iscoroutine(result):
        result = await result
    return result


def _default_ctx() -> LoadContext:
    """Build a default :class:`LoadContext` from the process environment."""

    return LoadContext(
        cwd=str(Path.cwd()),
        home=str(Path.home()),
    )


def _build_result(
    cap: Capability,
    provider_results: list[tuple[Provider, LoadResult]],
    include_ids: set[str] | None,
    exclude_ids: set[str] | None,
) -> CapabilityResult:
    """Assemble a :class:`CapabilityResult` from raw provider outputs.

    Deduplication strategy:
    * Iterate providers in priority order (highest first).
    * For each item, compute ``key = cap.key_fn(item)``.
    * If *key* is ``None`` → never deduplicate; always include.
    * If *key* was already seen → shadow (include in ``all_items`` but
      not in ``items``).
    * Higher-priority provider wins on key conflicts.
    """
    seen_keys: set[str] = set()
    items: list[Any] = []
    all_items: list[Any] = []
    warnings: list[str] = []
    contributing_providers: list[str] = []

    for provider, load_result in provider_results:
        # Apply include/exclude filters
        if include_ids is not None and provider.id not in include_ids:
            continue
        if exclude_ids is not None and provider.id in exclude_ids:
            continue

        if load_result.warnings:
            warnings.extend(load_result.warnings)

        provider_contributed = False
        for item in load_result.items:
            all_items.append(item)
            key = cap.key_fn(item)
            if key is None:
                # No dedup – always include
                items.append(item)
                provider_contributed = True
            elif key not in seen_keys:
                seen_keys.add(key)
                items.append(item)
                provider_contributed = True
            # else: shadowed by higher-priority provider

        if provider_contributed and provider.id not in contributing_providers:
            contributing_providers.append(provider.id)

    return CapabilityResult(
        items=items,
        all_items=all_items,
        warnings=warnings,
        contributing_providers=contributing_providers,
    )


# ---------------------------------------------------------------------------
# Public API – loading capabilities
# ---------------------------------------------------------------------------


async def load_capability(
    capability_id: str,
    ctx: LoadContext | None = None,
    providers: list[str] | None = None,
    exclude_providers: list[str] | None = None,
) -> CapabilityResult:
    """Load items from all providers registered for *capability_id*.

    Results are cached per *(capability_id, ctx)* until
    :func:`invalidate_cache` is called.

    Args:
        capability_id: Which capability to load.
        ctx: Optional load context.  Defaults to current cwd / home.
        providers: If given, only these provider IDs are used.
        exclude_providers: Provider IDs to skip.

    Returns:
        A :class:`CapabilityResult` with deduplicated items.

    Raises:
        KeyError: If *capability_id* has not been defined.
    """
    with _registry_lock:
        if capability_id not in _capabilities:
            raise KeyError(f"Unknown capability: '{capability_id}'")

        cap = _capabilities[capability_id]
        # Snapshot providers under lock so iteration is safe
        provider_snapshot = list(cap.providers)

    if ctx is None:
        ctx = _default_ctx()

    # Check cache – only when no provider filtering is requested, because
    # filtered results depend on the filter arguments too.
    cache_key = (capability_id, ctx)
    if providers is None and exclude_providers is None:
        with _registry_lock:
            cached = _cache.get(cache_key)
        if cached is not None:
            logger.debug("Cache hit for capability '%s'", capability_id)
            return cached

    # Load from all providers (outside the lock)
    include_ids = set(providers) if providers is not None else None
    exclude_ids = set(exclude_providers) if exclude_providers is not None else None

    provider_results: list[tuple[Provider, LoadResult]] = []
    for provider in provider_snapshot:
        try:
            load_result = await _call_provider(provider, ctx)
            if not isinstance(load_result, LoadResult):
                # Wrap bare list for convenience
                if isinstance(load_result, list):
                    load_result = LoadResult(items=load_result)
                else:
                    logger.warning(
                        "Provider '%s' returned unexpected type %s; skipping",
                        provider.id,
                        type(load_result).__name__,
                    )
                    continue
            provider_results.append((provider, load_result))
        except Exception as exc:
            logger.warning(
                "Provider '%s' raised an error while loading capability '%s': %s",
                provider.id,
                capability_id,
                exc,
            )

    result = _build_result(cap, provider_results, include_ids, exclude_ids)

    # Store in cache (only unfiltered results)
    if providers is None and exclude_providers is None:
        with _registry_lock:
            _cache[cache_key] = result

    return result


# ---------------------------------------------------------------------------
# Introspection helpers
# ---------------------------------------------------------------------------


def list_capabilities() -> list[dict[str, Any]]:
    """Return a summary list of all registered capabilities.

    Each entry is a dict with keys: ``id``, ``display_name``,
    ``description``, ``provider_count``, and ``providers``.
    """
    with _registry_lock:
        caps = list(_capabilities.values())

    return [
        {
            "id": cap.id,
            "display_name": cap.display_name,
            "description": cap.description,
            "provider_count": len(cap.providers),
            "providers": [
                {
                    "id": p.id,
                    "display_name": p.display_name,
                    "priority": p.priority,
                }
                for p in cap.providers
            ],
        }
        for cap in caps
    ]


def get_capability_info(capability_id: str) -> dict[str, Any] | None:
    """Return detailed info about a single capability, or ``None`` if unknown."""
    with _registry_lock:
        cap = _capabilities.get(capability_id)

    if cap is None:
        return None

    return {
        "id": cap.id,
        "display_name": cap.display_name,
        "description": cap.description,
        "provider_count": len(cap.providers),
        "providers": [
            {
                "id": p.id,
                "display_name": p.display_name,
                "description": p.description,
                "priority": p.priority,
            }
            for p in cap.providers
        ],
    }


# ---------------------------------------------------------------------------
# Cache management
# ---------------------------------------------------------------------------


def invalidate_cache() -> None:
    """Clear all cached capability results.

    Call this whenever underlying configuration files change, e.g. after
    the user edits their MCP config or adds a new model.
    """
    with _registry_lock:
        _cache.clear()
    logger.debug("Capability result cache invalidated")
