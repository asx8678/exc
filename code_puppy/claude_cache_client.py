"""Cache helpers for Claude Code / Anthropic.

ClaudeCacheAsyncClient: httpx client that tries to patch /v1/messages bodies.

We now also expose `patch_anthropic_client_messages` which monkey-patches
AsyncAnthropic.messages.create() so we can inject cache_control BEFORE
serialization, avoiding httpx/Pydantic internals.

This module also handles:
- Tool name prefixing/unprefixing for Claude Code OAuth compatibility
- Header transformations (anthropic-beta, user-agent)
- URL modifications (adding ?beta=true query param)
- Tool ID sanitization for cross-provider message history compatibility
"""

import asyncio
import hashlib
import json
import logging
import random
import re
import threading
import time
from collections.abc import Callable
from email.utils import parsedate_to_datetime
from typing import Any, MutableMapping
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

import httpx
import jwt as _jwt

from .request_cache import RequestCacheMixin

# Anthropic requires tool_use.id and tool_result.tool_use_id to match this pattern.
# See: https://docs.anthropic.com/ (messages API 400 errors)
_ANTHROPIC_TOOL_ID_RE = re.compile(r"^[a-zA-Z0-9_-]+$")


def sanitize_tool_id(raw):
    """Rewrite a tool id so it matches Anthropic's ^[a-zA-Z0-9_-]+$ pattern.

    Deterministic: the same input ALWAYS maps to the same output, so
    tool_use/tool_result pairs stay consistent across the whole history
    without any external state.

    Valid ids are returned unchanged (idempotent), so calling this twice
    is safe. Empty strings are passed through unchanged because the caller
    filters None/empty before this point.
    """
    if not isinstance(raw, str) or not raw:
        return raw
    if _ANTHROPIC_TOOL_ID_RE.match(raw):
        return raw
    try:
        encoded = raw.encode("utf-8", errors="surrogatepass")
    except UnicodeEncodeError, UnicodeError:
        # absolute last-resort: hash the repr
        encoded = repr(raw).encode("utf-8", errors="replace")
    digest = hashlib.md5(encoded, usedforsecurity=False).hexdigest()[:16]
    return f"sanitized_{digest}"


def _sanitize_tool_ids_in_payload(payload: dict) -> bool:
    """In-place sanitization of tool_use/tool_result ids in an Anthropic
    messages payload.

    Walks payload["messages"] -> each message's content list. For any
    block where type == "tool_use", rewrites block["id"]. For any block
    where type == "tool_result", rewrites block["tool_use_id"].

    Because sanitize_tool_id is deterministic, the same invalid id
    always maps to the same sanitized id, so pairs stay linked even
    across messages.

    Returns True if anything was rewritten.
    """
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return False

    changed = False
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "tool_use":
                raw = block.get("id")
                if isinstance(raw, str):
                    new = sanitize_tool_id(raw)
                    if new != raw:
                        block["id"] = new
                        changed = True
            elif btype == "tool_result":
                raw = block.get("tool_use_id")
                if isinstance(raw, str):
                    new = sanitize_tool_id(raw)
                    if new != raw:
                        block["tool_use_id"] = new
                        changed = True
    return changed


logger = logging.getLogger(__name__)

# Refresh token if it's older than the configured max age (seconds)
TOKEN_MAX_AGE_SECONDS = 3600

# Retry configuration
RETRY_STATUS_CODES = (429, 500, 502, 503, 504)
MAX_RETRIES = 5

# Tool name prefix for Claude Code OAuth compatibility
# Tools are prefixed on outgoing requests and unprefixed on incoming responses
TOOL_PREFIX = "cp_"

# User-Agent to send with Claude Code OAuth requests
CLAUDE_CLI_USER_AGENT = "claude-cli/2.1.2 (external, cli)"

# Required betas for Claude Code OAuth (base set)
REQUIRED_BETAS_BASE = ("oauth-2025-04-20", "interleaved-thinking-2025-05-14")
REQUIRED_BETAS_BASE_SET = frozenset(REQUIRED_BETAS_BASE)

# Optional beta that gets added if present in incoming headers
CLAUDE_CODE_BETA_OPTIONAL = "claude-code-20250219"

# X-API-Key header variants to remove (using Bearer auth instead)
X_API_KEY_VARIANTS = ("x-api-key", "X-API-Key", "X-Api-Key")

try:
    from anthropic import AsyncAnthropic
