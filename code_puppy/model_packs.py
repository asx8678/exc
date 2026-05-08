"""Model packs with role-based routing and fallback chains.

Thin wrapper that routes to Elixir ModelPacks GenServer.
Legacy Python implementation removed - now delegates all operations
to the Elixir control plane via call_elixir_model_packs().

Exports: RoleConfig, ModelPack, DEFAULT_PACKS, and all pack functions.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from code_puppy.config import get_global_model_name

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class RoleConfig:
    """Configuration for a specific role within a model pack."""

    primary: str
    fallbacks: list[str] = field(default_factory=list)
    trigger: str = "provider_failure"

    def get_model_chain(self) -> list[str]:
        return [self.primary] + self.fallbacks


@dataclass(frozen=True)
class ModelPack:
    """A model pack defining models for different roles."""

    name: str
    description: str
    roles: dict[str, RoleConfig]
    default_role: str = "coder"

    def get_model_for_role(self, role: str | None = None) -> str:
        role = role or self.default_role
        if role not in self.roles:
            role = self.default_role
        return self.roles[role].primary

    def get_fallback_chain(self, role: str | None = None) -> list[str]:
        role = role or self.default_role
        if role not in self.roles:
            role = self.default_role
        return self.roles[role].get_model_chain()


def _auto() -> RoleConfig:
    return RoleConfig(primary="auto")


def _pack(name: str, desc: str, **roles: RoleConfig) -> ModelPack:
    return ModelPack(name=name, description=desc, roles=roles, default_role="coder")


# Built-in default packs (used for local fallback when Elixir is not connected)
DEFAULT_PACKS: dict[str, ModelPack] = {
    "single": _pack(
        "single",
        "Use one model for all tasks",
        planner=_auto(),
        coder=_auto(),
        reviewer=_auto(),
        summarizer=_auto(),
        title=_auto(),
    ),
    "coding": _pack(
        "coding",
        "Optimized for coding tasks with specialized models",
        planner=RoleConfig(
            primary="claude-sonnet-4",
            fallbacks=["gpt-4o", "gemini-2.5-flash"],
            trigger="context_overflow",
        ),
        coder=RoleConfig(
            primary="zai-glm-5.1-coding",
            fallbacks=["synthetic-GLM-5", "firepass-kimi-k2p5-turbo"],
            trigger="provider_failure",
        ),
        reviewer=RoleConfig(
            primary="claude-sonnet-4", fallbacks=["gpt-4o-mini"], trigger="always"
        ),
        summarizer=RoleConfig(
            primary="gemini-2.5-flash",
            fallbacks=["gpt-4o-mini"],
            trigger="context_overflow",
        ),
        title=RoleConfig(
            primary="gpt-4o-mini", fallbacks=["gemini-2.5-flash"], trigger="always"
        ),
    ),
    "economical": _pack(
        "economical",
        "Cost-effective model selection for budget-conscious usage",
        planner=RoleConfig(
            primary="gemini-2.5-flash",
            fallbacks=["gpt-4o-mini"],
            trigger="context_overflow",
        ),
        coder=RoleConfig(
            primary="synthetic-GLM-5",
            fallbacks=["gemini-2.5-flash"],
            trigger="provider_failure",
        ),
        reviewer=RoleConfig(
            primary="gpt-4o-mini", fallbacks=["gemini-2.5-flash"], trigger="always"
        ),
        summarizer=RoleConfig(
            primary="gemini-2.5-flash", fallbacks=["gpt-4o-mini"], trigger="always"
        ),
        title=RoleConfig(primary="gpt-4o-mini", trigger="always"),
    ),
    "capacity": _pack(
        "capacity",
        "Models with large context windows for big tasks",
        planner=RoleConfig(
            primary="synthetic-Kimi-K2.5-Thinking",
            fallbacks=["firepass-kimi-k2p5-turbo"],
            trigger="context_overflow",
        ),
        coder=RoleConfig(
            primary="synthetic-qwen3.5-397b",
            fallbacks=["synthetic-Kimi-K2.5-Thinking"],
            trigger="context_overflow",
        ),
        reviewer=RoleConfig(
            primary="synthetic-Kimi-K2.5-Thinking",
            fallbacks=["claude-sonnet-4"],
            trigger="context_overflow",
        ),
        summarizer=RoleConfig(
            primary="synthetic-Kimi-K2.5-Thinking",
            fallbacks=["synthetic-qwen3.5-397b"],
            trigger="context_overflow",
        ),
        title=RoleConfig(primary="gpt-4o-mini", trigger="always"),
    ),
}

# User-defined packs storage (local fallback)
_user_packs: dict[str, ModelPack] = {}
_current_pack_name: str = "single"


def _pack_from_dict(data: dict[str, Any]) -> ModelPack:
    """Convert dict response to ModelPack."""
    roles = {
        name: RoleConfig(
            primary=cfg["primary"],
            fallbacks=cfg.get("fallbacks", []),
            trigger=cfg.get("trigger", "provider_failure"),
        )
        for name, cfg in data.get("roles", {}).items()
    }
    return ModelPack(
        name=data["name"],
        description=data.get("description", ""),
        roles=roles,
        default_role=data.get("default_role", "coder"),
    )


def _call_elixir(method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """Call Elixir model_packs method, fallback to local on error."""
    try:
        import asyncio

        from code_puppy.plugins.elixir_bridge import (
            call_elixir_model_packs,
            is_connected,
        )

        if is_connected():
            return asyncio.run(
                call_elixir_model_packs(
                    f"model_packs.{method}", params or {}, timeout=5.0
                )
            )
    except Exception as e:
        logger.debug(f"Elixir call failed, using local fallback: {e}")
    return {"status": "fallback"}


def get_pack(name: str | None = None) -> ModelPack:
    """Get a model pack by name (routes to Elixir)."""
    result = _call_elixir("get_pack", {"name": name} if name else {})
    if result.get("status") == "ok" and "pack" in result:
        return _pack_from_dict(result["pack"])
    # Fallback to local
    name = name or _current_pack_name
    if name in DEFAULT_PACKS:
        return DEFAULT_PACKS[name]
    if name in _user_packs:
        return _user_packs[name]
    logger.warning(f"Pack '{name}' not found, using 'single'")
    return DEFAULT_PACKS["single"]


def list_packs() -> list[ModelPack]:
    """List all available model packs (routes to Elixir)."""
    result = _call_elixir("list_packs")
    if result.get("status") == "ok" and "packs" in result:
        return [_pack_from_dict(p) for p in result["packs"]]
    # Fallback to local
    return list(DEFAULT_PACKS.values()) + list(_user_packs.values())


def set_current_pack(name: str) -> bool:
    """Set the current model pack (routes to Elixir)."""
    result = _call_elixir("set_current_pack", {"name": name})
    if result.get("status") == "ok":
        global _current_pack_name
        _current_pack_name = name
        return True
    # Fallback to local
    if name in DEFAULT_PACKS or name in _user_packs:
        _current_pack_name = name
        return True
    return False


def get_current_pack() -> ModelPack:
    """Get the currently active model pack (routes to Elixir)."""
    result = _call_elixir("get_current_pack")
    if result.get("status") == "ok" and "pack" in result:
        return _pack_from_dict(result["pack"])
    return get_pack(_current_pack_name)


def get_model_for_role(role: str | None = None) -> str:
    """Get the model for a specific role (routes to Elixir)."""
    result = _call_elixir("get_model_for_role", {"role": role} if role else {})
    if result.get("status") == "ok" and "model" in result:
        model = result["model"]
        return get_global_model_name() if model == "auto" else model
    # Fallback to local
    pack = get_current_pack()
    model = pack.get_model_for_role(role)
    return get_global_model_name() if model == "auto" else model


def create_user_pack(
    name: str,
    description: str,
    roles: dict[str, dict[str, Any]],
    default_role: str = "coder",
) -> ModelPack:
    """Create a new user-defined model pack (routes to Elixir)."""
    result = _call_elixir(
        "create_pack",
        {
            "name": name,
            "description": description,
            "roles": roles,
            "default_role": default_role,
        },
    )
    if result.get("status") == "ok" and "pack" in result:
        return _pack_from_dict(result["pack"])
    # Fallback to local
    if name in DEFAULT_PACKS:
        raise ValueError(f"Cannot override built-in pack: {name}")
    role_configs = {
        role_name: RoleConfig(
            primary=role_data.get("primary", "auto"),
            fallbacks=role_data.get("fallbacks", []),
            trigger=role_data.get("trigger", "provider_failure"),
        )
        for role_name, role_data in roles.items()
    }
    pack = ModelPack(
        name=name,
        description=description,
        roles=role_configs,
        default_role=default_role,
    )
    _user_packs[name] = pack
    return pack


def delete_user_pack(name: str) -> bool:
    """Delete a user-defined model pack (routes to Elixir)."""
    result = _call_elixir("delete_pack", {"name": name})
    if result.get("status") == "ok":
        return result.get("deleted", True)
    # Fallback to local
    if name in DEFAULT_PACKS:
        return False
    if name in _user_packs:
        del _user_packs[name]
        global _current_pack_name
        if _current_pack_name == name:
            _current_pack_name = "single"
        return True
    return False


def load_user_packs() -> None:
    """Load user-defined model packs from disk (routes to Elixir)."""
    result = _call_elixir("reload")
    logger.debug(f"load_user_packs result: {result}")


def save_user_packs() -> None:
    """Save user-defined model packs to disk (no-op in thin wrapper)."""
    pass  # Persistence handled by Elixir


def get_packs_file() -> str:
    """Get the path to the user-defined packs file."""
    from code_puppy.config_paths import resolve_path

    return str(resolve_path("model_packs.json"))


# Auto-load on import
load_user_packs()
