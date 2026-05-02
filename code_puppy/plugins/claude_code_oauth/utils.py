"""Utility helpers for the Claude Code OAuth plugin."""

import base64
import hashlib
import json
import logging
import os
import re
import secrets
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

import requests

from .config import (
    CLAUDE_CODE_OAUTH_CONFIG,
    get_claude_models_path,
    get_token_storage_path,
)

# SECURITY: These fields are sensitive and must never be logged.
# The _redact_secrets function should be used when logging any token data.
SENSITIVE_FIELDS = {
    "access_token",
    "refresh_token",
    "id_token",
    "api_key",
    "secret",
    "client_secret",
}


def _redact_secrets(data: dict[str, Any]) -> dict[str, Any]:
    """Redact sensitive fields from token response data for safe logging."""
    if not isinstance(data, dict):
        return {"_raw": "<non-dict response>"}
    return {
        k: ("***REDACTED***" if k.lower() in SENSITIVE_FIELDS else v)
        for k, v in data.items()
    }


# Proactive refresh buffer default (seconds). Actual buffer is dynamic
# based on expires_in to avoid overly aggressive refreshes.
TOKEN_REFRESH_BUFFER_SECONDS = 300
MIN_REFRESH_BUFFER_SECONDS = 30

logger = logging.getLogger(__name__)


# Models that should NEVER be registered in claude_models.json, even if
# returned by upstream or left behind in the file. Matched against both
# the raw model name (e.g. ``claude-opus-4-5-20251101``) and the
# prefixed form (e.g. ``claude-code-claude-opus-4-5-20251101``). Add an
# entry here to permanently suppress a model in the UI/model picker.
BLOCKED_CLAUDE_CODE_MODELS = frozenset()


def _is_blocked_claude_model(model_name: str) -> bool:
    """Return True if a model should be filtered out of claude_models.json.

    Accepts either the raw model name or the prefixed form.
    """
    if not model_name:
        return False
    name = model_name
    prefix = CLAUDE_CODE_OAUTH_CONFIG.get("prefix", "claude-code-")
    if prefix and name.startswith(prefix):
        name = name[len(prefix) :]
    # Tolerate the ``-long`` variant suffix that the plugin appends.
    if name.endswith("-long"):
        name = name[: -len("-long")]
    return (
        name in BLOCKED_CLAUDE_CODE_MODELS or model_name in BLOCKED_CLAUDE_CODE_MODELS
    )


def _filter_blocked_claude_models(models: list[str]) -> list[str]:
    """Drop blocked models from a list of raw model names."""
    if not models:
        return models
    kept: list[str] = []
    dropped: list[str] = []
    for m in models:
        if _is_blocked_claude_model(m):
            dropped.append(m)
        else:
            kept.append(m)
    if dropped:
        logger.info("Filtered blocked Claude Code models: %s", dropped)
    return kept


@dataclass
class OAuthContext:
    """Runtime state for an in-progress OAuth flow."""

    state: str
    code_verifier: str
    code_challenge: str
    created_at: float
    redirect_uri: str | None = None


_oauth_context: OAuthContext | None = None


def _urlsafe_b64encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("utf-8").rstrip("=")


def _generate_code_verifier() -> str:
    return _urlsafe_b64encode(secrets.token_bytes(64))


def _compute_code_challenge(code_verifier: str) -> str:
    digest = hashlib.sha256(code_verifier.encode("utf-8")).digest()
    return _urlsafe_b64encode(digest)


def prepare_oauth_context() -> OAuthContext:
    """Create and cache a new OAuth PKCE context."""
    global _oauth_context
    state = secrets.token_urlsafe(32)
    code_verifier = _generate_code_verifier()
    code_challenge = _compute_code_challenge(code_verifier)
    _oauth_context = OAuthContext(
        state=state,
        code_verifier=code_verifier,
        code_challenge=code_challenge,
        created_at=time.time(),
    )
    return _oauth_context


def get_oauth_context() -> OAuthContext | None:
    return _oauth_context