except ImportError:  # pragma: no cover - optional dep
    AsyncAnthropic = None  # type: ignore


# Maximum allowed token age (24 hours in seconds)
MAX_TOKEN_AGE_SECONDS = 86400
# Clock skew tolerance for future iat claims (60 seconds)
CLOCK_SKEW_TOLERANCE_SECONDS = 60


# Hash-based JWT claims cache to avoid storing raw bearer tokens (~49KB secrets)
# Uses truncated SHA256 hash (16 bytes) as key instead of full token string
_jwt_claims_cache: dict[bytes, tuple[int, int]] = {}
_jwt_cache_lock = threading.Lock()
_JWT_CACHE_MAX_SIZE = 16


def _get_jwt_claims(token: str) -> tuple[int, int] | None:
    """Decode a JWT and return its (iat, exp) claims with hash-based caching.

    SECURITY: Uses SHA256 hash of token as cache key instead of storing
    raw bearer tokens, preventing memory retention of sensitive credentials.
    Returns None if the token can't be decoded or has invalid claims.

    Returns:
        tuple[int, int] | None: (iat, exp) if valid, None otherwise
    """
    if not token or not isinstance(token, str):
        return None

    # Use hash-based cache key (16 bytes) instead of full token (~49KB)
    cache_key = hashlib.sha256(token.encode()).digest()[:16]

    # Check cache first (under lock)
    with _jwt_cache_lock:
        if cache_key in _jwt_claims_cache:
            return _jwt_claims_cache[cache_key]

    # Decode and validate (no lock needed for pure computation)
    try:
        payload = _jwt.decode(token, options={"verify_signature": False})

        iat = payload.get("iat")
        exp = payload.get("exp")

        # Validate both are numeric
        if not isinstance(iat, (int, float)) or not isinstance(exp, (int, float)):
            return None

        now = time.time()

        # Validate bounds (positive, not absurdly far in future)
        max_future = now + 86400 * 365 * 10  # 10 years
        if iat <= 0 or exp <= 0 or iat > max_future or exp > max_future:
            return None

        # Validate exp > iat
        if exp <= iat:
            return None

        result = (int(iat), int(exp))

        # Store in cache with hash key (under lock)
        with _jwt_cache_lock:
            if len(_jwt_claims_cache) >= _JWT_CACHE_MAX_SIZE:
                # Simple LRU: clear oldest entry
                oldest = next(iter(_jwt_claims_cache))
                del _jwt_claims_cache[oldest]
            _jwt_claims_cache[cache_key] = result

        return result
    except Exception:
        return None


def _validate_jwt_claims(token: str) -> tuple[int, int] | None:
    """Comprehensively validate JWT claims for security.

    Validates:
    1. Both 'exp' and 'iat' claims exist and are valid positive integers
    2. exp > iat (expiry must be after issued-at)
    3. iat is not in the future (allows small clock skew of ~60 seconds)
    4. Token age (exp - iat) does not exceed 24 hours (86400 seconds)
    5. Token is not already expired

    Returns:
        tuple[int, int] | None: (iat, exp) if validation passes, None otherwise

    SECURITY: This is a critical security function. Any change to validation
    logic must be carefully reviewed for security implications.
    """
    if not token or not isinstance(token, str):
        return None

    try:
        payload = _jwt.decode(token, options={"verify_signature": False})
    except Exception:
        return None

    if not isinstance(payload, dict):
        return None

    # Extract raw 'exp' claim (validate as numeric before truncation)
    exp = payload.get("exp")
    if exp is None:
        logger.debug("JWT validation failed: missing 'exp' claim")
        return None
    if not isinstance(exp, (int, float)):
        logger.debug("JWT validation failed: 'exp' is not numeric (%s)", type(exp))
        return None
    # SECURITY: Validate using RAW numeric values (not truncated to int)
    if exp <= 0:
        logger.debug("JWT validation failed: 'exp' is not positive (%s)", exp)
        return None

    # Extract raw 'iat' claim (validate as numeric before truncation)
    iat = payload.get("iat")
    if iat is None:
        logger.debug("JWT validation failed: missing 'iat' claim")
        return None
    if not isinstance(iat, (int, float)):
        logger.debug("JWT validation failed: 'iat' is not numeric (%s)", type(iat))
        return None
    # SECURITY: Validate using RAW numeric values (not truncated to int)
    if iat <= 0:
        logger.debug("JWT validation failed: 'iat' is not positive (%s)", iat)
        return None

    # Validate exp > iat using RAW values (expiry must be after issued-at)
    if exp <= iat:
        logger.debug(
            "JWT validation failed: 'exp' (%s) is not after 'iat' (%s)",
            exp,
            iat,
        )
        return None

    # Validate iat is not in the future using RAW values (allow clock skew tolerance)
    now = time.time()
    if iat > now + CLOCK_SKEW_TOLERANCE_SECONDS:
        logger.debug(
            "JWT validation failed: 'iat' (%s) is in the future (now: %s, skew: %s)",
            iat,
            now,
            CLOCK_SKEW_TOLERANCE_SECONDS,
        )
        return None

    # Validate maximum token age using RAW values (24 hours)
    token_lifetime = exp - iat
    if token_lifetime > MAX_TOKEN_AGE_SECONDS:
        logger.debug(
            "JWT validation failed: token lifetime (%s seconds) exceeds maximum (%s)",
            token_lifetime,
            MAX_TOKEN_AGE_SECONDS,
        )
        return None

    # Validate token is not already expired using RAW values
    if exp < now - CLOCK_SKEW_TOLERANCE_SECONDS:
        logger.debug(
            "JWT validation failed: token expired (exp: %s, now: %s)", exp, now
        )
        return None

    # SECURITY: Only convert to int at the very end for return values
    return (int(iat), int(exp))


