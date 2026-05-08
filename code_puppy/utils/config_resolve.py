"""Resolve configuration values from shell commands, environment variables, or literals.

Ported from oh-my-pi's resolve-config-value.ts pattern.

Supports three resolution modes:
1. Shell command: Values starting with ``!`` execute the rest as a shell command
   and use stdout (result is cached for the process lifetime).
2. Environment variable: Values matching an env var name are resolved from the environment.
3. Literal: Everything else is used as-is.

This enables secure credential management via tools like 1Password CLI,
AWS SSM, HashiCorp Vault, etc. without hardcoding secrets.

Usage:
    from code_puppy.utils.config_resolve import resolve_config_value

    # Shell command (cached)
    api_key = await resolve_config_value("!op read 'OpenAI API Key'")

    # Environment variable fallback
    api_key = await resolve_config_value("OPENAI_API_KEY")

    # Literal value
    api_key = await resolve_config_value("sk-abc123...")

Security note:
    Shell commands are executed with the current user's privileges.
    Only use this for values that the user has explicitly configured
    in their own config files.
"""

import asyncio
import logging
import os
import subprocess
import threading

__all__ = [
    "resolve_config_value",
    "resolve_config_value_sync",
    "resolve_headers",
    "resolve_headers_sync",
    "clear_config_value_cache",
]

logger = logging.getLogger(__name__)

# Cache for successful shell command results (persists for process lifetime).
_command_result_cache: dict[str, str] = {}
_cache_lock = threading.Lock()

# De-duplicates concurrent async executions for the same command.
_command_in_flight: dict[str, asyncio.Future[str | None]] = {}
_in_flight_lock = asyncio.Lock()

# Default timeout for shell commands (seconds).
_DEFAULT_TIMEOUT = 10


async def resolve_config_value(
    config: str,
    *,
    timeout: int = _DEFAULT_TIMEOUT,
) -> str | None:
    """Resolve a config value (API key, header value, etc.) to an actual value.

    Resolution order:
    1. If starts with ``!``, execute the rest as a shell command and use stdout
       (result is cached for the process lifetime).
    2. Otherwise, check environment variable first, then treat as literal.

    Args:
        config: The raw config value string.
        timeout: Timeout in seconds for shell command execution.

    Returns:
        The resolved value, or None if resolution fails (command error,
        empty output, etc.).
    """
    if not config:
        return None

    if config.startswith("!"):
        return await _execute_command_async(config, timeout=timeout)

    # Check environment variable, fall back to literal
    env_value = os.environ.get(config)
    return env_value or config


def resolve_config_value_sync(
    config: str,
    *,
    timeout: int = _DEFAULT_TIMEOUT,
) -> str | None:
    """Synchronous version of :func:`resolve_config_value`.

    Suitable for use in sync code paths (e.g., model factory initialization).

    Args:
        config: The raw config value string.
        timeout: Timeout in seconds for shell command execution.

    Returns:
        The resolved value, or None if resolution fails.
    """
    if not config:
        return None

    if config.startswith("!"):
        return _execute_command_sync(config, timeout=timeout)

    env_value = os.environ.get(config)
    return env_value or config


async def _execute_command_async(
    command_config: str, *, timeout: int = _DEFAULT_TIMEOUT
) -> str | None:
    """Execute a shell command for config resolution (async, cached, deduped).

    Args:
        command_config: Full config string starting with ``!``.
        timeout: Timeout in seconds.

    Returns:
        Trimmed stdout output, or None on error/empty.
    """
    # Check cache first (thread-safe read)
    with _cache_lock:
        cached = _command_result_cache.get(command_config)
        if cached is not None:
            return cached

    # Deduplicate concurrent requests for the same command
    async with _in_flight_lock:
        # Re-check cache after acquiring lock
        with _cache_lock:
            cached = _command_result_cache.get(command_config)
            if cached is not None:
                return cached

        existing = _command_in_flight.get(command_config)
        if existing is not None:
            # Another task is already resolving this — wait for it
            return await existing

        # Create a future to represent this resolution
        loop = asyncio.get_running_loop()
        future: asyncio.Future[str | None] = loop.create_future()
        _command_in_flight[command_config] = future

    # Execute outside the lock
    try:
        command = command_config[1:]  # Strip leading "!"
        result = await _run_shell_command_async(command, timeout=timeout)
        if result is not None:
            with _cache_lock:
                _command_result_cache[command_config] = result
        future.set_result(result)
        return result
    except Exception as exc:
        logger.debug("Config command failed: %s: %s", command_config, exc)
        future.set_result(None)
        return None
    finally:
        async with _in_flight_lock:
            _command_in_flight.pop(command_config, None)


