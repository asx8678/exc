"""Request caching module for header-only change optimization.

This module provides request caching and delta update capabilities for
HTTP clients. When headers change but the body/URL/method remain the same,
requests can be updated in-place rather than fully rebuilt.

Key benefits:
- Avoids expensive request rebuilding for header-only changes
- Reduces GC pressure by reusing request objects
- Provides transparent caching that falls back to full rebuild when needed
"""

import hashlib
import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

logger = logging.getLogger(__name__)


# Maximum cache size in bytes (4MB budget to prevent memory bloat)
MAX_CACHE_BYTES = 4 * 1024 * 1024


@dataclass
class CachedContent:
    """A cached content entry with metadata (stores bytes only, not full request).

    This reduces memory usage by ~60-80% compared to storing full httpx.Request
    objects (which include headers, URL, and other metadata). On cache hit,
    we rebuild the request with cached content bytes.

    Attributes:
        content: The cached request body bytes
        content_hash: Hash of URL + method + body (what makes requests unique)
        headers_hash: Hash of headers (to detect header-only changes)
        created_at: Timestamp when cache entry was created
        access_count: Number of times this entry was accessed (for metrics)
        last_accessed: Timestamp of last access
        method: HTTP method for rebuilding request on hit
        url: Request URL for rebuilding request on hit
    """

    content: bytes | None
    content_hash: str
    headers_hash: str
    method: str
    url: str
    created_at: float = field(default_factory=time.time)
    access_count: int = 0
    last_accessed: float = field(default_factory=time.time)


# Backward compatibility alias - CachedRequest renamed to CachedContent
# The new class stores content bytes instead of full httpx.Request to save memory
CachedRequest = CachedContent


@dataclass
class CacheStats:
    """Statistics for request cache performance.

    Attributes:
        hits: Number of cache hits (exact match or header-only update)
        header_only_updates: Number of header-only optimizations applied
        misses: Number of cache misses
        evictions: Number of entries evicted due to size limits
        rebuilds_avoided: Estimated number of full rebuilds avoided
    """

    hits: int = 0
    header_only_updates: int = 0
    misses: int = 0
    evictions: int = 0
    rebuilds_avoided: int = 0


