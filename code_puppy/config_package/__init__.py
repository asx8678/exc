"""Configuration package for code-puppy (typed settings layer).

This package provides an ADDITIVE typed layer over the existing dict-based
config.py. Both APIs coexist; use whichever fits your call site better.

Migration is gradual and additive — we do NOT remove or modify the
existing config.py. Instead, this package provides a modern, typed alternative
for new code and refactors.

Submodules:
- env_helpers: Typed environment variable helpers with multi-name fallback
- models: Typed dataclasses (PuppyConfig) for structured settings
- loader: Loading logic with env var + puppy.cfg support + singleton cache

Quick Start:
    >>> from code_puppy.config_package import get_puppy_config
    >>> cfg = get_puppy_config()
    >>> print(cfg.default_model)
    >>> print(cfg.data_dir)

    >>> # Reload after config edits
    >>> cfg = reload_puppy_config()

    >>> # Convert to dict for legacy consumers
    >>> config_dict = cfg.to_dict()
"""

from ._resolvers import (
    resolve_bool,
    resolve_float,
    resolve_int,
    resolve_path,
    resolve_str,
)
from .env_helpers import env_bool, env_int, env_path, get_first_env
from .loader import (
    get_puppy_config,
    load_puppy_config,
    reload_puppy_config,
    reset_puppy_config_for_tests,
)
from .models import PuppyConfig

__all__ = [
    # env_helpers
    "get_first_env",
    "env_bool",
    "env_int",
    "env_path",
    # models
    "PuppyConfig",
    # loader
    "load_puppy_config",
    "get_puppy_config",
    "reload_puppy_config",
    "reset_puppy_config_for_tests",
    # resolvers
    "resolve_str",
    "resolve_bool",
    "resolve_int",
    "resolve_float",
    "resolve_path",
]