class ClaudeCacheAsyncClient(RequestCacheMixin, httpx.AsyncClient):
    """Async HTTP client with Claude Code OAuth transformations.

    Handles:
    - Cache control injection for prompt caching
    - Tool name prefixing on outgoing requests
    - Tool name unprefixing on incoming streaming responses
    - Header transformations (anthropic-beta, user-agent)
    - URL modifications (adding ?beta=true)
    - Proactive token refresh
    - Request caching for header-only change optimization
    """

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        # Initialize request cache with larger capacity for Claude (more diverse requests)
        self._init_request_cache(max_size=256, ttl_seconds=300)
        # Performance tracking
        self._request_build_time_saved_ms = 0.0
        self._requests_optimized = 0
        # JWT age caching: avoid repeated base64+JSON decoding on every request
        # Stores (token_hash_or_prefix, iat_value) - only re-parse when token changes
        self._cached_jwt_iat: tuple[str, float] | None = None

    def _get_jwt_age_seconds(self, token: str | None) -> float | None:
        """Decode a JWT and return its age in seconds with comprehensive validation.

        SECURITY: This function now performs comprehensive JWT claim validation
        including exp > iat, clock skew checks, and maximum token age enforcement.

        Returns None if:
        - Token is missing or invalid
        - exp or iat claims are missing or malformed
        - exp <= iat (invalid timestamp ordering)
        - iat is in the future (beyond clock skew tolerance)
        - Token lifetime exceeds 24 hours
        - Token is already expired

        Uses cached iat time when the same token is passed,
        avoiding repeated base64+JSON decoding on every API request.
        """
        if not token:
            return None

        try:
            # First, perform comprehensive security validation
            validated_claims = _validate_jwt_claims(token)
            if validated_claims is None:
                # Token failed security validation
                return None

            iat_int, _ = validated_claims

            # Check instance cache first: compare by token prefix/hash
            # This avoids repeated base64+JSON decoding on retries
            # Use first 64 chars: covers JWT header (typically ~36 chars base64)
            # plus ~28 chars of payload which contains the distinguishing claims
            token_prefix = token[:64]
            if self._cached_jwt_iat is not None:
                cached_prefix, cached_iat = self._cached_jwt_iat
                if cached_prefix == token_prefix:
                    return time.time() - cached_iat

            # Update instance cache with validated iat
            self._cached_jwt_iat = (token_prefix, float(iat_int))
            return time.time() - iat_int

        except Exception as exc:
            logger.debug("Failed to decode JWT age: %s", exc)
            return None

    def _extract_bearer_token(self, request: httpx.Request) -> str | None:
        """Extract the bearer token from request headers."""
        auth_header = request.headers.get("Authorization") or request.headers.get(
            "authorization"
        )
        if auth_header and auth_header.lower().startswith("bearer "):
            return auth_header[7:]  # Strip "Bearer " prefix
        return None

    def _should_refresh_token(self, request: httpx.Request) -> bool:
        """Check if the token should be refreshed (within the max-age window).

        Uses two strategies:
        1. Decode JWT to check token age (if possible)
        2. Fall back to stored expires_at from token file

        Returns True if token expires within TOKEN_MAX_AGE_SECONDS.
        """
        token = self._extract_bearer_token(request)
        if not token:
            return False

        # Strategy 1: Try to decode JWT age
        age = self._get_jwt_age_seconds(token)
        if age is not None:
            should_refresh = age >= TOKEN_MAX_AGE_SECONDS
            if should_refresh:
                logger.info(
                    "JWT token is %.1f seconds old (>= %d), will refresh proactively",
                    age,
                    TOKEN_MAX_AGE_SECONDS,
                )
            return should_refresh

        # Strategy 2: Fall back to stored expires_at from token file
        should_refresh = self._check_stored_token_expiry()
        if should_refresh:
            logger.info(
                "Stored token expires within %d seconds, will refresh proactively",
                TOKEN_MAX_AGE_SECONDS,
            )
        return should_refresh

    @staticmethod
    def _check_stored_token_expiry() -> bool:
        """Check if the stored token expires within TOKEN_MAX_AGE_SECONDS.

        This is a fallback for when JWT decoding fails or isn't available.
        Uses the expires_at timestamp from the stored token file.
        """
        try:
            from code_puppy.plugins.claude_code_oauth.utils import (
                is_token_expired,
                load_stored_tokens,
            )

            tokens = load_stored_tokens()
            if not tokens:
                return False

            # is_token_expired already uses the configured refresh buffer window
            return is_token_expired(tokens)
        except Exception as exc:
            logger.debug("Error checking stored token expiry: %s", exc)
            return False

    @staticmethod
    def _transform_request_body(body: bytes) -> tuple[bytes | None, bool, bool]:
        """Single-pass transform for tool prefixing, cache_control injection, and tool_id sanitization.

        Parses the JSON body once and applies all transformations:
        1. Prefixes tool names with TOOL_PREFIX for Claude Code OAuth compatibility
        2. Injects cache_control into the last message's last content block
        3. Sanitizes tool_use.id and tool_result.tool_use_id for Anthropic pattern compliance

        Returns: (transformed_body_or_None, tools_modified, cache_modified)
        """
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            return None, False, False

        if not isinstance(data, dict):
            return None, False, False

        tools_modified = False
        cache_modified = False

        # 1. Prefix tool names
        tools = data.get("tools")
        if isinstance(tools, list) and tools:
            for tool in tools:
                if isinstance(tool, dict) and "name" in tool:
                    name = tool["name"]
                    if name and not name.startswith(TOOL_PREFIX):
                        tool["name"] = f"{TOOL_PREFIX}{name}"
                        tools_modified = True

        # 2. Sanitize tool ids (defense in depth for cross-provider message history)
        try:
            ids_modified = _sanitize_tool_ids_in_payload(data)
        except Exception as exc:
            # Sanitization must NEVER crash the request path
            logger.debug("Error during tool id sanitization (transform body): %s", exc)
            ids_modified = False

        # 3. Inject cache_control into last message's last content block
        messages = data.get("messages")
        if isinstance(messages, list) and messages:
            last = messages[-1]
            if isinstance(last, dict):
                content = last.get("content")
                if isinstance(content, list) and content:
                    last_block = content[-1]
                    if (
                        isinstance(last_block, dict)
                        and "cache_control" not in last_block
                    ):
                        last_block["cache_control"] = {"type": "ephemeral"}
                        cache_modified = True

        if not tools_modified and not cache_modified and not ids_modified:
            return None, False, False

        return json.dumps(data).encode("utf-8"), tools_modified, cache_modified

    @staticmethod
    def _prefix_tool_names(body: bytes) -> bytes | None:
        """Prefix all tool names in the request body with TOOL_PREFIX.

        This is required for Claude Code OAuth compatibility - tools must be
        prefixed on outgoing requests and unprefixed on incoming responses.
        """
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            return None

        if not isinstance(data, dict):
            return None

        tools = data.get("tools")
        if not isinstance(tools, list) or not tools:
            return None

        modified = False
        for tool in tools:
            if isinstance(tool, dict) and "name" in tool:
                name = tool["name"]
                if name and not name.startswith(TOOL_PREFIX):
                    tool["name"] = f"{TOOL_PREFIX}{name}"
                    modified = True

        if not modified:
            return None

        return json.dumps(data).encode("utf-8")

    @staticmethod
    def _transform_headers_for_claude_code(headers: MutableMapping[str, str]) -> None:
        """Transform headers for Claude Code OAuth compatibility.

        - Sets user-agent to claude-cli
        - Merges anthropic-beta headers appropriately
        - Removes x-api-key (using Bearer auth instead)
        """
        # Set user-agent
        headers["user-agent"] = CLAUDE_CLI_USER_AGENT

        # Handle anthropic-beta header — merge required betas with any
        # extras already present (e.g. context-1m-2025-08-07).
        incoming_beta = headers.get("anthropic-beta", "")
        incoming_betas = [b.strip() for b in incoming_beta.split(",") if b.strip()]

        # Build required set based on base required betas + optional claude-code beta
        required_set = REQUIRED_BETAS_BASE_SET
        if CLAUDE_CODE_BETA_OPTIONAL in incoming_betas:
            required_set = required_set | {CLAUDE_CODE_BETA_OPTIONAL}

        # Merge: start with required base, then optional, then append extras
        merged = list(REQUIRED_BETAS_BASE)
        if CLAUDE_CODE_BETA_OPTIONAL in incoming_betas:
            merged.append(CLAUDE_CODE_BETA_OPTIONAL)
        for beta in incoming_betas:
            if beta not in required_set:
                merged.append(beta)

        headers["anthropic-beta"] = ",".join(merged)

        # Remove x-api-key if present (we use Bearer auth instead)
        for key in X_API_KEY_VARIANTS:
            if key in headers:
                del headers[key]

    @staticmethod
    def _add_beta_query_param(url: httpx.URL) -> httpx.URL:
        """Add ?beta=true query parameter to the URL if not already present."""
        # Parse the URL
        parsed = urlparse(str(url))
        query_params = parse_qs(parsed.query)

        # Only add if not already present
        if "beta" not in query_params:
            query_params["beta"] = ["true"]
            # Rebuild query string
            new_query = urlencode(query_params, doseq=True)
            # Rebuild URL
            new_parsed = parsed._replace(query=new_query)
            return httpx.URL(urlunparse(new_parsed))

        return url

    async def send(
        self, request: httpx.Request, *args: Any, **kwargs: Any
    ) -> httpx.Response:  # type: ignore[override]
        is_messages_endpoint = request.url.path.endswith("/v1/messages")
        rebuild_start = time.perf_counter()
        used_cache = False

        # Proactive token refresh: check JWT age before every request
        if not request.extensions.get("claude_oauth_refresh_attempted"):
            try:
                if self._should_refresh_token(request):
                    refreshed_token = self._refresh_claude_oauth_token()
                    if refreshed_token:
                        logger.info("Proactively refreshed token before request")
                        # Rebuild request with new token - USE CACHE for header-only change
                        headers = dict(request.headers)
                        self._update_auth_headers(headers, refreshed_token)
                        body_bytes = self._extract_body_bytes(request)
                        request = self.cached_or_build_request(
                            method=request.method,
                            url=request.url,
                            headers=headers,
                            content=body_bytes,
                        )
                        used_cache = True
                        request.extensions["claude_oauth_refresh_attempted"] = True
            except Exception as exc:
                logger.debug("Error during proactive token refresh check: %s", exc)

        # Apply Claude Code OAuth transformations for /v1/messages
        if is_messages_endpoint:
            try:
                body_bytes = self._extract_body_bytes(request)
                headers = dict(request.headers)
                url = request.url
                body_modified = False
                headers_modified = False

                # 1. Transform headers for Claude Code OAuth
                self._transform_headers_for_claude_code(headers)
                headers_modified = True

                # 2. Add ?beta=true query param
                url = self._add_beta_query_param(url)

                # 3. Transform request body (tool prefixing + cache_control in one pass)
                if body_bytes:
                    transformed_body, _, _ = self._transform_request_body(body_bytes)
                    if transformed_body is not None:
                        body_bytes = transformed_body
                        body_modified = True

                # Rebuild request if anything changed - USE CACHE for optimization
                if body_modified or headers_modified or url != request.url:
                    try:
                        # Optimization: skip rebuild for header-only changes
                        # Body re-encode is expensive; if only headers changed, mutate directly
                        if not body_modified and url == request.url:
                            # Header-only change: mutate headers directly, skip rebuild
                            for key, value in headers.items():
                                request.headers[key] = value
                            used_cache = True
                        else:
                            # Body or URL changed: need full rebuild
                            rebuilt = self.cached_or_build_request(
                                method=request.method,
                                url=url,
                                headers=headers,
                                content=body_bytes,
                            )
                            used_cache = True

                            # Copy core internals so httpx uses the modified body/stream
                            # OPTIMIZATION: Use hasattr + direct access pattern to reduce
                            # repeated getattr lookups. We check once and use direct access.
                            _rebuilt = rebuilt  # Local binding for speed
                            if hasattr(_rebuilt, "_content"):
                                request._content = _rebuilt._content  # type: ignore[attr-defined]
                            if hasattr(_rebuilt, "stream"):
                                request.stream = _rebuilt.stream  # type: ignore[attr-defined]
                            if hasattr(_rebuilt, "extensions"):
                                request.extensions = _rebuilt.extensions  # type: ignore[attr-defined]

                            # Update URL
                            request.url = url

                            # Update headers
                            for key, value in headers.items():
                                request.headers[key] = value

                            # Ensure Content-Length matches the new body
                            if body_bytes:
                                request.headers["Content-Length"] = str(len(body_bytes))

                    except Exception as exc:
                        logger.debug("Error rebuilding request: %s", exc)

            except Exception as exc:
                logger.debug("Error in Claude Code transformations: %s", exc)

        # Track performance metrics
        if used_cache:
            rebuild_time = (time.perf_counter() - rebuild_start) * 1000
            self._requests_optimized += 1
            estimated_saved = max(0, 5.0 - rebuild_time)
            self._request_build_time_saved_ms += estimated_saved
            logger.debug(
                "Request optimized via cache (took %.2fms, saved ~%.2fms)",
                rebuild_time,
                estimated_saved,
            )

        # Send the request with retry logic for transient errors
        response = await self._send_with_retries(request, *args, **kwargs)

        # NOTE: Tool name unprefixing is now handled at the pydantic-ai level
        # in pydantic_patches.py rather than wrapping the HTTP response stream.
        # The response wrapper caused zlib decompression errors due to httpx
        # response lifecycle issues.

        # Handle auth errors with token refresh
        try:
            if response.status_code in (400, 401, 403) and not request.extensions.get(
                "claude_oauth_refresh_attempted"
            ):
                is_auth_error = response.status_code in (401, 403)

                if response.status_code == 400:
                    is_auth_error = await self._is_cloudflare_html_error(response)
                    if is_auth_error:
                        logger.info(
                            "Detected Cloudflare 400 error (likely auth-related), attempting token refresh"
                        )

                if is_auth_error:
                    refreshed_token = self._refresh_claude_oauth_token()
                    if refreshed_token:
                        logger.info("Token refreshed successfully, retrying request")
                        await response.aclose()
                        body_bytes = self._extract_body_bytes(request)
                        headers = dict(request.headers)
                        self._update_auth_headers(headers, refreshed_token)
                        # Use cached request building for retry optimization
                        retry_request = self.cached_or_build_request(
                            method=request.method,
                            url=request.url,
                            headers=headers,
                            content=body_bytes,
                        )
                        retry_request.extensions["claude_oauth_refresh_attempted"] = (
                            True
                        )
                        return await self._send_with_retries(
                            retry_request, *args, **kwargs
                        )
                    else:
                        logger.warning("Token refresh failed, returning original error")
        except Exception as exc:
            logger.debug("Error during token refresh attempt: %s", exc)

        return response

    async def _send_with_retries(
        self, request: httpx.Request, *args: Any, **kwargs: Any
    ) -> httpx.Response:
        """Send request with automatic retries for rate limits and server errors.

        Retries on:
        - 429 (rate limit) - respects Retry-After header
        - 500, 502, 503, 504 (server errors) - exponential backoff
        - Connection errors (ConnectError, ReadTimeout, PoolTimeout)
        """
        last_response = None
        last_exception = None

        for attempt in range(MAX_RETRIES + 1):
            try:
                response = await super().send(request, *args, **kwargs)
                last_response = response

                # Check for retryable status
                if response.status_code not in RETRY_STATUS_CODES:
                    return response

                # Don't retry if this is the last attempt
                if attempt >= MAX_RETRIES:
                    return response

                # Close response before retrying
                await response.aclose()

                # Calculate wait time with exponential backoff and jitter
                wait_time = 2**attempt  # 1s, 2s, 4s, 8s, 16s
                # Add jitter to prevent thundering herd
                wait_time = wait_time + random.uniform(0, wait_time * 0.1)

                # For 429, respect Retry-After header if present
                if response.status_code == 429:
                    retry_after = response.headers.get("Retry-After")
                    if retry_after:
                        try:
                            wait_time = float(retry_after)
                        except ValueError:
                            # Try parsing http-date format
                            try:
                                date = parsedate_to_datetime(retry_after)
                                wait_time = max(0, date.timestamp() - time.time())
                            except Exception:
                                pass

                # Cap wait time between 0.5s and 60s
                wait_time = max(0.5, min(wait_time, 60.0))

                logger.info(
                    "HTTP %d received, retrying in %.1fs (attempt %d/%d)",
                    response.status_code,
                    wait_time,
                    attempt + 1,
                    MAX_RETRIES,
                )
                await asyncio.sleep(wait_time)

            except (httpx.ConnectError, httpx.ReadTimeout, httpx.PoolTimeout) as exc:
                last_exception = exc

                # Don't retry if this is the last attempt
                if attempt >= MAX_RETRIES:
                    raise

                wait_time = 2**attempt
                # Add jitter to prevent thundering herd
                wait_time = wait_time + random.uniform(0, wait_time * 0.1)
                wait_time = max(0.5, min(wait_time, 60.0))

                logger.warning(
                    "HTTP connection error: %s. Retrying in %.1fs (attempt %d/%d)",
                    exc,
                    wait_time,
                    attempt + 1,
                    MAX_RETRIES,
                )
                await asyncio.sleep(wait_time)

            except Exception:
                # Don't retry on other exceptions (e.g., validation errors)
                raise

        # Return last response if we have one
        if last_response is not None:
            return last_response

        # Re-raise last exception if we have one
        if last_exception is not None:
            raise last_exception

        # This shouldn't happen, but just in case
        raise RuntimeError("Retry loop completed without response or exception")

    @staticmethod
    def _extract_body_bytes(request: httpx.Request) -> bytes | None:
        """Extract the request body as bytes.

        OPTIMIZATION: Use hasattr + direct access pattern to reduce getattr overhead.
        """
        # Try public content first
        try:
            content = request.content
            if content:
                return content
        except Exception:
            pass

        # Fallback to private attr if necessary - use getattr with exception handling
        # to gracefully handle property access failures (hasattr can raise if property raises)
        try:
            content = getattr(request, "_content", None)
            if content is not None:
                return content
        except Exception:
            pass

        return None

    @staticmethod
    def _update_auth_headers(
        headers: MutableMapping[str, str], access_token: str
    ) -> None:
        bearer_value = f"Bearer {access_token}"
        if "Authorization" in headers or "authorization" in headers:
            headers["Authorization"] = bearer_value
        elif "x-api-key" in headers or "X-API-Key" in headers:
            headers["x-api-key"] = access_token
        else:
            headers["Authorization"] = bearer_value

    @staticmethod
    async def _is_cloudflare_html_error(response: httpx.Response) -> bool:
        """Check if this is a Cloudflare HTML error response.

        Cloudflare often returns HTML error pages with status 400 when
        there are authentication issues.
        """
        # Check content type
        content_type = response.headers.get("content-type", "")
        if "text/html" not in content_type.lower():
            return False

        # Check if body contains Cloudflare markers
        try:
            # For async httpx, we need to read the body first
            # OPTIMIZATION: Cache hasattr check result to avoid repeated lookups
            response_has_content = hasattr(response, "_content")
            if not response_has_content or not response._content:
                try:
                    await response.aread()
                except Exception as read_exc:
                    logger.debug("Failed to read response body: %s", read_exc)
                    return False

            # Now we can safely access the content
            # Re-check _content after aread() since it may have populated it
            content: bytes | None = None
            if response_has_content and response._content:
                content = response._content
            else:
                # Fallback to text property (should work after aread)
                try:
                    content = response.content
                except Exception:
                    return False

            if not content:
                return False

            # OPTIMIZATION: Use ASCII bytes.lower() on 8KB-capped slice
            # instead of full UTF-8 decode + str.lower() which doubles allocation (~8KB)
            # Check for Cloudflare and 400 markers directly in bytes
            head = content[:8192].lower()
            return b"cloudflare" in head and b"400" in head
        except Exception as exc:
            logger.debug("Error checking for Cloudflare error: %s", exc)
            return False

    def _refresh_claude_oauth_token(self) -> str | None:
        try:
            from code_puppy.plugins.claude_code_oauth.utils import refresh_access_token

            logger.info("Attempting to refresh Claude Code OAuth token...")
            refreshed_token = refresh_access_token(force=True)
            if refreshed_token:
                self._update_auth_headers(self.headers, refreshed_token)
                # Clear JWT age cache when token changes
                self._cached_jwt_iat = None
                logger.info("Successfully refreshed Claude Code OAuth token")
            else:
                logger.warning("Token refresh returned None")
            return refreshed_token
        except Exception as exc:
            logger.error("Exception during token refresh: %s", exc)
            return None

    def get_performance_stats(self) -> dict[str, Any]:
        """Get performance statistics for this client.

        Returns:
            Dict with performance metrics including:
            - requests_optimized: Number of requests that used cache
            - time_saved_ms: Estimated time saved from avoiding rebuilds
            - cache_stats: Detailed cache statistics
        """
        cache_stats = self.get_cache_stats()
        return {
            "requests_optimized": self._requests_optimized,
            "estimated_time_saved_ms": self._request_build_time_saved_ms,
            "cache": cache_stats,
        }

    @staticmethod
    def _inject_cache_control(body: bytes) -> bytes | None:
        # Skip if SDK already injected cache_control (fast path avoids JSON parse)
        # Check for the marker: "_cache_control_sdk_injected": true
        # Note: We need to strip the marker even if we skip injection
        if b'"_cache_control_sdk_injected"' in body:
            try:
                data = json.loads(body.decode("utf-8"))
                if isinstance(data, dict) and "_cache_control_sdk_injected" in data:
                    # Strip the marker before sending to Anthropic
                    del data["_cache_control_sdk_injected"]
                    return json.dumps(data).encode("utf-8")
            except Exception:
                pass  # Fall through to normal flow if stripping fails
            return None

        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            return None

        if not isinstance(data, dict):
            return None

        modified = False

        # Minimal, deterministic strategy:
        # Add cache_control only on the single most recent block:
        # the last dict content block of the last message (if any).
        messages = data.get("messages")
        if isinstance(messages, list) and messages:
            last = messages[-1]
            if isinstance(last, dict):
                content = last.get("content")
                if isinstance(content, list) and content:
                    last_block = content[-1]
                    if (
                        isinstance(last_block, dict)
                        and "cache_control" not in last_block
                    ):
                        last_block["cache_control"] = {"type": "ephemeral"}
                        modified = True

        if not modified:
            return None

        return json.dumps(data).encode("utf-8")