def clear_oauth_context() -> None:
    global _oauth_context
    _oauth_context = None


def assign_redirect_uri(context: OAuthContext, port: int) -> str:
    """Assign redirect URI for the given OAuth context."""
    if context is None:
        raise RuntimeError("OAuth context cannot be None")

    host = CLAUDE_CODE_OAUTH_CONFIG["redirect_host"].rstrip("/")
    path = CLAUDE_CODE_OAUTH_CONFIG["redirect_path"].lstrip("/")
    redirect_uri = f"{host}:{port}/{path}"
    context.redirect_uri = redirect_uri
    return redirect_uri


def build_authorization_url(context: OAuthContext) -> str:
    """Return the Claude authorization URL with PKCE parameters."""
    if not context.redirect_uri:
        raise RuntimeError("Redirect URI has not been assigned for this OAuth context")

    params = {
        "response_type": "code",
        "client_id": CLAUDE_CODE_OAUTH_CONFIG["client_id"],
        "redirect_uri": context.redirect_uri,
        "scope": CLAUDE_CODE_OAUTH_CONFIG["scope"],
        "state": context.state,
        "code": "true",
        "code_challenge": context.code_challenge,
        "code_challenge_method": "S256",
    }
    return f"{CLAUDE_CODE_OAUTH_CONFIG['auth_url']}?{urlencode(params)}"


def parse_authorization_code(raw_input: str) -> tuple[str, str | None]:
    value = raw_input.strip()
    if not value:
        raise ValueError("Authorization code cannot be empty")

    if "#" in value:
        code, state = value.split("#", 1)
        return code.strip(), state.strip() or None

    parts = value.split()
    if len(parts) == 2:
        return parts[0].strip(), parts[1].strip() or None

    return value, None


def load_stored_tokens() -> dict[str, Any] | None:
    try:
        token_path = get_token_storage_path()
        if token_path.exists():
            with open(token_path, "r", encoding="utf-8") as handle:
                return json.load(handle)
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Failed to load tokens: %s", exc)
    return None


def _calculate_expires_at(expires_in: float | None) -> float | None:
    if expires_in is None:
        return None
    try:
        return time.time() + float(expires_in)
    except TypeError, ValueError:
        return None


def _calculate_refresh_buffer(expires_in: float | None) -> float:
    default_buffer = float(TOKEN_REFRESH_BUFFER_SECONDS)
    if expires_in is None:
        return default_buffer
    try:
        expires_value = float(expires_in)
    except TypeError, ValueError:
        return default_buffer
    return min(default_buffer, max(MIN_REFRESH_BUFFER_SECONDS, expires_value * 0.1))


def _get_expires_at_value(tokens: dict[str, Any]) -> float | None:
    expires_at = tokens.get("expires_at")
    if expires_at is None:
        return None
    try:
        return float(expires_at)
    except TypeError, ValueError:
        return None


def _is_token_actually_expired(tokens: dict[str, Any]) -> bool:
    expires_at_value = _get_expires_at_value(tokens)
    if expires_at_value is None:
        return False
    return time.time() >= expires_at_value


# Unrecoverable OAuth error codes that indicate the refresh token is dead
# and cannot be used anymore. These require user re-authentication.
UNRECOVERABLE_OAUTH_ERRORS = frozenset(
    {
        "invalid_grant",
        "invalid_token",
        "token_expired",
        "unauthorized_client",
        "access_denied",
        "invalid_client",
    }
)

# Explicit phrases in error messages/descriptions that indicate unrecoverable errors.
UNRECOVERABLE_ERROR_PHRASES = frozenset(
    {
        "token expired",
        "refresh token expired",
        "token has expired",
        "could not validate your token",
        "invalid grant",
    }
)


