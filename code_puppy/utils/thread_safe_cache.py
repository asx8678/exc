"""Thread-safe cache decorators for Python 3.14t free-threading compatibility."""

import functools
import threading
from typing import Callable, ParamSpec, TypeVar

P = ParamSpec("P")
R = TypeVar("R")


def thread_safe_lru_cache(maxsize: int = 128, typed: bool = False):
    """Thread-safe version of functools.lru_cache for Python 3.14t free-threading.

    Under Python 3.14t (free-threading / no GIL), functools.lru_cache is not
    thread-safe as its internal dict can be corrupted by concurrent access.
    This wrapper adds a threading.Lock around cache operations.
    """

    def decorator(func: Callable[P, R]) -> Callable[P, R]:
        cached = functools.lru_cache(maxsize=maxsize, typed=typed)(func)
        lock = threading.RLock()

        @functools.wraps(func)
        def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            with lock:
                return cached(*args, **kwargs)

        def _cache_info():
            with lock:
                return cached.cache_info()

        def _cache_clear():
            with lock:
                cached.cache_clear()

        wrapper.cache_info = _cache_info
        wrapper.cache_clear = _cache_clear
        return wrapper

    return decorator


def thread_safe_cache(func: Callable[P, R]) -> Callable[P, R]:
    """Thread-safe version of functools.cache (unlimited size) for Python 3.14t."""
    return thread_safe_lru_cache(maxsize=None)(func)