def _inject_cache_control_in_payload(payload: dict[str, Any]) -> bool:
    """In-place cache_control injection on Anthropic messages.create payload.

    Returns True if cache_control was injected, False otherwise.
    """
    injected = False
    messages = payload.get("messages")
    if isinstance(messages, list) and messages:
        last = messages[-1]
        if isinstance(last, dict):
            content = last.get("content")
            if isinstance(content, list) and content:
                last_block = content[-1]
                if isinstance(last_block, dict) and "cache_control" not in last_block:
                    last_block["cache_control"] = {"type": "ephemeral"}
                    injected = True

    # Add marker so HTTP-level injection can skip redundant parsing
    if injected:
        payload["_cache_control_sdk_injected"] = True
    return injected


def patch_anthropic_client_messages(client: Any) -> None:
    """Monkey-patch AsyncAnthropic.messages.create to inject cache_control.

    This operates at the highest level: just before Anthropic SDK serializes
    the request into HTTP. That means no httpx / Pydantic shenanigans can
    undo it.
    """

    if AsyncAnthropic is None or not isinstance(client, AsyncAnthropic):  # type: ignore[arg-type]
        return

    try:
        messages_obj = getattr(client, "messages", None)
        if messages_obj is None:
            return
        original_create: Callable[..., Any] = messages_obj.create
    except Exception:  # pragma: no cover - defensive
        return

    async def wrapped_create(*args: Any, **kwargs: Any):
        # Anthropic messages.create takes a mix of positional/kw args.
        # The payload is usually in kwargs for the Python SDK.
        if kwargs:
            _inject_cache_control_in_payload(kwargs)
        elif args:
            maybe_payload = args[-1]
            if isinstance(maybe_payload, dict):
                _inject_cache_control_in_payload(maybe_payload)

        return await original_create(*args, **kwargs)

    messages_obj.create = wrapped_create  # type: ignore[assignment]