def _is_unrecoverable_token_error(response: Any) -> bool:
    """Check if an OAuth response indicates an unrecoverable token error.

    Supports both response shapes:
    a) OAuth style: {"error": "invalid_grant", "error_description": "..."}
    b) Nested API style: {"error": {"code": "token_expired", "message": "..."}}

    Args:
        response: The requests Response object from a failed token refresh.

    Returns:
        True if the error is unrecoverable (token is dead, user must re-auth).
    """
    # 401 Unauthorized is always unrecoverable
    if response.status_code == 401:
        return True

    # 400 Bad Request often carries OAuth error codes
    if response.status_code == 400:
        try:
            error_data = response.json()

            # Handle OAuth style: {"error": "invalid_grant", "error_description": "..."}
            error_code = error_data.get("error")
            if isinstance(error_code, str):
                error_code_lower = error_code.lower()
                if error_code_lower in UNRECOVERABLE_OAUTH_ERRORS:
                    return True
                # Check error_description for explicit phrases
                error_desc = error_data.get("error_description", "").lower()
                if any(phrase in error_desc for phrase in UNRECOVERABLE_ERROR_PHRASES):
                    return True

            # Handle nested API style: {"error": {"code": "token_expired", "message": "..."}}
            elif isinstance(error_code, dict):
                nested_code = error_code.get("code", "").lower()
                if nested_code in UNRECOVERABLE_OAUTH_ERRORS:
                    return True
                # Check nested message for explicit phrases
                nested_message = error_code.get("message", "").lower()
                if any(
                    phrase in nested_message for phrase in UNRECOVERABLE_ERROR_PHRASES
                ):
                    return True

        except ValueError, AttributeError:
            pass

    return False


def _is_transient_error(response: Any) -> bool:
    """Check if an error is likely transient (can be retried).

    Args:
        response: The requests Response object from a failed token refresh.

    Returns:
        True if the error appears to be transient (network/server issues).
    """
    # 5xx server errors are transient
    if 500 <= response.status_code < 600:
        return True
    # 429 rate limit is transient
    if response.status_code == 429:
        return True
    # 400 with non-unrecoverable error might be transient
    if response.status_code == 400:
        return not _is_unrecoverable_token_error(response)
    return False


def is_token_expired(tokens: dict[str, Any]) -> bool:
    expires_at_value = _get_expires_at_value(tokens)
    if expires_at_value is None:
        return False
    buffer_seconds = _calculate_refresh_buffer(tokens.get("expires_in"))
    return time.time() >= expires_at_value - buffer_seconds


def update_claude_code_model_tokens(access_token: str) -> bool:
    try:
        claude_models = load_claude_models()
        if not claude_models:
            return False

        updated = False
        for config in claude_models.values():
            if config.get("oauth_source") != "claude-code-plugin":
                continue
            custom_endpoint = config.get("custom_endpoint")
            if not isinstance(custom_endpoint, dict):
                continue
            custom_endpoint["api_key"] = access_token
            updated = True

        if updated:
            return save_claude_models(claude_models)
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Failed to update Claude model tokens: %s", exc)
    return False


