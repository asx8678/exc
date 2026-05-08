"""Shared helpers for agent model pinning.

Fixes the mixed-source pinning bug where JSON agents could have stale
config pins that weren't cleared when the JSON model was unpinned.

For JSON agents, there is a single source of truth:
- JSON file `model` key is checked first and takes precedence
- Config pin is cleared when setting/unsetting JSON pin to avoid conflicts

For built-in agents, the existing config pinning behavior is preserved.
"""

import json
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    pass


def _get_json_agent_path(agent_name: str) -> str | None:
    """Get the file path for a JSON agent, if it exists.

    Args:
        agent_name: Name of the agent to look up.

    Returns:
        Path to the JSON file, or None if not a JSON agent.
    """
    try:
        from code_puppy.agents.json_agent import discover_json_agents

        json_agents = discover_json_agents()
        return json_agents.get(agent_name)
    except Exception:
        return None


def _load_json_agent_config(path: str) -> dict:
    """Load JSON agent configuration from file.

    Args:
        path: Path to the JSON file.

    Returns:
        The parsed JSON configuration.

    Raises:
        ValueError: If the file cannot be read or parsed.
    """
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _save_json_agent_config(path: str, cfg: dict) -> None:
    """Save JSON agent configuration to file.

    Args:
        path: Path to the JSON file.
        cfg: The configuration to save.
    """
    # Ensure parent directory exists
    Path(path).parent.mkdir(parents=True, exist_ok=True)

    from code_puppy.config_paths import assert_write_allowed

    assert_write_allowed(path, "save_json_agent_config")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)


def _is_json_agent(agent_name: str) -> bool:
    """Check if an agent is a JSON agent.

    Args:
        agent_name: Name of the agent to check.

    Returns:
        True if the agent is a JSON agent, False otherwise.
    """
    return _get_json_agent_path(agent_name) is not None


def get_effective_agent_pinned_model(agent_name: str) -> str | None:
    """Get the effective pinned model for an agent.

    For JSON agents: returns JSON `model` key if present, otherwise
    falls back to config pin (for backward compatibility).

    For built-in agents: returns the config pin.

    This matches the behavior of `JSONAgent.get_model_name()` which
    uses JSON `model` first, then falls back to BaseAgent/config pin.

    Args:
        agent_name: Name of the agent to get the pinned model for.

    Returns:
        The effective pinned model name, or None if not pinned.
    """
    # Check if this is a JSON agent
    json_path = _get_json_agent_path(agent_name)

    if json_path:
        # JSON agent: check JSON file first (source of truth)
        try:
            cfg = _load_json_agent_config(json_path)
            json_model = cfg.get("model")
            if json_model:
                return json_model
        except Exception:
            pass  # Fall through to config check

    # For built-in agents OR as fallback for JSON agents
    from code_puppy.config import get_agent_pinned_model

    try:
        return get_agent_pinned_model(agent_name)
    except Exception:
        return None


def apply_agent_pinned_model(agent_name: str, model_choice: str) -> str | None:
    """Apply a pinned model selection for an agent.

    For JSON agents:
    - If pinning: sets JSON `model` and clears any stale config pin
    - If unpinning: removes JSON `model` AND clears config pin
    - JSON `model` takes precedence over config pin

    For built-in agents: uses the existing config pinning system.

    Args:
        agent_name: Name of the agent to pin/unpin.
        model_choice: Model name to pin, or "(unpin)" to unpin.

    Returns:
        The pinned model name if pinned, None if unpinned.

    Raises:
        RuntimeError: If the operation fails (file errors, etc).
    """
    from code_puppy.config import clear_agent_pinned_model, set_agent_pinned_model

    is_unpin = model_choice == "(unpin)"

    # Check if this is a JSON agent
    json_path = _get_json_agent_path(agent_name)

    if json_path:
        # JSON agent: modify the JSON file and handle stale config pins
        try:
            cfg = _load_json_agent_config(json_path)

            if is_unpin:
                # Remove model from JSON
                if "model" in cfg:
                    del cfg["model"]

                # Also clear any stale config pin (THE BUG FIX)
                try:
                    clear_agent_pinned_model(agent_name)
                except Exception:
                    pass  # Config pin might not exist

                _save_json_agent_config(json_path, cfg)
                return None
            else:
                # Set model in JSON
                cfg["model"] = model_choice

                # Also clear any stale config pin to ensure single source of truth
                try:
                    clear_agent_pinned_model(agent_name)
                except Exception:
                    pass  # Config pin might not exist

                _save_json_agent_config(json_path, cfg)
                return model_choice

        except Exception as exc:
            raise RuntimeError(f"Failed to modify JSON agent config: {exc}") from exc

    else:
        # Built-in agent: use config functions
        if is_unpin:
            clear_agent_pinned_model(agent_name)
            return None
        else:
            set_agent_pinned_model(agent_name, model_choice)
            return model_choice
