"""Lazy plugin loading system for code_puppy.

Plugins are discovered at startup but only imported when their callbacks are first triggered.
This reduces cold-start time by deferring heavy imports until they're actually needed.

SECURITY WARNING:
User plugins (from ~/.code_puppy/plugins/) execute arbitrary Python code with full system
privileges. A malicious plugin can perform any action the user can perform (delete files,
steal credentials, install malware, etc.). Only install plugins from trusted sources.
"""

import importlib
import importlib.util
import logging
import re
import sys
import threading
from collections.abc import Callable
from pathlib import Path

logger = logging.getLogger(__name__)


# Respects pup-ex isolation (ADR-003) — resolves under active home
def _user_plugins_dir() -> Path:
    """Return the user plugins directory under the active home.

    Honors a patched ``USER_PLUGINS_DIR`` module attribute when present so
    existing tests and callers can override the location explicitly.
    """
    override = globals().get("USER_PLUGINS_DIR")
    if override is not None:
        return Path(override)

    from code_puppy.config_paths import resolve_path

    return resolve_path("plugins")


def __getattr__(name: str):
    """Lazy resolution of env-sensitive module-level names.

    ``USER_PLUGINS_DIR`` is now computed on every access so that env-var
    changes (e.g. ``PUP_EX_HOME`` set after import) are always respected.
    """
    if name == "USER_PLUGINS_DIR":
        return _user_plugins_dir()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


# Track if plugins have already been discovered to prevent duplicate work
_PLUGINS_DISCOVERED = False

# Registry of lazy-loadable plugins: {phase: [(plugin_type, plugin_name, load_func), ...]}
# plugin_type is 'builtin' or 'user'
# load_func is a callable that performs the actual import and returns the module
_LAZY_PLUGIN_REGISTRY: dict[str, list[tuple[str, str, Callable]]] = {}

# Track which plugins have been fully loaded to prevent duplicate imports
_LOADED_PLUGINS: set[str] = set()

# Lock for thread-safe access to _LOADED_PLUGINS
_plugin_load_lock = threading.Lock()


def _create_loader_builtin(plugin_name: str, module_name: str) -> Callable:
    """Create a lazy loader function for a built-in plugin."""

    def _load():
        try:
            return importlib.import_module(module_name)
        except ImportError as e:
            logger.warning(f"Failed to lazy-load built-in plugin {plugin_name}: {e}")
            return None
        except Exception as e:
            logger.error(
                f"Unexpected error lazy-loading built-in plugin {plugin_name}: {e}"
            )
            return None

    return _load


def _validate_plugin_path(
    plugin_name: str,
    callbacks_file: Path,
    expected_base: Path,
) -> Path | None:
    """Validate that a plugin path is safe and within the expected directory.

    SECURITY: This function performs path traversal protection and symlink validation.

    Args:
        plugin_name: Name of the plugin.
        callbacks_file: Path to the register_callbacks.py file.
        expected_base: The expected base directory the file must be within.

    Returns:
        The resolved absolute path if valid, None if unsafe.
    """
    try:
        callbacks_abs = callbacks_file.resolve()

        # Check that resolved path is within the plugins directory using proper path containment
        try:
            callbacks_abs.relative_to(expected_base)
        except ValueError:
            logger.error(
                "SECURITY: User plugin '%s' resolves to '%s' which is outside expected "
                "plugin directory '%s'. Refusing to create loader.",
                plugin_name,
                callbacks_abs,
                expected_base,
            )
            return None

        # SECURITY: Reject symlinks that escape the plugins directory
        if callbacks_file.is_symlink():
            try:
                link_target = callbacks_file.readlink()
                if link_target.is_absolute():
                    target_abs = link_target.resolve()
                    try:
                        target_abs.relative_to(expected_base)
                    except ValueError:
                        logger.error(
                            "SECURITY: User plugin '%s' has symlink pointing outside plugins "
                            "directory ('%s' -> '%s'). Refusing to create loader.",
                            plugin_name,
                            callbacks_file,
                            target_abs,
                        )
                        return None
            except (OSError, ValueError) as e:
                logger.error(
                    "SECURITY: Could not verify symlink for user plugin '%s': %s. "
                    "Refusing to create loader.",
                    plugin_name,
                    e,
                )
                return None

        # Validate it's a proper file (not a directory or special file)
        if not callbacks_abs.is_file():
            logger.error(
                "SECURITY: User plugin '%s' path is not a regular file: %s. "
                "Refusing to create loader.",
                plugin_name,
                callbacks_abs,
            )
            return None

        return callbacks_abs

    except (OSError, ValueError) as e:
        logger.error(
            "SECURITY: Could not resolve path for user plugin '%s': %s. "
            "Refusing to create loader.",
            plugin_name,
            e,
        )
        return None