def refresh_access_token(force: bool = False) -> str | None:
    """Refresh the access token using the refresh token.

    On successful refresh, the access token is saved and model tokens updated.
    Errors are classified as:
    - Unrecoverable (401, invalid_grant, etc.): Log user-friendly warning
    - Transient (5xx, 429, network issues): Log quietly at debug level
    - Ambiguous: Log at debug level without alarming the user

    Args:
        force: Force refresh even if token is not yet expired.

    Returns:
        New access token if refresh succeeded, None otherwise.
    """
    tokens = load_stored_tokens()
    if not tokens:
        return None

    if not force and not is_token_expired(tokens):
        return tokens.get("access_token")

    refresh_token = tokens.get("refresh_token")
    if not refresh_token:
        logger.debug("No refresh_token available")
        return None

    payload = {
        "grant_type": "refresh_token",
        "client_id": CLAUDE_CODE_OAUTH_CONFIG["client_id"],
        "refresh_token": refresh_token,
    }

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
    }

    try:
        response = requests.post(
            CLAUDE_CODE_OAUTH_CONFIG["token_url"],
            json=payload,
            headers=headers,
            timeout=30,
        )
        if response.status_code == 200:
            content_type = response.headers.get("content-type", "")
            if not content_type.startswith("application/json"):
                logger.error(
                    "Token refresh returned non-JSON response (Content-Type: %s). "
                    "Response body omitted for security.",
                    content_type,
                )
                return None
            try:
                new_tokens = response.json()
            except (ValueError, json.JSONDecodeError) as e:
                logger.error("Failed to parse token refresh response as JSON: %s", e)
                return None
            tokens["access_token"] = new_tokens.get("access_token")
            tokens["refresh_token"] = new_tokens.get("refresh_token", refresh_token)
            expires_in_value = new_tokens.get("expires_in")
            if expires_in_value is None:
                expires_in_value = tokens.get("expires_in")
            if expires_in_value is not None:
                tokens["expires_in"] = expires_in_value
                tokens["expires_at"] = _calculate_expires_at(expires_in_value)
            if save_tokens(tokens):
                update_claude_code_model_tokens(tokens["access_token"])
                return tokens["access_token"]
        else:
            # Classify error for appropriate logging
            # SECURITY: Never log response body - it may contain tokens or sensitive data
            if _is_unrecoverable_token_error(response):
                logger.warning(
                    "Claude token refresh failed with unrecoverable error (%s). "
                    "Tokens may need re-authentication.",
                    response.status_code,
                )
            elif _is_transient_error(response):
                logger.debug(
                    "Claude token refresh failed (transient %s)",
                    response.status_code,
                )
            else:
                # Ambiguous/unclassified error - log quietly
                logger.debug(
                    "Claude token refresh failed (%s)",
                    response.status_code,
                )
    except requests.exceptions.Timeout:
        logger.debug("Claude token refresh timed out (transient)")
    except requests.exceptions.ConnectionError:
        logger.debug("Claude token refresh connection error (transient)")
    except requests.exceptions.RequestException as exc:
        logger.debug("Claude token refresh request error (transient): %s", exc)
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Unexpected Claude token refresh error: %s", exc)
    return None


def get_valid_access_token() -> str | None:
    """Get a valid access token, refreshing if needed.

    This function respects Claude's existing semantics where a still-valid
    access token may continue to be used until actual expiry, even if the
    proactive refresh buffer has been exceeded.

    Args:
        None

    Returns:
        Valid access token string, or None if not authenticated or refresh failed.
    """
    tokens = load_stored_tokens()
    if not tokens:
        logger.debug("No stored Claude Code OAuth tokens found")
        return None

    access_token = tokens.get("access_token")
    if not access_token:
        logger.debug("No access_token in stored tokens")
        return None

    if is_token_expired(tokens):
        logger.info("Claude Code OAuth token expired, attempting refresh")
        refreshed = refresh_access_token()
        if refreshed:
            return refreshed
        if not _is_token_actually_expired(tokens):
            # Token is still technically valid - use it but warn once
            logger.debug(
                "Claude Code token refresh failed; using existing access token until expiry"
            )
            return access_token
        logger.warning(
            "Claude Code token refresh failed and token has expired. "
            "Run /claude-code-auth to re-authenticate."
        )
        return None

    return access_token


def save_tokens(tokens: dict[str, Any]) -> bool:
    # SECURITY: tokens stored with 0o600 permissions only. For enhanced security,
    # consider using the 'keyring' package for OS-level encryption.
    # SECURITY FIX: Use os.open with explicit mode to create file with correct
    # permissions atomically, avoiding TOCTOU race condition.
    try:
        token_path = get_token_storage_path()
        from code_puppy.config_paths import assert_write_allowed

        assert_write_allowed(token_path, "save_claude_oauth_tokens")
        fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(tokens, handle, indent=2)
        except:
            os.close(fd)
            raise
        logger.debug(f"Saved OAuth tokens to {token_path} with 0o600 permissions")
        return True
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Failed to save tokens: %s", exc)
        return False


