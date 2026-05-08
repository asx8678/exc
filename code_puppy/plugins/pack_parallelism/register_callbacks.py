"""
Pack Leader max-parallelism constraint plugin.

Reads a configured ``max_parallelism`` value and exposes a
``/pack-parallel N`` slash command to override it per-session, while
enforcing the limit at runtime via RunLimiter.

Permanent config (TOML):
    ~/.code_puppy/pack_parallelism.toml

    [pack_leader]
    max_parallelism = 6          # default: 6
    allow_parallel = true        # if false, forces limit=1
    run_wait_timeout = null      # seconds before rejecting (null = wait forever)

Per-session override (slash command):
    /pack-parallel 4             # set to 4 for this session
    /pack-parallel               # show current value
"""

import logging
from pathlib import Path

from code_puppy.callbacks import register_callback
from code_puppy.config_paths import safe_atomic_write

# Import RunLimiter for runtime enforcement
try:
    from .run_limiter import get_run_limiter, update_run_limiter_config

    _RUN_LIMITER_AVAILABLE = True
except ImportError:
    _RUN_LIMITER_AVAILABLE = False

    # Stubs for graceful degradation
    def get_run_limiter():  # type: ignore[misc]
        return None

    def update_run_limiter_config(**kwargs):  # type: ignore[misc]
        pass


logger = logging.getLogger(__name__)

# NOTE(code_puppy-154.3): The authoritative concurrency state lives in the
# Elixir GenServer ``CodePuppyControl.Plugins.PackParallelism`` when the
# control plane is connected. Python must sync its config to the GenServer
# (via ``run_limiter.set_limit``) before first acquire and on every runtime
# update so the two stay consistent. The Python local fallback retains the old
# semaphore+counter approach for disconnected mode only.


# Respects pup-ex isolation (ADR-003) — resolves under active home
_CONFIG_PATH: Path | None = None


def _config_path() -> Path:
    """Return the pack parallelism config path under the active home.

    Honors a patched ``_CONFIG_PATH`` module attribute when present so tests
    can override the location without depending on the active home.
    """
    if _CONFIG_PATH is not None:
        return _CONFIG_PATH

    from code_puppy.config_paths import resolve_path

    return resolve_path("pack_parallelism.toml")


_BUILTIN_DEFAULT = 6

# Module-level per-session override; None means "use config file value"
_session_max: int | None = None

# Cached result of reading the config file so we only parse it once per session
_cached_config: int | None = None


def _parse_toml_manual(content: str) -> dict:
    """Minimal TOML parser for pack_leader.max_parallelism only.

    Handles the simple case of extracting values from [pack_leader] section
    without requiring external TOML libraries.
    """
    result: dict = {}
    current_section: str | None = None

    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # Section header: [section_name]
        if stripped.startswith("[") and stripped.endswith("]"):
            current_section = stripped[1:-1].strip()
            if current_section not in result:
                result[current_section] = {}
            continue

        # Key-value pair: key = value
        if "=" in stripped and current_section is not None:
            key, _, value = stripped.partition("=")
            key = key.strip()
            value = value.strip()
            # Remove quotes if present
            if (value.startswith('"') and value.endswith('"')) or (
                value.startswith("'") and value.endswith("'")
            ):
                value = value[1:-1]
            # Try to convert to int if possible
            try:
                value = int(value)
            except ValueError:
                pass
            result[current_section][key] = value

    return result


def _read_config_max() -> int:
    """Read max_parallelism from the TOML config, with graceful fallback.

    The result is cached after the first read so the file is not parsed on
    every prompt injection.
    """
    global _cached_config
    if _cached_config is not None:
        return _cached_config

    result = _BUILTIN_DEFAULT
    if not _config_path().exists():
        _cached_config = result
        return _cached_config

    # Try TOML libraries first, fall back to manual parser
    try:
        import tomllib  # Python 3.11+

        with open(_config_path(), "rb") as fh:
            data = tomllib.load(fh)
        result = int(
            data.get("pack_leader", {}).get("max_parallelism", _BUILTIN_DEFAULT)
        )
    except ImportError:
        # tomllib not available (Python < 3.11), try tomli
        try:
            import tomli

            with open(_config_path(), "rb") as fh:
                data = tomli.load(fh)
            result = int(
                data.get("pack_leader", {}).get("max_parallelism", _BUILTIN_DEFAULT)
            )
        except ImportError:
            # No TOML library available, use manual parser
            try:
                with open(_config_path(), "r", encoding="utf-8") as fh:
                    content = fh.read()
                data = _parse_toml_manual(content)
                result = int(
                    data.get("pack_leader", {}).get("max_parallelism", _BUILTIN_DEFAULT)
                )
            except Exception as exc:
                logger.warning(
                    "pack_parallelism: manual parser failed for %s: %s",
                    _config_path(),
                    exc,
                )
                result = _BUILTIN_DEFAULT
    except Exception as exc:
        logger.warning(
            "pack_parallelism: could not read config %s: %s", _config_path(), exc
        )
        result = _BUILTIN_DEFAULT

    _cached_config = result
    return _cached_config


