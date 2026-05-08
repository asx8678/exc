"""Agent manager for handling different agent configurations."""

import dataclasses
import importlib
import json
import os
import pkgutil
import re
import threading
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from pydantic_ai.messages import ModelMessage

from code_puppy.agents.base_agent import BaseAgent
from code_puppy.agents.json_agent import JSONAgent, discover_json_agents
from code_puppy.callbacks import on_agent_reload, on_register_agents
from code_puppy.messaging import emit_error, emit_success, emit_warning


@dataclass(frozen=True)
class AgentInfo:
    """Immutable metadata snapshot for a discovered agent.

    Stores the metadata captured at discovery time so that
    ``get_available_agents()`` and ``get_agent_descriptions()`` never
    need to re-instantiate the agent just to read its name or description.
    """

    name: str
    display_name: str
    description: str
    factory: Callable  # callable () -> BaseAgent instance
    # Present only for JSON-file agents; None for Python-class agents.
    json_path: str | None = None


@dataclass
class AgentManagerState:
    """Encapsulates all mutable module-level state for the agent manager.

    Replaces the six process-global variables that previously scattered
    mutable state across the module, making the state easier to inspect,
    reset in tests, and reason about.
    """

    agent_registry: dict[str, AgentInfo] = dataclasses.field(default_factory=dict)
    agent_histories: dict[str, list[ModelMessage]] = dataclasses.field(
        default_factory=dict
    )
    current_agent: BaseAgent | None = None
    registry_populated: bool = False
    session_agents_cache: dict[str, str] = dataclasses.field(default_factory=dict)
    session_file_loaded: bool = False


# Module-level singleton – all functions reference _state.<field> instead of
# bare module globals so the state is fully encapsulated.
_state = AgentManagerState()

# Thread lock for session cache updates (not part of state because it must
# never be replaced or serialised).
_SESSION_LOCK = threading.Lock()

# Thread lock for agent registry mutations (prevents race conditions during
# concurrent agent discovery operations).
_REGISTRY_LOCK = threading.Lock()


# Session persistence file path
def _get_session_file_path() -> Path:
    """Get the path to the terminal sessions file."""
    from ..config import STATE_DIR

    return Path(STATE_DIR) / "terminal_sessions.json"


def get_terminal_session_id() -> str:
    """Get a unique identifier for the current terminal session.

    Includes both parent PID (for terminal grouping) and current PID
    (for process isolation) to prevent collisions between multiple
    Code Puppy processes under the same shell.

    Returns:
        str: Unique session identifier (e.g., "session_12345_12346")
    """
    try:
        ppid = os.getppid()
        pid = os.getpid()
        return f"session_{ppid}_{pid}"
    except OSError, AttributeError:
        # Fallback to current process ID if PPID unavailable
        return f"fallback_{os.getpid()}"


def _is_process_alive(pid: int) -> bool:
    """Check if a process with the given PID is still alive, cross-platform.

    Args:
        pid: Process ID to check

    Returns:
        bool: True if process likely exists, False otherwise
    """
    try:
        if os.name == "nt":
            # Windows: use OpenProcess to probe liveness safely
            import ctypes
            from ctypes import wintypes

            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
            kernel32.OpenProcess.argtypes = [
                wintypes.DWORD,
                wintypes.BOOL,
                wintypes.DWORD,
            ]
            kernel32.OpenProcess.restype = wintypes.HANDLE
            handle = kernel32.OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid)
            )
            if handle:
                kernel32.CloseHandle(handle)
                return True
            # If access denied, process likely exists but we can't query it
            last_error = kernel32.GetLastError()
            # ERROR_ACCESS_DENIED = 5
            if last_error == 5:
                return True
            return False
        else:
            # Unix-like: signal 0 does not deliver a signal but checks existence
            os.kill(int(pid), 0)
            return True
    except PermissionError:
        # No permission to signal -> process exists
        return True
    except OSError, ProcessLookupError:
        # Process does not exist
        return False
    except ValueError:
        # Invalid signal or pid format
        return False
    except Exception:
        # Be conservative – don't crash session cleanup due to platform quirks
        return True