def load_claude_models() -> dict[str, Any]:
    try:
        models_path = get_claude_models_path()
        if models_path.exists():
            with open(models_path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
            if isinstance(data, dict):
                blocked = [k for k in data if _is_blocked_claude_model(k)]
                if blocked:
                    logger.info(
                        "Skipping blocked models from claude_models.json: %s",
                        blocked,
                    )
                    for k in blocked:
                        data.pop(k, None)
            return data
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Failed to load Claude models: %s", exc)
    return {}


def load_claude_models_filtered() -> dict[str, Any]:
    """Load Claude models and filter to only the latest versions.

    This loads the stored models and applies the same filtering logic
    used during saving to ensure only the latest haiku, sonnet, and opus
    models are returned.
    """
    try:
        all_models = load_claude_models()
        if not all_models:
            return {}

        # Extract model names from the configuration
        model_names = []
        for name, config in all_models.items():
            if config.get("oauth_source") == "claude-code-plugin":
                model_names.append(config.get("name", ""))
            else:
                # For non-OAuth models, use the full key
                model_names.append(name)

        # Filter to only latest models
        latest_names = set(
            filter_latest_claude_models(
                model_names, max_per_family={"default": 1, "opus": 6}
            )
        )

        # Return only the filtered models
        filtered_models = {}
        for name, config in all_models.items():
            model_name = config.get("name", name)
            if model_name in latest_names:
                filtered_models[name] = config

        logger.info(
            "Loaded %d models, filtered to %d latest models",
            len(all_models),
            len(filtered_models),
        )
        return filtered_models

    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Failed to load and filter Claude models: %s", exc)
    return {}


def save_claude_models(models: dict[str, Any]) -> bool:
    # SECURITY: model configs contain API keys - use 0o600 permissions.
    # SECURITY FIX: Use os.open with explicit mode to create file with correct
    # permissions atomically, avoiding TOCTOU race condition.
    try:
        models_path = get_claude_models_path()
        from code_puppy.config_paths import assert_write_allowed

        assert_write_allowed(models_path, "save_claude_models")
        fd = os.open(models_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(models, handle, indent=2)
        except:
            os.close(fd)
            raise
        return True
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Failed to save Claude models: %s", exc)
        return False


def exchange_code_for_tokens(
    auth_code: str, context: OAuthContext
) -> dict[str, Any] | None:
    if not context.redirect_uri:
        raise RuntimeError("Redirect URI missing from OAuth context")

    payload = {
        "grant_type": "authorization_code",
        "client_id": CLAUDE_CODE_OAUTH_CONFIG["client_id"],
        "code": auth_code,
        "state": context.state,
        "code_verifier": context.code_verifier,
        "redirect_uri": context.redirect_uri,
    }

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
    }

    logger.info("Exchanging code for tokens: %s", CLAUDE_CODE_OAUTH_CONFIG["token_url"])
    logger.debug("Payload keys: %s", list(payload.keys()))
    logger.debug("Headers: %s", headers)
    try:
        response = requests.post(
            CLAUDE_CODE_OAUTH_CONFIG["token_url"],
            json=payload,
            headers=headers,
            timeout=30,
        )
        logger.info("Token exchange response: %s", response.status_code)
        # SECURITY: Never log response.text directly - it may contain tokens.
        # Log only response keys after redaction for safe debugging.
        if response.status_code == 200:
            content_type = response.headers.get("content-type", "")
            if not content_type.startswith("application/json"):
                logger.error(
                    "Token exchange returned non-JSON response (Content-Type: %s). "
                    "Response body omitted for security.",
                    content_type,
                )
                return None
            try:
                token_data = response.json()
            except (ValueError, json.JSONDecodeError) as e:
                logger.error("Failed to parse token exchange response as JSON: %s", e)
                return None
            # SECURITY: Log only the keys, not values - tokens are sensitive
            logger.debug("Token response keys: %s", sorted(token_data.keys()))
            token_data["expires_at"] = _calculate_expires_at(
                token_data.get("expires_in")
            )
            return token_data
        # SECURITY: Never log response body on error - it may contain partial tokens
        logger.warning("Token exchange failed: status=%s", response.status_code)
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Token exchange error: %s", exc)
    return None


def filter_latest_claude_models(
    models: list[str], max_per_family: int | dict[str, int] = 2
) -> list[str]:
    """Filter models to keep the top N latest haiku, sonnet, and opus.

    Parses model names in the format claude-{family}-{major}-{minor}-{date}
    and returns the top ``max_per_family`` versions of each family
    (haiku, sonnet, opus), sorted newest-first.

    Args:
        models: List of model name strings to filter.
        max_per_family: Either a single int applied to all families, or a dict
            mapping family name to its limit (e.g. ``{"opus": 3}``). Families
            not present in the dict fall back to ``"default"`` key, or ``2``.
    """
    # Collect all parsed models per family
    # family -> list of (model_name, major, minor, date)
    family_models: dict[str, list[tuple[str, int, int, int]]] = {}

    for model_name in models:
        # Pattern 1: claude-{family}-{major}[-{num1}][-{num2}]
        # Covers all modern naming variants:
        #   claude-opus-4-7              → major=4, minor=7 (latest alias)
        #   claude-opus-4-5-20251101     → major=4, minor=5, date=20251101
        #   claude-opus-4-20250514       → major=4, date=20250514 (no minor)
        match = re.match(
            r"claude-(haiku|sonnet|opus)-(\d+)(?:-(\d+))?(?:-(\d+))?$",
            model_name,
        )
        if match:
            family = match.group(1)
            major = int(match.group(2))
            g3 = match.group(3)
            g4 = match.group(4)

            if g3 is None:
                # Just claude-{family}-{major}
                minor, date = 0, 99999999
            elif g4 is not None:
                # Both present: claude-{family}-{major}-{minor}-{date}
                minor, date = int(g3), int(g4)
            elif len(g3) >= 6:
                # Long number is a date: claude-{family}-{major}-{date}
                minor, date = 0, int(g3)
            else:
                # Short number is minor: claude-{family}-{major}-{minor}
                minor, date = int(g3), 99999999

            family_models.setdefault(family, []).append(
                (model_name, major, minor, date)
            )
            continue

        # Pattern 1b: claude-{family}-{major}.{minor}[-{date}] (dot separator)
        # e.g., claude-haiku-3.5-20241022
        match = re.match(
            r"claude-(haiku|sonnet|opus)-(\d+)\.(\d+)(?:-(\d+))?$",
            model_name,
        )
        if match:
            family = match.group(1)
            major = int(match.group(2))
            minor = int(match.group(3))
            date = int(match.group(4)) if match.group(4) else 99999999
            family_models.setdefault(family, []).append(
                (model_name, major, minor, date)
            )
            continue

        # Pattern 2: claude-{major}-{family}[-{date}] (legacy naming)
        # e.g., claude-3-haiku-20240307
        match = re.match(r"claude-(\d+)-(haiku|sonnet|opus)(?:-(\d+))?$", model_name)
        if match:
            major = int(match.group(1))
            family = match.group(2)
            date = int(match.group(3)) if match.group(3) else 99999999
            family_models.setdefault(family, []).append((model_name, major, 0, date))
            continue

        # Model doesn't match any known pattern — skip it

    # Sort each family descending and keep the top N
    filtered: list[str] = []
    for family, family_entries in family_models.items():
        if isinstance(max_per_family, dict):
            limit = max_per_family.get(family, max_per_family.get("default", 2))
        else:
            limit = max_per_family
        family_entries.sort(key=lambda e: (e[1], e[2], e[3]), reverse=True)
        for entry in family_entries[:limit]:
            filtered.append(entry[0])

    logger.info(
        "Filtered %d models to %d latest models (max_per_family=%s): %s",
        len(models),
        len(filtered),
        max_per_family,
        filtered,
    )
    return filtered


def fetch_claude_code_models(access_token: str) -> list[str | None]:
    try:
        api_url = f"{CLAUDE_CODE_OAUTH_CONFIG['api_base_url']}/v1/models"
        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "anthropic-version": CLAUDE_CODE_OAUTH_CONFIG.get(
                "anthropic_version", "2023-06-01"
            ),
        }
        response = requests.get(api_url, headers=headers, timeout=30)
        if response.status_code == 200:
            content_type = response.headers.get("content-type", "")
            if not content_type.startswith("application/json"):
                logger.error(
                    "Models fetch returned non-JSON response (Content-Type: %s). "
                    "Response body omitted for security.",
                    content_type,
                )
                return None
            try:
                data = response.json()
            except (ValueError, json.JSONDecodeError) as e:
                logger.error("Failed to parse models response as JSON: %s", e)
                return None
            if isinstance(data.get("data"), list):
                models: list[str] = []
                for model in data["data"]:
                    name = model.get("id") or model.get("name")
                    if name:
                        models.append(name)
                return models
        else:
            # SECURITY: Never log response body - it may contain sensitive data
            logger.error("Failed to fetch models: status=%s", response.status_code)
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Error fetching Claude Code models: %s", exc)
    return None