def _write_config_max(value: int) -> bool:
    """Write max_parallelism to the TOML config file, preserving other content.

    Writes atomically using a temp file and os.replace(). Creates the
    config directory if it doesn't exist. On failure, logs a warning
    but does not crash (fail gracefully per rule #4).

    Returns True if the write succeeded, False if it failed.
    """
    global _cached_config
    try:
        lines: list[str] = []
        pack_leader_idx: int | None = None
        max_parallelism_idx: int | None = None

        if _config_path().exists():
            with open(_config_path(), "r", encoding="utf-8") as fh:
                lines = fh.readlines()

            # Find [pack_leader] section and max_parallelism key
            in_pack_leader = False
            for i, line in enumerate(lines):
                stripped = line.strip()
                # Strip inline comments: "[pack_leader] # comment" → "[pack_leader]"
                header_part = (
                    stripped.split("#")[0].rstrip() if "#" in stripped else stripped
                )
                if header_part.startswith("[") and header_part.endswith("]"):
                    section_name = header_part[1:-1].strip()
                    if section_name == "pack_leader":
                        pack_leader_idx = i
                        in_pack_leader = True
                    else:
                        in_pack_leader = False
                    continue

                if in_pack_leader and "=" in stripped:
                    key = stripped.split("=")[0].strip()
                    if key == "max_parallelism":
                        max_parallelism_idx = i
                        break  # Found the key we need to update

        # Build new lines
        new_lines = lines.copy() if lines else []

        if pack_leader_idx is None:
            # No [pack_leader] section exists, append it
            if new_lines and not new_lines[-1].endswith("\n"):
                new_lines.append("\n")
            new_lines.append("[pack_leader]\n")
            new_lines.append(f"max_parallelism = {value}\n")
        elif max_parallelism_idx is not None:
            # Update existing max_parallelism line
            new_lines[max_parallelism_idx] = f"max_parallelism = {value}\n"
        else:
            # Section exists but no max_parallelism key, insert after section header
            insert_idx = pack_leader_idx + 1
            new_lines.insert(insert_idx, f"max_parallelism = {value}\n")

        # Write atomically through the isolation-aware helper
        safe_atomic_write(_config_path(), "".join(new_lines))

        # Invalidate cache so next read picks up the new value
        _cached_config = None
        return True

    except Exception as exc:
        logger.warning(
            "pack_parallelism: failed to write config %s: %s", _config_path(), exc
        )
        return False


def _effective_max() -> int:
    """Return the currently active max (session override > config file > builtin default)."""
    if _session_max is not None:
        return _session_max
    return _read_config_max()


# ---------------------------------------------------------------------------
# startup hook — display pack-parallel value on startup
# ---------------------------------------------------------------------------


def _on_startup():
    """Display current pack-parallel limit on startup.

    Also syncs the Python-side config to the Elixir GenServer when
    connected so the authoritative limiter initializes from the same
    pack_parallelism.toml config path.
    """
    try:
        from code_puppy.messaging import emit_info
    except ImportError:
        emit_info = print  # type: ignore[assignment]

    max_p = _effective_max()
    source = "config" if _session_max is None else "session"
    emit_info(f"🐺 Pack parallelism limit: {max_p} (from {source})")

    # code_puppy-154.3: Sync Python config to Elixir GenServer on startup
    # so the authoritative limiter uses the same pack_parallelism.toml values.
    try:
        from code_puppy.plugins.elixir_bridge import call_method, is_connected

        if is_connected():
            call_method(
                "run_limiter.set_limit",
                {"limit": max_p},
                timeout=5.0,
            )
            logger.debug(
                "pack_parallelism: synced limit %d to Elixir GenServer on startup",
                max_p,
            )
    except ImportError:
        pass
    except Exception as e:
        logger.debug("pack_parallelism: failed to sync to Elixir on startup: %s", e)