def _execute_command_sync(
    command_config: str, *, timeout: int = _DEFAULT_TIMEOUT
) -> str | None:
    """Execute a shell command for config resolution (sync, cached).

    Args:
        command_config: Full config string starting with ``!``.
        timeout: Timeout in seconds.

    Returns:
        Trimmed stdout output, or None on error/empty.
    """
    with _cache_lock:
        cached = _command_result_cache.get(command_config)
        if cached is not None:
            return cached

    command = command_config[1:]  # Strip leading "!"
    result = _run_shell_command_sync(command, timeout=timeout)
    if result is not None:
        with _cache_lock:
            _command_result_cache[command_config] = result
    return result


async def _run_shell_command_async(command: str, *, timeout: int) -> str | None:
    """Run a shell command asynchronously and return trimmed stdout.

    Args:
        command: Shell command to execute.
        timeout: Timeout in seconds.

    Returns:
        Trimmed stdout, or None on error/timeout/empty.
    """
    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0:
            logger.debug(
                "Config command exited %d: %s (stderr: %s)",
                proc.returncode,
                command,
                stderr.decode("utf-8", errors="replace").strip()[:200],
            )
            return None
        trimmed = stdout.decode("utf-8", errors="replace").strip()
        return trimmed if trimmed else None
    except asyncio.TimeoutError:
        logger.debug("Config command timed out after %ds: %s", timeout, command)
        return None
    except OSError as exc:
        logger.debug("Config command OS error: %s: %s", command, exc)
        return None


def _run_shell_command_sync(command: str, *, timeout: int) -> str | None:
    """Run a shell command synchronously and return trimmed stdout.

    Args:
        command: Shell command to execute.
        timeout: Timeout in seconds.

    Returns:
        Trimmed stdout, or None on error/timeout/empty.
    """
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            timeout=timeout,
            text=True,
        )
        if result.returncode != 0:
            logger.debug(
                "Config command exited %d: %s (stderr: %s)",
                result.returncode,
                command,
                result.stderr.strip()[:200],
            )
            return None
        trimmed = result.stdout.strip()
        return trimmed if trimmed else None
    except subprocess.TimeoutExpired:
        logger.debug("Config command timed out after %ds: %s", timeout, command)
        return None
    except OSError as exc:
        logger.debug("Config command OS error: %s: %s", command, exc)
        return None


async def resolve_headers(
    headers: dict[str, str] | None,
    *,
    timeout: int = _DEFAULT_TIMEOUT,
) -> dict[str, str] | None:
    """Resolve all header values using the same resolution logic as API keys.

    Args:
        headers: Dict of header name to config value (may contain ``!`` commands).
        timeout: Timeout in seconds for shell commands.

    Returns:
        Dict with resolved values, or None if all headers resolved to None.
    """
    if not headers:
        return None
    resolved: dict[str, str] = {}
    for key, value in headers.items():
        resolved_value = await resolve_config_value(value, timeout=timeout)
        if resolved_value:
            resolved[key] = resolved_value
    return resolved if resolved else None


def resolve_headers_sync(
    headers: dict[str, str] | None,
    *,
    timeout: int = _DEFAULT_TIMEOUT,
) -> dict[str, str] | None:
    """Synchronous version of :func:`resolve_headers`.

    Args:
        headers: Dict of header name to config value.
        timeout: Timeout in seconds for shell commands.

    Returns:
        Dict with resolved values, or None if empty.
    """
    if not headers:
        return None
    resolved: dict[str, str] = {}
    for key, value in headers.items():
        resolved_value = resolve_config_value_sync(value, timeout=timeout)
        if resolved_value:
            resolved[key] = resolved_value
    return resolved if resolved else None


def clear_config_value_cache() -> None:
    """Clear the config value command cache.

    Useful for testing or when credentials rotate.
    """
    with _cache_lock:
        _command_result_cache.clear()
    logger.debug("Config value cache cleared")