def _build_model_entry(model_name: str, access_token: str, context_length: int) -> dict:
    """Build a single model config entry for claude_models.json."""
    supported_settings = [
        "temperature",
        "extended_thinking",
        "budget_tokens",
        "interleaved_thinking",
    ]

    # All opus models support the effort setting
    lower = model_name.lower()
    if "opus" in lower:
        supported_settings.append("effort")

    return {
        "type": "claude_code",
        "name": model_name,
        "custom_endpoint": {
            "url": CLAUDE_CODE_OAUTH_CONFIG["api_base_url"],
            "api_key": access_token,
            "headers": {
                "anthropic-beta": "oauth-2025-04-20,interleaved-thinking-2025-05-14",
                "x-app": "cli",
                "User-Agent": "claude-cli/2.0.61 (external, cli)",
            },
        },
        "context_length": context_length,
        "oauth_source": "claude-code-plugin",
        "supported_settings": supported_settings,
    }


def add_models_to_extra_config(models: list[str]) -> bool:
    try:
        # Drop permanently-blocked entries before any further processing.
        models = _filter_blocked_claude_models(models)

        # Start fresh - overwrite the file on every auth instead of loading existing
        claude_models = {}
        added = 0
        access_token = get_valid_access_token() or ""
        prefix = CLAUDE_CODE_OAUTH_CONFIG["prefix"]
        default_ctx = CLAUDE_CODE_OAUTH_CONFIG["default_context_length"]
        long_ctx = CLAUDE_CODE_OAUTH_CONFIG["long_context_length"]
        long_ctx_models = CLAUDE_CODE_OAUTH_CONFIG["long_context_models"]

        for model_name in models:
            prefixed = f"{prefix}{model_name}"
            claude_models[prefixed] = _build_model_entry(
                model_name, access_token, default_ctx
            )
            added += 1

            # Create a "-long" variant with extended context for eligible models
            if model_name in long_ctx_models:
                long_prefixed = f"{prefix}{model_name}-long"
                claude_models[long_prefixed] = _build_model_entry(
                    model_name, access_token, long_ctx
                )
                added += 1

        if save_claude_models(claude_models):
            logger.info("Added %s Claude Code models", added)
            return True
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Error adding models to config: %s", exc)
    return False


def remove_claude_code_models() -> int:
    try:
        claude_models = load_claude_models()
        to_remove = [
            name
            for name, config in claude_models.items()
            if config.get("oauth_source") == "claude-code-plugin"
        ]
        if not to_remove:
            return 0
        for model_name in to_remove:
            claude_models.pop(model_name, None)
        if save_claude_models(claude_models):
            return len(to_remove)
    except Exception as exc:  # pragma: no cover - defensive logging
        logger.error("Error removing Claude Code models: %s", exc)
    return 0