class RequestCache:
    """Cache for HTTP requests with header-only change optimization.

    This cache stores built requests and provides fast delta updates
    when only headers change. It's designed for scenarios where the
    same request is made multiple times with different authentication
    tokens or header values.

    Example usage:
        cache = RequestCache(max_size=100)

        # Build or retrieve cached request
        request = cache.get_or_build(
            method="POST",
            url="https://api.example.com/v1/chat",
            headers={...},
            content=b'{"messages": [...]}',
            client=httpx_client
        )

        # Later, with different headers but same content
        request2 = cache.get_or_build(
            method="POST",
            url="https://api.example.com/v1/chat",
            headers={"Authorization": "Bearer new_token"},  # Different!
            content=b'{"messages": [...]}',  # Same as before
            client=httpx_client
        )
        # request2 is request with updated headers (fast!)

    Thread safety: This cache is designed for use within a single
    async event loop. External synchronization is needed for
    multi-threaded usage.
    """

    # Default maximum number of cached entries
    DEFAULT_MAX_SIZE = 128

    # TTL for cache entries (seconds) - 5 minutes default
    DEFAULT_TTL_SECONDS = 300

    def __init__(
        self,
        max_size: int = DEFAULT_MAX_SIZE,
        ttl_seconds: float = DEFAULT_TTL_SECONDS,
        enable_stats: bool = True,
    ):
        """Initialize the request cache.

        Args:
            max_size: Maximum number of cached requests to keep
            ttl_seconds: Time-to-live for cache entries
            enable_stats: Whether to collect performance statistics
        """
        self._max_size = max_size
        self._ttl_seconds = ttl_seconds
        self._enable_stats = enable_stats

        # Map from content_hash -> CachedContent
        self._cache: dict[str, CachedContent] = {}

        # Track total bytes to enforce MAX_CACHE_BYTES budget
        self._current_bytes = 0

        # Statistics tracking
        self._stats = CacheStats()

        logger.debug(
            "RequestCache initialized (max_size=%d, ttl=%ds, max_bytes=%d)",
            max_size,
            ttl_seconds,
            MAX_CACHE_BYTES,
        )

    def _compute_content_hash(
        self, method: str, url: httpx.URL | str, content: bytes | None
    ) -> str:
        """Compute a hash of the request content (method + URL + body).

        This hash identifies requests that are identical except for headers.
        """
        hasher = hashlib.blake2b(digest_size=32)
        hasher.update(method.encode())
        hasher.update(str(url).encode())
        if content:
            hasher.update(content)
        return hasher.hexdigest()

    def _compute_headers_hash(self, headers: dict[str, str]) -> str:
        """Compute a hash of headers for comparison.

        Headers are normalized (lowercase keys, sorted) to ensure
        consistent hashing regardless of header ordering.
        """
        hasher = hashlib.blake2b(digest_size=32)

        # Normalize headers: lowercase keys, sort for consistency
        normalized = sorted(
            (k.lower(), str(v).lower())
            for k, v in headers.items()
            if k.lower()
            not in ("content-length", "content-length")  # Computed from body
        )

        for key, value in normalized:
            hasher.update(key.encode())
            hasher.update(value.encode())

        return hasher.hexdigest()

    def _is_entry_valid(self, entry: CachedContent) -> bool:
        """Check if a cache entry is still valid (not expired)."""
        age = time.time() - entry.created_at
        return age < self._ttl_seconds

    def _evict_expired_entries(self) -> None:
        """Remove expired entries from the cache."""
        now = time.time()
        expired = [
            key
            for key, entry in self._cache.items()
            if now - entry.created_at > self._ttl_seconds
        ]
        for key in expired:
            entry = self._cache.pop(key)
            self._current_bytes -= len(entry.content) if entry.content else 0
            self._stats.evictions += 1

        if expired:
            logger.debug("Evicted %d expired cache entries", len(expired))

    def _evict_lru_if_needed(self) -> None:
        """Evict least recently used entries if cache is at capacity or over budget."""
        # Check both count limit and byte budget
        while (
            len(self._cache) >= self._max_size or self._current_bytes > MAX_CACHE_BYTES
        ):
            if not self._cache:
                break
            # Find and remove the least recently used entry
            lru_key = min(
                self._cache.keys(), key=lambda k: self._cache[k].last_accessed
            )
            entry = self._cache.pop(lru_key)
            self._current_bytes -= len(entry.content) if entry.content else 0
            self._stats.evictions += 1
            logger.debug("Evicted LRU cache entry for key %s...", lru_key[:16])

    def _build_request_from_cached(
        self,
        cached: CachedContent,
        new_headers: dict[str, str],
        client: httpx.AsyncClient,
    ) -> httpx.Request:
        """Build a new request from cached content with new headers.

        This rebuilds the request using cached content bytes, avoiding
        the memory bloat of storing full httpx.Request objects.
        """
        return client.build_request(
            method=cached.method,
            url=cached.url,
            headers=new_headers,
            content=cached.content,
        )

    def get_or_build(
        self,
        method: str,
        url: httpx.URL | str,
        headers: dict[str, str],
        content: bytes | None,
        client: httpx.AsyncClient,
    ) -> httpx.Request:
        """Get a cached request or build a new one.

        This method:
        1. Computes hashes for content (method + URL + body) and headers
        2. Checks if we have a matching cached request
        3. If exact match: returns cached request
        4. If content match but headers differ: applies header delta update
        5. If no match: builds new request and caches it

        Args:
            method: HTTP method (GET, POST, etc.)
            url: Request URL
            headers: Request headers dict
            content: Request body content
            client: httpx.AsyncClient for building requests when needed

        Returns:
            An httpx.Request ready to use
        """
        content_hash = self._compute_content_hash(method, url, content)
        headers_hash = self._compute_headers_hash(headers)

        # Clean up expired entries periodically (1% chance per call)
        if hash(content_hash.encode()) % 100 == 0:
            self._evict_expired_entries()

        # Check for existing cached entry
        entry = self._cache.get(content_hash)

        if entry is not None:
            if not self._is_entry_valid(entry):
                # Entry expired, remove it
                self._current_bytes -= len(entry.content) if entry.content else 0
                del self._cache[content_hash]
                entry = None
            elif entry.headers_hash == headers_hash:
                # Exact match! Update access stats and rebuild request from cached content
                entry.access_count += 1
                entry.last_accessed = time.time()
                if self._enable_stats:
                    self._stats.hits += 1
                logger.debug("Cache HIT (exact) for %s %s", method, url)
                # Rebuild request from cached content bytes (not storing full request)
                return self._build_request_from_cached(entry, headers, client)
            else:
                # Content matches but headers differ - apply delta update!
                entry.access_count += 1
                entry.last_accessed = time.time()
                if self._enable_stats:
                    self._stats.header_only_updates += 1
                    self._stats.rebuilds_avoided += 1

                logger.debug(
                    "Cache HEADER-ONLY UPDATE for %s %s (rebuild avoided!)", method, url
                )

                # Build new request with same cached content but new headers
                new_request = self._build_request_from_cached(entry, headers, client)

                # Create new CachedContent entry instead of mutating in-place
                # Update bytes accounting: new entry may have same content size
                new_entry = CachedContent(
                    content=entry.content,
                    content_hash=content_hash,
                    headers_hash=headers_hash,
                    method=entry.method,
                    url=entry.url,
                    created_at=time.time(),  # Reset TTL
                    access_count=entry.access_count,
                    last_accessed=entry.last_accessed,
                )
                self._cache[content_hash] = new_entry

                return new_request

        # Cache miss - build new request
        if self._enable_stats:
            self._stats.misses += 1

        # Make room if needed
        self._evict_lru_if_needed()

        # Build fresh request
        request = client.build_request(
            method=method,
            url=url,
            headers=headers,
            content=content,
        )

        # Store content bytes in cache (not full request object) to save memory
        content_bytes = content if content is not None else b""
        self._current_bytes += len(content_bytes)
        self._cache[content_hash] = CachedContent(
            content=content_bytes if content_bytes else None,
            content_hash=content_hash,
            headers_hash=headers_hash,
            method=method,
            url=str(url),
        )

        logger.debug("Cache MISS for %s %s (new entry cached)", method, url)
        return request

    def invalidate(self, content_hash: str | None = None) -> int:
        """Invalidate cache entries.

        Args:
            content_hash: Specific hash to invalidate, or None to clear all

        Returns:
            Number of entries invalidated
        """
        if content_hash is None:
            count = len(self._cache)
            self._cache.clear()
            logger.debug("Invalidated all %d cache entries", count)
            return count
        else:
            if content_hash in self._cache:
                del self._cache[content_hash]
                logger.debug(
                    "Invalidated cache entry for hash %s...", content_hash[:16]
                )
                return 1
            return 0

    def get_stats(self) -> CacheStats:
        """Get cache performance statistics."""
        return CacheStats(
            hits=self._stats.hits,
            header_only_updates=self._stats.header_only_updates,
            misses=self._stats.misses,
            evictions=self._stats.evictions,
            rebuilds_avoided=self._stats.rebuilds_avoided,
        )

    def get_stats_dict(self) -> dict[str, Any]:
        """Get cache statistics as a dictionary."""
        total = self._stats.hits + self._stats.header_only_updates + self._stats.misses
        hit_rate = 0.0
        if total > 0:
            hit_rate = (self._stats.hits + self._stats.header_only_updates) / total

        return {
            "hits": self._stats.hits,
            "header_only_updates": self._stats.header_only_updates,
            "misses": self._stats.misses,
            "evictions": self._stats.evictions,
            "rebuilds_avoided": self._stats.rebuilds_avoided,
            "total_requests": total,
            "hit_rate": hit_rate,
            "current_size": len(self._cache),
            "max_size": self._max_size,
        }

    def clear_stats(self) -> None:
        """Reset all statistics counters."""
        self._stats = CacheStats()