register_callback("startup", _on_startup)


# ---------------------------------------------------------------------------
# custom_command hook — /pack-parallel N
# ---------------------------------------------------------------------------

_COMMAND_NAMES = {"pack-parallel", "pack-par"}


def _invalidate_agent_caches(previous_val: int | None, new_val: int) -> None:
    """Invalidate agent caches to ensure new MAX_PARALLEL_AGENTS is reflected.

    Busts both the Rust-path cached system prompt and rebuilds the PydanticAgent
    instance with fresh instructions containing the updated value.
    """
    # Optimization: skip heavy reload if value hasn't actually changed
    if previous_val is not None and previous_val == new_val:
        return

    # Lazy import to avoid circular dependencies
    try:
        from code_puppy.agents.agent_manager import get_current_agent
    except ImportError:
        return  # Agent manager not available, skip cache invalidation

    try:
        agent = get_current_agent()
    except Exception:
        # No active agent or other error - cache invalidation is best-effort
        return

    if agent is None:
        return

    try:
        # Bust Rust-path cached system prompt (base_agent.py:1477-1483)
        if hasattr(agent, "_state") and hasattr(agent._state, "cached_system_prompt"):
            agent._state.cached_system_prompt = None

        # Rebuild PydanticAgent with fresh instructions (base_agent.py:1846-1878)
        if hasattr(agent, "reload_code_generation_agent"):
            agent.reload_code_generation_agent()
    except Exception:
        # Best-effort: never crash the slash command due to cache invalidation
        logger.debug(
            "pack_parallelism: cache invalidation failed (non-critical)", exc_info=True
        )