def _create_loader_user(
    plugin_name: str,
    callbacks_file: Path,
    base_dir: Path | None = None,
) -> Callable:
    """Create a lazy loader function for a user plugin.

    SECURITY: User plugins execute with full system privileges via exec_module().
    A malicious plugin can perform any action the user account can perform.

    Args:
        plugin_name: Name of the plugin.
        callbacks_file: Path to the register_callbacks.py file.
        base_dir: Optional base directory for path traversal protection.
                  Defaults to active-home/plugins if not provided.

    Returns:
        A callable that loads the plugin, or a no-op loader if the plugin file is unsafe.
    """
    # SECURITY: Path traversal protection - validate path before creating loader
    expected_base = (base_dir or _user_plugins_dir()).resolve()

    # Validate the path - use the validated path for all future operations
    validated_path = _validate_plugin_path(plugin_name, callbacks_file, expected_base)
    if validated_path is None:
        return lambda: None  # Return no-op loader

    def _load():
        try:
            # SECURITY: Check if user plugins are enabled
            from code_puppy.config import get_value

            user_plugins_enabled = get_value("enable_user_plugins")
            if user_plugins_enabled is None:
                # Default to disabled - require explicit opt-in
                logger.warning(
                    f"SECURITY: User plugin '{plugin_name}' not loaded. "
                    f"User plugins are disabled by default. Set enable_user_plugins=true "
                    f"in config to enable (executes untrusted code with full privileges)."
                )
                return None

            # Check allowlist if configured
            allowed_plugins = get_value("allowed_user_plugins")
            if allowed_plugins:
                allowed = [p.strip() for p in allowed_plugins.split(",")]
                if plugin_name not in allowed:
                    logger.warning(
                        f"SECURITY: User plugin '{plugin_name}' not in allowlist. "
                        f"Add to allowed_user_plugins config to enable."
                    )
                    return None

            # SECURITY: TOCTOU protection - re-validate path at load time
            # The path may have been swapped between validation and loading
            load_time_path = _validate_plugin_path(
                plugin_name, callbacks_file, expected_base
            )
            if load_time_path is None:
                return None

            # SECURITY CRITICAL WARNING: Loading user plugin executes arbitrary code
            # This is the primary ACE/RCE attack surface. The plugin runs with full
            # system privileges and can perform any action the user can perform
            # (delete files, steal credentials, install malware, exfiltrate data, etc.)
            logger.warning(
                "SECURITY: Loading user plugin '%s' from %s — executes arbitrary Python code "
                "with full system privileges. Only load plugins from trusted sources!",
                plugin_name,
                load_time_path,
            )

            module_name = f"{plugin_name}.register_callbacks"
            spec = importlib.util.spec_from_file_location(module_name, load_time_path)

            # SECURITY: Validate it's a proper Python module before loading
            if spec is None:
                logger.error(
                    "SECURITY: Could not create module spec for user plugin '%s' — "
                    "not a valid Python module. File may be corrupted or not a Python file.",
                    plugin_name,
                )
                return None
            if spec.loader is None:
                logger.error(
                    "SECURITY: Module spec for user plugin '%s' has no loader — "
                    "cannot safely import. This may indicate a non-Python file.",
                    plugin_name,
                )
                return None

            module = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = module
            # SECURITY: exec_module() executes arbitrary Python code with full privileges.
            # This is the primary RCE attack surface - only load trusted plugins!
            spec.loader.exec_module(module)
            return module
        except ImportError as e:
            logger.warning(f"Failed to lazy-load user plugin {plugin_name}: {e}")
            return None
        except Exception as e:
            logger.error(
                f"Unexpected error lazy-loading user plugin {plugin_name}: {e}",
                exc_info=True,
            )
            return None

    return _load


def _register_lazy_plugin(
    phase: str, plugin_type: str, plugin_name: str, load_func: Callable
) -> None:
    """Register a plugin for lazy loading when a specific phase is triggered."""
    if phase not in _LAZY_PLUGIN_REGISTRY:
        _LAZY_PLUGIN_REGISTRY[phase] = []
    _LAZY_PLUGIN_REGISTRY[phase].append((plugin_type, plugin_name, load_func))
    logger.debug(
        f"Registered {plugin_type} plugin '{plugin_name}' for lazy loading on phase '{phase}'"
    )