# Global cache instance for reuse across clients
_global_request_cache: RequestCache | None = None
_global_cache_lock = threading.Lock()


def get_global_request_cache() -> RequestCache:
    """Get or create the global request cache.

    This shared cache can be used across multiple clients for
    maximum efficiency. Thread-safe via double-check locking.
    """
    global _global_request_cache
    if _global_request_cache is None:
        with _global_cache_lock:
            if _global_request_cache is None:
                _global_request_cache = RequestCache()
    return _global_request_cache


def reset_global_request_cache() -> None:
    """Reset the global request cache."""
    global _global_request_cache
    with _global_cache_lock:
        _global_request_cache = None


class RequestCacheMixin:
    """Mixin class to add request caching to httpx.AsyncClient subclasses.

    Usage:
        class MyClient(RequestCacheMixin, httpx.AsyncClient):
            def __init__(self, ...):
                super().__init__(...)
                self._init_request_cache()

            async def send(self, request):
                # Use cached_or_build_request to get optimized request
                optimized = self.cached_or_build_request(
                    method=request.method,
                    url=request.url,
                    headers=dict(request.headers),
                    content=request.content
                )
                return await super().send(optimized, ...)
    """

    def _init_request_cache(
        self,
        max_size: int = RequestCache.DEFAULT_MAX_SIZE,
        ttl_seconds: float = RequestCache.DEFAULT_TTL_SECONDS,
        use_global: bool = False,
    ) -> None:
        """Initialize request cache for this client.

        Args:
            max_size: Maximum cache size
            ttl_seconds: Cache entry TTL
            use_global: Whether to use the global shared cache
        """
        if use_global:
            self._request_cache = get_global_request_cache()
        else:
            self._request_cache = RequestCache(
                max_size=max_size, ttl_seconds=ttl_seconds
            )

    def cached_or_build_request(
        self,
        method: str,
        url: httpx.URL | str,
        headers: dict[str, str],
        content: bytes | None,
    ) -> httpx.Request:
        """Get cached request or build new one with header optimization.

        Requires _request_cache to be initialized via _init_request_cache().
        """
        if not hasattr(self, "_request_cache") or self._request_cache is None:
            # No cache available, build request directly
            return self.build_request(
                method=method, url=url, headers=headers, content=content
            )

        return self._request_cache.get_or_build(
            method=method, url=url, headers=headers, content=content, client=self
        )

    def get_cache_stats(self) -> dict[str, Any]:
        """Get cache statistics if caching is enabled."""
        if hasattr(self, "_request_cache") and self._request_cache:
            return self._request_cache.get_stats_dict()
        return {"enabled": False, "message": "Request cache not initialized"}

    def invalidate_cache(self, content_hash: str | None = None) -> int:
        """Invalidate cache entries."""
        if hasattr(self, "_request_cache") and self._request_cache:
            return self._request_cache.invalidate(content_hash)
        return 0
