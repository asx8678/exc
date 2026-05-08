"""Capability-based config discovery system.

Inspired by oh-my-pi's capability registry pattern.  This system
inverts control: instead of callers knowing about specific paths,
they ask for ``load_capability("mcps")`` and get back a unified
list from all registered providers.

Quick-start
-----------
1. Define a capability (or reuse a built-in one)::

       from code_puppy.capability import define_capability
       cap = define_capability("my_cap", "My Cap", "A custom capability")

2. Register a provider::

       from code_puppy.capability import register_provider
       from code_puppy.capability.types import LoadContext, LoadResult

       class MyProvider:
           id = "my_provider"
           display_name = "My Provider"
           description = "Loads my stuff"
           priority = 100

           def load(self, ctx: LoadContext) -> LoadResult:
               return LoadResult(items=[{"name": "thing1"}, {"name": "thing2"}])

       register_provider("my_cap", MyProvider())

3. Load results (async)::

       from code_puppy.capability import load_capability
       result = await load_capability("my_cap")
       print(result.items)

Built-in capabilities (``"models"``, ``"rules"``, ``"mcps"``) are
registered automatically when this package is imported.
"""

# Ensure built-in capabilities are defined on import
from . import builtin_providers as _builtin_providers  # noqa: F401
from .registry import (
    define_capability,
    get_capability_info,
    invalidate_cache,
    list_capabilities,
    load_capability,
    register_provider,
)
from .types import (
    Capability,
    CapabilityResult,
    LoadContext,
    LoadResult,
    Provider,
    SourceMeta,
)

__all__ = [
    # Registry functions
    "define_capability",
    "register_provider",
    "load_capability",
    "list_capabilities",
    "get_capability_info",
    "invalidate_cache",
    # Types
    "Capability",
    "Provider",
    "LoadContext",
    "LoadResult",
    "CapabilityResult",
    "SourceMeta",
]