def _discover_builtin_plugins(plugins_dir: Path) -> list[tuple[str, list[str]]]:
    """Discover built-in plugins and their target phases without importing them.

    Returns list of (plugin_name, phases) tuples where phases are the callback phases
    the plugin wants to register for.
    """
    discovered = []

    for item in plugins_dir.iterdir():
        if item.is_dir() and not item.name.startswith("_"):
            plugin_name = item.name
            callbacks_file = item / "register_callbacks.py"

            if callbacks_file.exists():
                # Check for shell_safety plugin - may need to skip based on config
                if plugin_name == "shell_safety":
                    from code_puppy.config import get_safety_permission_level

                    safety_level = get_safety_permission_level()
                    if safety_level not in ("none", "low"):
                        logger.debug(
                            f"Skipping shell_safety plugin - safety_permission_level is '{safety_level}'"
                        )
                        continue

                # Parse the register_callbacks.py to find which phases it uses
                phases = _extract_phases_from_callbacks_file(
                    callbacks_file, plugin_name
                )
                if phases:
                    discovered.append((plugin_name, phases))

    return discovered


def _extract_phases_from_callbacks_file(
    callbacks_file: Path, plugin_name: str
) -> list[str]:
    """Extract callback phases from a register_callbacks.py file without executing it.

    This is a lightweight static analysis to determine which phases a plugin
    will register for, so we can lazy-load it only when those phases trigger.
    """
    phases = []
    supported_phases = {
        "startup",
        "shutdown",
        "invoke_agent",
        "agent_exception",
        "version_check",
        "edit_file",
        "create_file",
        "replace_in_file",
        "delete_snippet",
        "delete_file",
        "run_shell_command",
        "load_model_config",
        "load_models_config",
        "load_prompt",
        "agent_reload",
        "custom_command",
        "custom_command_help",
        "file_permission",
        "pre_tool_call",
        "post_tool_call",
        "stream_event",
        "register_tools",
        "register_agents",
        "register_model_type",
        "get_model_system_prompt",
        "agent_run_start",
        "agent_run_end",
        "register_mcp_catalog_servers",
        "register_browser_types",
        "get_motd",
        "register_model_providers",
        "message_history_processor_start",
        "message_history_processor_end",
    }

    try:
        content = callbacks_file.read_text()

        # Look for register_callback("phase", ...) patterns
        pattern = r'register_callback\s*\(\s*["\']([^"\']+)["\']'
        matches = re.findall(pattern, content)

        for phase in matches:
            if phase in supported_phases:
                phases.append(phase)  # type: ignore

        # If no explicit register_callback calls found but file exists,
        # the plugin might register callbacks at import time via side effects
        # In that case, default to startup phase
        if not phases:
            phases = ["startup"]  # type: ignore

    except Exception as e:
        logger.warning(f"Could not parse callbacks file for {plugin_name}: {e}")
        phases = ["startup"]  # type: ignore

    return phases


def _discover_user_plugins(user_plugins_dir: Path) -> list[tuple[str, list[str]]]:
    """Discover user plugins and their target phases without importing them.

    Returns list of (plugin_name, phases) tuples.
    """
    discovered = []

    if not user_plugins_dir.exists():
        return discovered

    if not user_plugins_dir.is_dir():
        logger.warning(f"User plugins path is not a directory: {user_plugins_dir}")
        return discovered

    # Add user plugins directory to sys.path if not already there
    user_plugins_str = str(user_plugins_dir)
    if user_plugins_str not in sys.path:
        sys.path.insert(0, user_plugins_str)

    for item in user_plugins_dir.iterdir():
        if (
            item.is_dir()
            and not item.name.startswith("_")
            and not item.name.startswith(".")
        ):
            plugin_name = item.name

            # SECURITY: Validate plugin name doesn't contain path traversal sequences
            if (
                ".." in plugin_name
                or "/" in plugin_name
                or "\\" in plugin_name
                or "\x00" in plugin_name
            ):
                logger.warning(
                    "SECURITY: Skipping user plugin with suspicious name: %s",
                    plugin_name,
                )
                continue

            callbacks_file = item / "register_callbacks.py"

            # SECURITY: Path traversal protection - verify resolved path is inside plugins dir
            try:
                callbacks_abs = callbacks_file.resolve()
                plugins_abs = user_plugins_dir.resolve()
                # Check if the resolved path is within the plugins directory using proper path containment
                try:
                    callbacks_abs.relative_to(plugins_abs)
                except ValueError:
                    logger.warning(
                        "SECURITY: User plugin %s attempted path traversal outside plugins directory. Skipping.",
                        plugin_name,
                    )
                    continue
            except (OSError, ValueError) as e:
                logger.warning(
                    "SECURITY: Could not resolve path for user plugin %s: %s. Skipping.",
                    plugin_name,
                    e,
                )
                continue

            # SECURITY: Check for symlinks pointing outside plugin directory
            try:
                if callbacks_file.is_symlink():
                    link_target = callbacks_file.readlink()
                    if link_target.is_absolute():
                        target_abs = link_target.resolve()
                        try:
                            target_abs.relative_to(plugins_abs)
                        except ValueError:
                            logger.warning(
                                "SECURITY: User plugin %s has symlink pointing outside plugins directory. Skipping.",
                                plugin_name,
                            )
                            continue
            except (OSError, ValueError) as e:
                logger.warning(
                    "SECURITY: Could not check symlink for user plugin %s: %s. Skipping.",
                    plugin_name,
                    e,
                )
                continue

            if callbacks_file.exists():
                phases = _extract_phases_from_callbacks_file(
                    callbacks_file, plugin_name
                )
                if phases:
                    discovered.append((plugin_name, phases))
            else:
                # Check if there's an __init__.py - might be a simple plugin
                init_file = item / "__init__.py"
                if init_file.exists():
                    # Simple plugins typically run at startup
                    discovered.append((plugin_name, ["startup"]))  # type: ignore

    return discovered