def _handle_command(command: str, name: str):
    """Handle /pack-parallel [N|status|reset|--session] slash command."""
    global _session_max, _cached_config

    if name not in _COMMAND_NAMES:
        return None  # not ours

    try:
        from code_puppy.messaging import emit_error, emit_info
    except ImportError:
        emit_info = print  # type: ignore[assignment]
        emit_error = print  # type: ignore[assignment]

    parts = command.strip().split()

    if len(parts) < 2:
        # No argument → show current value
        current = _effective_max()
        config_val = _read_config_max()
        source = (
            "session override"
            if _session_max is not None
            else f"config ({_config_path()})"
        )
        emit_info(
            f"🐺 Pack Leader max parallelism: **{current}** (from {source})\n"
            f"   Config file default: {config_val}\n"
            f"   Usage: /pack-parallel <N>          (saves as default)\n"
            f"          /pack-parallel <N> --session (this session only)\n"
            f"          /pack-parallel status\n"
            f"          /pack-parallel reset"
        )
        return True

    subcommand = parts[1].lower()

    # Handle status subcommand
    if subcommand == "status":
        if _RUN_LIMITER_AVAILABLE:
            limiter = get_run_limiter()
            # When Elixir GenServer is connected, display full authoritative
            # status from the GenServer (includes `available` count).
            try:
                from code_puppy.plugins.elixir_bridge import call_method, is_connected

                if is_connected():
                    result = call_method("run_limiter.status", {}, timeout=5.0)
                    emit_info(
                        f"🐺 RunLimiter status (Elixir GenServer — authoritative):\n"
                        f"   Active: {result.get('active', '?')}\n"
                        f"   Waiters: {result.get('waiters', '?')}\n"
                        f"   Limit: {result.get('limit', '?')}\n"
                        f"   Available: {result.get('available', '?')}"
                    )
                    return True
            except ImportError:
                pass
            except Exception:
                pass  # Fall through to local status

            # Local fallback
            emit_info(
                f"🐺 RunLimiter status (local fallback):\n"
                f"   Active: {limiter.active_count}\n"
                f"   Waiters: {limiter.waiters_count}\n"
                f"   Limit: {limiter.effective_limit}\n"
                f"   Available: {limiter.available_count}\n"
                f"   Wait timeout: {limiter._config.wait_timeout}s"
            )
        else:
            emit_error("RunLimiter not available")
        return True

    # Handle reset subcommand
    if subcommand == "reset":
        if _RUN_LIMITER_AVAILABLE:
            from .run_limiter import force_reset_limiter_state

            result = force_reset_limiter_state()
            emit_info(f"🐺 RunLimiter force-reset: {result}")
        else:
            emit_error("RunLimiter not available")
        return True

    # Try to parse as integer for set operation
    try:
        new_val = int(parts[1])
    except ValueError:
        emit_error(
            f"pack-parallel: '{parts[1]}' is not a valid integer or subcommand "
            f"(try 'status' or 'reset')"
        )
        return True

    if new_val < 1:
        emit_error("pack-parallel: value must be at least 1")
        return True

    if new_val > 32:
        emit_info(f"⚠️ /pack-parallel: {new_val} is very high, capping at 32")
        new_val = 32

    # Check for --session flag and reject unknown args
    extras = set(parts[2:])
    unknown = extras - {"--session"}
    if unknown:
        emit_error(
            f"pack-parallel: unknown argument(s): {', '.join(sorted(unknown))}. "
            f"Did you mean --session?"
        )
        return True
    session_only = "--session" in extras

    # Remember previous value for cache invalidation optimization
    previous_val = _effective_max()

    if session_only:
        # Session-only mode: don't write to disk
        _session_max = new_val
        source_msg = "(session only — will reset on restart)"
        saved_path_msg = ""
    else:
        # Default: persist to config file
        if _write_config_max(new_val):
            _cached_config = new_val  # Update cache directly
            _session_max = None  # Clear session override so config takes effect
            source_msg = "(saved as default)"
            saved_path_msg = f"\n   Saved to {_config_path()}"
        else:
            # Persistence failed — fall back to session-only
            _session_max = new_val
            source_msg = "(session only — failed to save to disk)"
            saved_path_msg = f"\n   ⚠️ Could not write to {_config_path()}"

    # Invalidate agent caches so the new value is reflected in prompts
    _invalidate_agent_caches(previous_val, new_val)

    # Also update the runtime limiter for immediate effect
    if _RUN_LIMITER_AVAILABLE:
        try:
            update_run_limiter_config(max_concurrent_runs=new_val)
            limiter = get_run_limiter()
            active = limiter.active_count if limiter else 0
            effective = limiter.effective_limit if limiter else new_val

            # code_puppy-154.3: Sync new limit to Elixir GenServer so the
            # authoritative limiter changes immediately when connected.
            try:
                from code_puppy.plugins.elixir_bridge import call_method, is_connected

                if is_connected():
                    result = call_method(
                        "run_limiter.set_limit",
                        {"limit": new_val},
                        timeout=5.0,
                    )
                    logger.debug(
                        "Synced limit %d to Elixir GenServer: %s", new_val, result
                    )
            except ImportError:
                pass
            except Exception as e:
                logger.debug("Failed to sync limit to Elixir: %s", e)
        except Exception as e:
            logger.debug("Failed to update runtime limiter: %s", e)
            active = "?"
            effective = new_val
    else:
        active = "?"
        effective = new_val

    emit_info(
        f"🐺 Pack Leader max parallelism → **{new_val}** {source_msg}\n"
        f"   Runtime limiter: effective={effective}, active={active}"
        f"{saved_path_msg}"
    )
    return True


register_callback("custom_command", _handle_command)


# ---------------------------------------------------------------------------
# custom_command_help hook
# ---------------------------------------------------------------------------


def _command_help() -> list[tuple[str, str]]:
    max_p = _effective_max()
    return [
        (
            "pack-parallel",
            f"Get/set Pack Leader max parallel agents (current: {max_p}). "
            f"Usage: /pack-parallel N [--session] | status | reset",
        ),
        ("pack-par", "Alias for /pack-parallel"),
        ("pack-parallel status", "Show RunLimiter active/waiting counts"),
        ("pack-parallel reset", "Emergency reset of stuck limiter state"),
    ]


register_callback("custom_command_help", _command_help)

logger.info("pack_parallelism plugin loaded (effective max=%d)", _effective_max())