def _cleanup_dead_sessions(sessions: dict[str, str]) -> dict[str, str]:
    """Remove sessions for processes that no longer exist.

    Args:
        sessions: Dictionary of session_id -> agent_name

    Returns:
        dict: Cleaned sessions dictionary
    """
    cleaned = {}
    for session_id, agent_name in sessions.items():
        if session_id.startswith("session_"):
            try:
                pid_str = session_id.replace("session_", "")
                # Handle both formats: "session_{ppid}_{pid}" (new) and "session_{pid}" (legacy)
                if "_" in pid_str:
                    # New format: extract the current PID (second part after underscore)
                    _, pid_str = pid_str.rsplit("_", 1)
                # Legacy format: pid_str is already just the PID
                pid = int(pid_str)
                if _is_process_alive(pid):
                    cleaned[session_id] = agent_name
                # else: skip dead session
            except ValueError, TypeError:
                # Invalid session ID format, keep it anyway
                cleaned[session_id] = agent_name
        else:
            # Non-standard session ID (like "fallback_"), keep it
            cleaned[session_id] = agent_name
    return cleaned


def _load_session_data() -> dict[str, str]:
    """Load terminal session data from the JSON file.

    Returns:
        dict: Session ID to agent name mapping
    """
    session_file = _get_session_file_path()
    try:
        if session_file.exists():
            with open(session_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                # Clean up dead sessions while loading
                return _cleanup_dead_sessions(data)
        return {}
    except json.JSONDecodeError, IOError, OSError:
        # File corrupted or permission issues, start fresh
        return {}


def _save_session_data(sessions: dict[str, str]) -> None:
    """Save terminal session data to the JSON file.

    Args:
        sessions: Session ID to agent name mapping
    """
    session_file = _get_session_file_path()
    try:
        # Ensure the config directory exists
        session_file.parent.mkdir(parents=True, exist_ok=True)

        # Clean up dead sessions before saving
        cleaned_sessions = _cleanup_dead_sessions(sessions)

        # Write to file atomically (write to temp file, then rename)
        temp_file = session_file.with_suffix(".tmp")
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(cleaned_sessions, f, indent=2)

        # Atomic rename (works on all platforms)
        temp_file.replace(session_file)

    except IOError, OSError:
        # File permission issues, etc. - just continue without persistence
        pass


def _ensure_session_cache_loaded() -> None:
    """Ensure the session cache is loaded from disk."""
    with _SESSION_LOCK:
        if not _state.session_file_loaded:
            _state.session_agents_cache.update(_load_session_data())
            _state.session_file_loaded = True


def _discover_agents(message_group_id: str | None = None):
    """Dynamically discover all agent classes and JSON agents."""
    # Double-checked locking pattern for thread-safe early return
    if _state.registry_populated:
        return  # Already discovered, use cached registry

    with _REGISTRY_LOCK:
        # Check again inside lock (another thread may have populated while waiting)
        if _state.registry_populated:
            return

        # Always clear the registry to force refresh
        _state.agent_registry.clear()

        # 1. Discover Python agent classes in the agents package
        import code_puppy.agents as agents_package

        # Iterate through all modules in the agents package
        for _, modname, _ in pkgutil.iter_modules(agents_package.__path__):
            if modname.startswith("_") or modname in [
                "base_agent",
                "json_agent",
                "agent_manager",
            ]:
                continue

            try:
                # Import the module
                module = importlib.import_module(f"code_puppy.agents.{modname}")

                # Look for BaseAgent subclasses
                for attr_name in dir(module):
                    attr = getattr(module, attr_name)
                    if (
                        isinstance(attr, type)
                        and issubclass(attr, BaseAgent)
                        and attr not in [BaseAgent, JSONAgent]
                    ):
                        # Instantiate once to capture metadata into AgentInfo
                        agent_instance = attr()
                        _state.agent_registry[agent_instance.name] = AgentInfo(
                            name=agent_instance.name,
                            display_name=agent_instance.display_name,
                            description=agent_instance.description,
                            factory=attr,
                        )

            except (ImportError, ModuleNotFoundError) as e:
                emit_warning(
                    f"Could not import agent module {modname}: {e}",
                    message_group=message_group_id,
                )
                continue
            except (AttributeError, SyntaxError, TypeError) as e:
                emit_warning(
                    f"Agent module {modname} has errors: {e}",
                    message_group=message_group_id,
                )
                continue
            except Exception as e:
                emit_error(
                    f"Unexpected error loading agent module {modname}: {e}",
                    message_group=message_group_id,
                )
                continue

        # 1b. Discover agents in sub-packages (like 'pack')
        for _, subpkg_name, ispkg in pkgutil.iter_modules(agents_package.__path__):
            if not ispkg or subpkg_name.startswith("_"):
                continue

            try:
                # Import the sub-package
                subpkg = importlib.import_module(f"code_puppy.agents.{subpkg_name}")

                # Iterate through modules in the sub-package
                if not hasattr(subpkg, "__path__"):
                    continue

                for _, modname, _ in pkgutil.iter_modules(subpkg.__path__):
                    if modname.startswith("_"):
                        continue

                    try:
                        # Import the submodule
                        module = importlib.import_module(
                            f"code_puppy.agents.{subpkg_name}.{modname}"
                        )

                        # Look for BaseAgent subclasses
                        for attr_name in dir(module):
                            attr = getattr(module, attr_name)
                            if (
                                isinstance(attr, type)
                                and issubclass(attr, BaseAgent)
                                and attr not in [BaseAgent, JSONAgent]
                            ):
                                # Instantiate once to capture metadata into AgentInfo
                                agent_instance = attr()
                                _state.agent_registry[agent_instance.name] = AgentInfo(
                                    name=agent_instance.name,
                                    display_name=agent_instance.display_name,
                                    description=agent_instance.description,
                                    factory=attr,
                                )

                    except (ImportError, ModuleNotFoundError) as e:
                        emit_warning(
                            f"Could not import agent {subpkg_name}.{modname}: {e}",
                            message_group=message_group_id,
                        )
                        continue
                    except (AttributeError, SyntaxError, TypeError) as e:
                        emit_warning(
                            f"Agent {subpkg_name}.{modname} has errors: {e}",
                            message_group=message_group_id,
                        )
                        continue
                    except Exception as e:
                        emit_error(
                            f"Unexpected error loading agent {subpkg_name}.{modname}: {e}",
                            message_group=message_group_id,
                        )
                        continue

            except (ImportError, ModuleNotFoundError) as e:
                emit_warning(
                    f"Could not import agent sub-package {subpkg_name}: {e}",
                    message_group=message_group_id,
                )
                continue
            except (AttributeError, SyntaxError, TypeError) as e:
                emit_warning(
                    f"Agent sub-package {subpkg_name} has errors: {e}",
                    message_group=message_group_id,
                )
                continue
            except Exception as e:
                emit_error(
                    f"Unexpected error loading agent sub-package {subpkg_name}: {e}",
                    message_group=message_group_id,
                )
                continue

        # 2. Discover JSON agents in user directory
        try:
            json_agents = discover_json_agents()

            # Add JSON agents to registry (store file path instead of class)
            # Python (builtin) agents take precedence over JSON agents.
            for agent_name, json_path in json_agents.items():
                if agent_name in _state.agent_registry:
                    emit_warning(
                        f"JSON agent '{agent_name}' skipped: builtin Python agent with the same name takes precedence.",
                        message_group=message_group_id,
                    )
                    continue
                try:
                    _json_tmp = JSONAgent(json_path)
                    _json_display = _json_tmp.display_name
                    _json_desc = _json_tmp.description
                except (FileNotFoundError, json.JSONDecodeError, KeyError) as e:
                    _json_display = agent_name.replace("-", " ").title() + " 🤖"
                    _json_desc = "No description available"
                    emit_warning(
                        f"JSON agent '{agent_name}' config error: {e}",
                        message_group=message_group_id,
                    )
                except (AttributeError, TypeError) as e:
                    _json_display = agent_name.replace("-", " ").title() + " 🤖"
                    _json_desc = "No description available"
                    emit_warning(
                        f"JSON agent '{agent_name}' has errors: {e}",
                        message_group=message_group_id,
                    )
                except Exception as e:
                    _json_display = agent_name.replace("-", " ").title() + " 🤖"
                    _json_desc = "No description available"
                    emit_error(
                        f"Unexpected error loading JSON agent '{agent_name}': {e}",
                        message_group=message_group_id,
                    )
                _state.agent_registry[agent_name] = AgentInfo(
                    name=agent_name,
                    display_name=_json_display,
                    description=_json_desc,
                    factory=lambda _p=json_path: JSONAgent(_p),
                    json_path=json_path,
                )

        except Exception as e:
            emit_warning(
                f"Warning: Could not discover JSON agents: {e}",
                message_group=message_group_id,
            )

        # 3. Discover agents registered by plugins
        try:
            results = on_register_agents()
            for result in results:
                if result is None:
                    continue
                # Each result should be a list of agent definitions
                agents_list = result if isinstance(result, list) else [result]
                for agent_def in agents_list:
                    if not isinstance(agent_def, dict) or "name" not in agent_def:
                        continue

                    agent_name = agent_def["name"]

                    # Support both class-based and JSON path-based registration
                    if "class" in agent_def:
                        agent_class = agent_def["class"]
                        if isinstance(agent_class, type) and issubclass(
                            agent_class, BaseAgent
                        ):
                            try:
                                _plugin_inst = agent_class()
                                _state.agent_registry[agent_name] = AgentInfo(
                                    name=_plugin_inst.name,
                                    display_name=_plugin_inst.display_name,
                                    description=_plugin_inst.description,
                                    factory=agent_class,
                                )
                            except (
                                ImportError,
                                ModuleNotFoundError,
                                AttributeError,
                                TypeError,
                            ) as e:
                                emit_warning(
                                    f"Could not load plugin agent '{agent_name}': {e}",
                                    message_group=message_group_id,
                                )
                            except Exception as e:
                                emit_error(
                                    f"Unexpected error loading plugin agent '{agent_name}': {e}",
                                    message_group=message_group_id,
                                )
                    elif "json_path" in agent_def:
                        json_path = agent_def["json_path"]
                        if isinstance(json_path, str):
                            try:
                                _pj_tmp = JSONAgent(json_path)
                                _pj_display = _pj_tmp.display_name
                                _pj_desc = _pj_tmp.description
                            except (
                                FileNotFoundError,
                                json.JSONDecodeError,
                                KeyError,
                            ) as e:
                                _pj_display = (
                                    agent_name.replace("-", " ").title() + " 🤖"
                                )
                                _pj_desc = "No description available"
                                emit_warning(
                                    f"Plugin JSON agent '{agent_name}' config error: {e}",
                                    message_group=message_group_id,
                                )
                            except (AttributeError, TypeError) as e:
                                _pj_display = (
                                    agent_name.replace("-", " ").title() + " 🤖"
                                )
                                _pj_desc = "No description available"
                                emit_warning(
                                    f"Plugin JSON agent '{agent_name}' has errors: {e}",
                                    message_group=message_group_id,
                                )
                            except Exception as e:
                                _pj_display = (
                                    agent_name.replace("-", " ").title() + " 🤖"
                                )
                                _pj_desc = "No description available"
                                emit_error(
                                    f"Unexpected error loading plugin JSON agent '{agent_name}': {e}",
                                    message_group=message_group_id,
                                )
                            _state.agent_registry[agent_name] = AgentInfo(
                                name=agent_name,
                                display_name=_pj_display,
                                description=_pj_desc,
                                factory=lambda _p=json_path: JSONAgent(_p),
                                json_path=json_path,
                            )

        except Exception as e:
            emit_warning(
                f"Warning: Could not load plugin agents: {e}",
                message_group=message_group_id,
            )

        _state.registry_populated = True  # Mark registry as fully populated


def _invalidate_agent_registry() -> None:
    """Invalidate the agent registry cache, forcing re-discovery on next call."""
    with _REGISTRY_LOCK:
        _state.registry_populated = False


def reset_state_for_tests() -> None:
    """Reset the agent manager state for test isolation.

    Clears all mutable state including registry, histories, current agent,
    and session cache. Acquires both registry and session locks to ensure
    thread-safe reset.
    """
    global _state

    # Acquire both locks to ensure thread-safe reset
    with _REGISTRY_LOCK:
        with _SESSION_LOCK:
            # Reset the state object to a fresh instance
            _state = AgentManagerState()


def get_available_agents() -> dict[str, str]:
    """Get a dictionary of available agents with their display names.

    Bridge-aware - tries Elixir bridge first if connected,
    falls back to local agent registry.

    Returns:
        Dict mapping agent names to display names.
    """
    # Try Elixir bridge first if connected
    try:
        import asyncio

        from code_puppy.plugins.elixir_bridge import (
            call_elixir_agent_manager,
            is_connected,
        )

        if is_connected():
            try:
                # Try to get agents from Elixir (with short timeout)
                result = asyncio.run(
                    call_elixir_agent_manager(
                        "agent_manager.list",
                        {},
                        timeout=1.0,
                    )
                )
                if result.get("status") == "ok" and "agents" in result:
                    return dict(result["agents"])
            except Exception:
                pass  # Fallback to local on any error
    except ImportError:
        pass

    from ..config import (
        PACK_AGENT_NAMES,
        UC_AGENT_NAMES,
        get_pack_agents_enabled,
        get_universal_constructor_enabled,
    )

    # Generate a message group ID for this operation
    message_group_id = str(uuid.uuid4())
    _discover_agents(message_group_id=message_group_id)

    # Check if pack agents are enabled
    pack_agents_enabled = get_pack_agents_enabled()

    # Check if UC is enabled
    uc_enabled = get_universal_constructor_enabled()

    agents = {}
    for name, agent_info in _state.agent_registry.items():
        # Filter out pack agents if disabled
        if not pack_agents_enabled and name in PACK_AGENT_NAMES:
            continue

        # Filter out UC-dependent agents if UC is disabled
        if not uc_enabled and name in UC_AGENT_NAMES:
            continue

        agents[name] = agent_info.display_name

    return agents


def get_current_agent_name() -> str:
    """Get the name of the currently active agent for this terminal session.

    Bridge-aware - tries Elixir bridge first if connected,
    falls back to local session/cache/config.

    Returns:
        The name of the current agent for this session.
        Priority: session agent > last selected agent > config default > 'code-puppy'.
    """
    # Try Elixir bridge first if connected
    try:
        import asyncio

        from code_puppy.plugins.elixir_bridge import (
            call_elixir_agent_manager,
            is_connected,
        )

        if is_connected():
            try:
                # Try to get current agent from Elixir (with short timeout)
                result = asyncio.run(
                    call_elixir_agent_manager(
                        "agent_manager.get_current",
                        {},
                        timeout=1.0,
                    )
                )
                if result.get("status") == "ok" and result.get("current_agent"):
                    return result["current_agent"]
            except Exception:
                pass  # Fallback to local on any error
    except ImportError:
        pass

    _ensure_session_cache_loaded()
    session_id = get_terminal_session_id()

    # First check for session-specific agent
    with _SESSION_LOCK:
        session_agent = _state.session_agents_cache.get(session_id)
    if session_agent:
        return session_agent

    # Fall back to last selected agent (from plugin)
    try:
        from code_puppy.plugins.remember_last_agent import get_last_agent

        last_agent = get_last_agent()
        if last_agent:
            return last_agent
    except ImportError:
        pass  # Plugin not available

    # Fall back to config default
    from ..config import get_default_agent

    return get_default_agent()


def set_current_agent(agent_name: str) -> bool:
    """Set the current agent by name.

    Bridge-aware - notifies Elixir bridge if connected (fire-and-forget).

    Args:
        agent_name: The name of the agent to set as current.

    Returns:
        True if the agent was set successfully, False if agent not found.
    """
    curr_agent = get_current_agent()
    if curr_agent is not None:
        # Store a shallow copy so future mutations don't affect saved history
        _state.agent_histories[curr_agent.name] = list(curr_agent.get_message_history())
    # Generate a message group ID for agent switching
    message_group_id = str(uuid.uuid4())
    _discover_agents(message_group_id=message_group_id)

    # Save current agent's history before switching

    # Clear the cached config when switching agents
    agent_obj = load_agent(agent_name)
    _state.current_agent = agent_obj

    # Update session-based agent selection and persist to disk
    _ensure_session_cache_loaded()
    session_id = get_terminal_session_id()
    with _SESSION_LOCK:
        _state.session_agents_cache[session_id] = agent_name
        cache_snapshot = dict(_state.session_agents_cache)
    _save_session_data(cache_snapshot)
    if agent_obj.name in _state.agent_histories:
        # Restore a copy to avoid sharing the same list instance
        agent_obj.set_message_history(list(_state.agent_histories[agent_obj.name]))
    on_agent_reload(agent_obj.id, agent_name)

    # Notify Elixir bridge if connected (fire-and-forget)
    try:
        import asyncio

        from code_puppy.plugins.elixir_bridge import (
            call_elixir_agent_manager,
            is_connected,
        )

        if is_connected():
            try:
                asyncio.create_task(
                    call_elixir_agent_manager(
                        "agent_manager.set_current",
                        {"agent_name": agent_name},
                        timeout=1.0,
                    )
                )
            except Exception:
                pass  # Ignore errors for fire-and-forget
    except ImportError:
        pass

    return True


def get_current_agent() -> BaseAgent:
    """Get the current agent configuration.

    Returns:
        The current agent configuration instance.
    """
    if _state.current_agent is None:
        agent_name = get_current_agent_name()
        _state.current_agent = load_agent(agent_name)

    return _state.current_agent


def load_agent(agent_name: str) -> BaseAgent:
    """Load an agent configuration by name.

    Args:
        agent_name: The name of the agent to load.

    Returns:
        The agent configuration instance.

    Raises:
        ValueError: If the agent is not found.
    """
    # Generate a message group ID for agent loading
    message_group_id = str(uuid.uuid4())
    _discover_agents(message_group_id=message_group_id)

    if agent_name not in _state.agent_registry:
        # Fallback to code-puppy if agent not found
        if "code-puppy" in _state.agent_registry:
            agent_name = "code-puppy"
        else:
            raise ValueError(
                f"Agent '{agent_name}' not found and no fallback available"
            )

    agent_info = _state.agent_registry[agent_name]
    return agent_info.factory()


def get_agent_descriptions() -> dict[str, str]:
    """Get descriptions for all available agents.

    Returns:
        Dict mapping agent names to their descriptions.
    """
    from ..config import (
        PACK_AGENT_NAMES,
        UC_AGENT_NAMES,
        get_pack_agents_enabled,
        get_universal_constructor_enabled,
    )

    # Generate a message group ID for this operation
    message_group_id = str(uuid.uuid4())
    _discover_agents(message_group_id=message_group_id)

    # Check if pack agents are enabled
    pack_agents_enabled = get_pack_agents_enabled()

    # Check if UC is enabled
    uc_enabled = get_universal_constructor_enabled()

    descriptions = {}
    for name, agent_info in _state.agent_registry.items():
        # Filter out pack agents if disabled
        if not pack_agents_enabled and name in PACK_AGENT_NAMES:
            continue

        # Filter out UC-dependent agents if UC is disabled
        if not uc_enabled and name in UC_AGENT_NAMES:
            continue

        descriptions[name] = agent_info.description

    return descriptions


def refresh_agents():
    """Refresh the agent discovery to pick up newly created agents.

    This clears the agent registry cache and forces a rediscovery of all agents.
    """
    # Invalidate cache so _discover_agents performs a full re-scan
    _invalidate_agent_registry()
    # Generate a message group ID for agent refreshing
    message_group_id = str(uuid.uuid4())
    _discover_agents(message_group_id=message_group_id)


_CLONE_NAME_PATTERN = re.compile(r"^(?P<base>.+)-clone-(?P<index>\d+)$")
_CLONE_DISPLAY_PATTERN = re.compile(r"\s*\(Clone\s+\d+\)$", re.IGNORECASE)


def _strip_clone_suffix(agent_name: str) -> str:
    """Strip a trailing -clone-N suffix from a name if present."""
    match = _CLONE_NAME_PATTERN.match(agent_name)
    return match.group("base") if match else agent_name


def _strip_clone_display_suffix(display_name: str) -> str:
    """Remove a trailing "(Clone N)" suffix from display names."""
    cleaned = _CLONE_DISPLAY_PATTERN.sub("", display_name).strip()
    return cleaned or display_name


def is_clone_agent_name(agent_name: str) -> bool:
    """Return True if the agent name looks like a clone."""
    return bool(_CLONE_NAME_PATTERN.match(agent_name))


def _default_display_name(agent_name: str) -> str:
    """Build a default display name from an agent name."""
    title = agent_name.title()
    return f"{title} 🤖"


def _build_clone_display_name(display_name: str, clone_index: int) -> str:
    """Build a clone display name based on the source display name."""
    base_name = _strip_clone_display_suffix(display_name)
    return f"{base_name} (Clone {clone_index})"


def _filter_available_tools(tool_names: list[str]) -> list[str]:
    """Filter a tool list to only available tool names."""
    from code_puppy.tools import get_available_tool_names

    available_tools = set(get_available_tool_names())
    return [tool for tool in tool_names if tool in available_tools]


def _next_clone_index(
    base_name: str, existing_names: set[str], agents_dir: Path
) -> int:
    """Compute the next clone index for a base name."""
    clone_pattern = re.compile(rf"^{re.escape(base_name)}-clone-(\d+)$")
    indices = []
    for name in existing_names:
        match = clone_pattern.match(name)
        if match:
            indices.append(int(match.group(1)))

    next_index = max(indices, default=0) + 1
    while True:
        clone_name = f"{base_name}-clone-{next_index}"
        clone_path = agents_dir / f"{clone_name}.json"
        if clone_name not in existing_names and not clone_path.exists():
            return next_index
        next_index += 1


def clone_agent(agent_name: str) -> str | None:
    """Clone an agent definition into the user agents directory.

    Args:
        agent_name: Source agent name to clone.

    Returns:
        The cloned agent name, or None if cloning failed.
    """
    # Generate a message group ID for agent cloning
    message_group_id = str(uuid.uuid4())
    _discover_agents(message_group_id=message_group_id)

    agent_info = _state.agent_registry.get(agent_name)
    if agent_info is None:
        emit_warning(f"Agent '{agent_name}' not found for cloning.")
        return None

    from ..config import get_agent_pinned_model, get_user_agents_directory

    agents_dir = Path(get_user_agents_directory())
    base_name = _strip_clone_suffix(agent_name)
    existing_names = set(_state.agent_registry.keys())
    clone_index = _next_clone_index(base_name, existing_names, agents_dir)
    clone_name = f"{base_name}-clone-{clone_index}"
    clone_path = agents_dir / f"{clone_name}.json"

    try:
        if agent_info.json_path is not None:
            with open(agent_info.json_path, "r", encoding="utf-8") as f:
                source_config = json.load(f)

            source_display_name = source_config.get("display_name")
            if not source_display_name:
                source_display_name = _default_display_name(base_name)

            clone_config = dict(source_config)
            clone_config["name"] = clone_name
            clone_config["display_name"] = _build_clone_display_name(
                source_display_name, clone_index
            )

            tools = source_config.get("tools", [])
            clone_config["tools"] = (
                _filter_available_tools(tools) if isinstance(tools, list) else []
            )

            if not clone_config.get("model"):
                clone_config.pop("model", None)
        else:
            agent_instance = agent_info.factory()
            clone_config = {
                "name": clone_name,
                "display_name": _build_clone_display_name(
                    agent_instance.display_name, clone_index
                ),
                "description": agent_instance.description,
                "system_prompt": agent_instance.get_full_system_prompt(),
                "tools": _filter_available_tools(agent_instance.get_available_tools()),
            }

            user_prompt = agent_instance.get_user_prompt()
            if user_prompt is not None:
                clone_config["user_prompt"] = user_prompt

            tools_config = agent_instance.get_tools_config()
            if tools_config is not None:
                clone_config["tools_config"] = tools_config

            pinned_model = get_agent_pinned_model(agent_instance.name)
            if pinned_model:
                clone_config["model"] = pinned_model
    except Exception as exc:
        emit_warning(f"Failed to build clone for '{agent_name}': {exc}")
        return None

    if clone_path.exists():
        emit_warning(f"Clone target '{clone_name}' already exists.")
        return None

    try:
        with open(clone_path, "w", encoding="utf-8") as f:
            json.dump(clone_config, f, indent=2, ensure_ascii=False)
        emit_success(f"Cloned '{agent_name}' to '{clone_name}'.")
        _invalidate_agent_registry()
        _discover_agents(message_group_id=message_group_id)
        return clone_name
    except Exception as exc:
        emit_warning(f"Failed to write clone file '{clone_path}': {exc}")
        return None


def delete_clone_agent(agent_name: str) -> bool:
    """Delete a cloned JSON agent definition.

    Args:
        agent_name: Clone agent name to delete.

    Returns:
        True if the clone was deleted, False otherwise.
    """
    message_group_id = str(uuid.uuid4())
    _discover_agents(message_group_id=message_group_id)

    if not is_clone_agent_name(agent_name):
        emit_warning(f"Agent '{agent_name}' is not a clone.")
        return False

    if get_current_agent_name() == agent_name:
        emit_warning("Cannot delete the active agent. Switch agents first.")
        return False

    agent_info = _state.agent_registry.get(agent_name)
    if agent_info is None:
        emit_warning(f"Clone '{agent_name}' not found.")
        return False

    if agent_info.json_path is None:
        emit_warning(f"Clone '{agent_name}' is not a JSON agent.")
        return False

    clone_path = Path(agent_info.json_path)
    if not clone_path.exists():
        emit_warning(f"Clone file for '{agent_name}' does not exist.")
        return False

    from ..config import get_user_agents_directory

    agents_dir = Path(get_user_agents_directory()).resolve()
    if clone_path.resolve().parent != agents_dir:
        emit_warning(f"Refusing to delete non-user clone '{agent_name}'.")
        return False

    try:
        clone_path.unlink()
        emit_success(f"Deleted clone '{agent_name}'.")
        _state.agent_registry.pop(agent_name, None)
        _state.agent_histories.pop(agent_name, None)
        _invalidate_agent_registry()
        _discover_agents(message_group_id=message_group_id)
        return True
    except Exception as exc:
        emit_warning(f"Failed to delete clone '{agent_name}': {exc}")
        return False