def load_plugin_callbacks() -> dict[str, list[str]]:
    """Discover plugins for lazy loading.

    This function discovers all plugins and registers them for lazy loading
    based on which callback phases they use. Plugins are NOT imported during
    discovery - they're only imported when their registered phases trigger.

    Returns dict with 'builtin' and 'user' keys containing lists of discovered plugin names.

    NOTE: This function is idempotent - calling it multiple times will only
    discover plugins once. Subsequent calls return empty lists.
    """
    global _PLUGINS_DISCOVERED

    if _PLUGINS_DISCOVERED:
        logger.debug("Plugins already discovered, skipping")
        return {"builtin": [], "user": []}

    plugins_dir = Path(__file__).parent

    # Discover built-in plugins
    builtin_discovered = _discover_builtin_plugins(plugins_dir)
    builtin_loaded = []
    for plugin_name, phases in builtin_discovered:
        module_name = f"code_puppy.plugins.{plugin_name}.register_callbacks"
        load_func = _create_loader_builtin(plugin_name, module_name)

        # Register this plugin for lazy loading on each of its phases
        for phase in phases:
            _register_lazy_plugin(phase, "builtin", plugin_name, load_func)

        builtin_loaded.append(plugin_name)

    # Discover user plugins
    user_discovered = _discover_user_plugins(_user_plugins_dir())
    user_loaded = []
    for plugin_name, phases in user_discovered:
        callbacks_file = _user_plugins_dir() / plugin_name / "register_callbacks.py"
        load_func = _create_loader_user(
            plugin_name, callbacks_file, base_dir=_user_plugins_dir()
        )

        # Register this plugin for lazy loading on each of its phases
        for phase in phases:
            _register_lazy_plugin(phase, "user", plugin_name, load_func)

        user_loaded.append(plugin_name)

    _PLUGINS_DISCOVERED = True
    logger.debug(
        f"Discovered plugins for lazy loading: builtin={builtin_loaded}, user={user_loaded}"
    )

    return {"builtin": builtin_loaded, "user": user_loaded}


def _load_plugins_for_phase(phase: str) -> list[str]:
    """Load all plugins registered for a specific phase.

    This is called internally when a phase is triggered to ensure
    all lazy-loaded plugins for that phase are imported before callbacks run.
    """
    if phase not in _LAZY_PLUGIN_REGISTRY:
        return []

    loaded = []
    plugins_to_load = _LAZY_PLUGIN_REGISTRY.get(phase, [])

    for plugin_type, plugin_name, load_func in plugins_to_load:
        # Skip if already loaded (with lock for thread safety)
        plugin_key = f"{plugin_type}:{plugin_name}"
        with _plugin_load_lock:
            if plugin_key in _LOADED_PLUGINS:
                continue

        # Load the plugin
        result = load_func()
        if result is not None:
            with _plugin_load_lock:
                _LOADED_PLUGINS.add(plugin_key)
            loaded.append(plugin_name)
            logger.debug(
                f"Lazy-loaded {plugin_type} plugin '{plugin_name}' for phase '{phase}'"
            )

    return loaded


def ensure_plugins_loaded_for_phase(phase: str) -> list[str]:
    """Public API to ensure all plugins for a phase are loaded.

    This should be called by the callbacks system before triggering callbacks
    for a phase that might have lazy-loaded plugins.

    Returns list of plugin names that were loaded.
    """
    return _load_plugins_for_phase(phase)


def get_user_plugins_dir() -> Path:
    """Return the path to the user plugins directory."""
    return _user_plugins_dir()


def ensure_user_plugins_dir() -> Path:
    """Create the user plugins directory if it doesn't exist.

    Returns the path to the directory.
    """
    from code_puppy.config_paths import safe_mkdir_p

    safe_mkdir_p(_user_plugins_dir())
    return _user_plugins_dir()
