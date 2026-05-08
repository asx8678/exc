"""Configuration presets for Code Puppy.

This module implements named configuration presets inspired by Plandex auto modes.
Presets are collections of configuration values that can be applied atomically
to switch between different operating modes.

Available presets:
- basic: Minimal automation, conservative safety settings
- semi: Balanced automation with safety checks
- full: Maximum automation, YOLO mode enabled
- pack: Pack agents enabled for complex multi-agent workflows
"""

from dataclasses import dataclass
from typing import Any

from code_puppy.config import set_value
from code_puppy.messaging import emit_info, emit_success, emit_warning


@dataclass(frozen=True)
class ConfigPreset:
    """A named collection of configuration values.

    Attributes:
        name: Preset identifier (e.g., "basic", "full")
        display_name: Human-readable name for UI display
        description: One-line description of what this preset does
        detailed_help: Multi-line help text explaining the preset
        values: Dictionary of config keys to values
    """

    name: str
    display_name: str
    description: str
    detailed_help: str
    values: dict[str, Any]


# Define the built-in presets
# These can be overridden or extended via ~/.code_puppy/presets.json in the future

BASIC_PRESET = ConfigPreset(
    name="basic",
    display_name="Basic",
    description="Minimal automation, conservative safety",
    detailed_help=(
        "The basic preset uses minimal automation and conservative safety settings.\n\n"
        "Configuration:\n"
        "- yolo_mode: false (manual confirmation required)\n"
        "- enable_pack_agents: false (pack agents disabled)\n"
        "- enable_universal_constructor: false (UC disabled)\n"
        "- safety_permission_level: medium\n"
        "- compaction_strategy: summarization\n"
        "- enable_streaming: true\n\n"
        "Best for: Users who want maximum control and safety, or are new to Code Puppy."
    ),
    values={
        "yolo_mode": "false",
        "enable_pack_agents": "false",
        "enable_universal_constructor": "false",
        "safety_permission_level": "medium",
        "compaction_strategy": "summarization",
        "enable_streaming": "true",
    },
)


SEMI_PRESET = ConfigPreset(
    name="semi",
    display_name="Semi",
    description="Balanced automation with safety checks",
    detailed_help=(
        "The semi preset balances automation with safety checks.\n\n"
        "Configuration:\n"
        "- yolo_mode: false (manual confirmation required)\n"
        "- enable_pack_agents: false (pack agents disabled)\n"
        "- enable_universal_constructor: true (UC enabled for complex tasks)\n"
        "- safety_permission_level: medium\n"
        "- compaction_strategy: summarization\n"
        "- enable_streaming: true\n\n"
        "Best for: Daily development work with a good balance of assistance and control."
    ),
    values={
        "yolo_mode": "false",
        "enable_pack_agents": "false",
        "enable_universal_constructor": "true",
        "safety_permission_level": "medium",
        "compaction_strategy": "summarization",
        "enable_streaming": "true",
    },
)


FULL_PRESET = ConfigPreset(
    name="full",
    display_name="Full",
    description="Maximum automation, YOLO mode",
    detailed_help=(
        "The full preset enables maximum automation with YOLO mode.\n\n"
        "Configuration:\n"
        "- yolo_mode: true (auto-approve shell commands)\n"
        "- enable_pack_agents: true (pack agents enabled)\n"
        "- enable_universal_constructor: true (UC enabled)\n"
        "- safety_permission_level: low\n"
        "- compaction_strategy: summarization\n"
        "- enable_streaming: true\n\n"
        "WARNING: Shell commands will execute without confirmation!\n\n"
        "Best for: Experienced users who want maximum productivity and understand the risks."
    ),
    values={
        "yolo_mode": "true",
        "enable_pack_agents": "true",
        "enable_universal_constructor": "true",
        "safety_permission_level": "low",
        "compaction_strategy": "summarization",
        "enable_streaming": "true",
    },
)


PACK_PRESET = ConfigPreset(
    name="pack",
    display_name="Pack",
    description="Pack agents for complex workflows",
    detailed_help=(
        "The pack preset enables pack agents for complex multi-agent workflows.\n\n"
        "Configuration:\n"
        "- yolo_mode: false (manual confirmation - safety first)\n"
        "- enable_pack_agents: true (pack-leader, husky, shepherd, terrier)\n"
        "- enable_universal_constructor: true (UC enabled)\n"
        "- safety_permission_level: medium\n"
        "- compaction_strategy: summarization\n"
        "- enable_streaming: true\n\n"
        "Use /pack-help to learn about the pack agents.\n\n"
        "Best for: Complex tasks that benefit from coordinated multi-agent workflows."
    ),
    values={
        "yolo_mode": "false",
        "enable_pack_agents": "true",
        "enable_universal_constructor": "true",
        "safety_permission_level": "medium",
        "compaction_strategy": "summarization",
        "enable_streaming": "true",
    },
)


# Registry of all built-in presets
BUILTIN_PRESETS: dict[str, ConfigPreset] = {
    BASIC_PRESET.name: BASIC_PRESET,
    SEMI_PRESET.name: SEMI_PRESET,
    FULL_PRESET.name: FULL_PRESET,
    PACK_PRESET.name: PACK_PRESET,
}


def get_preset(name: str) -> ConfigPreset | None:
    """Get a preset by name.

    Args:
        name: Preset name (e.g., "basic", "full")

    Returns:
        ConfigPreset if found, None otherwise
    """
    return BUILTIN_PRESETS.get(name.lower())


def list_presets() -> list[ConfigPreset]:
    """Get all available presets.

    Returns:
        List of all built-in presets
    """
    return list(BUILTIN_PRESETS.values())


def apply_preset(name: str, emit: bool = True) -> bool:
    """Apply a preset by name.

    Args:
        name: Preset name to apply
        emit: Whether to emit status messages

    Returns:
        True if preset was applied successfully, False otherwise
    """
    preset = get_preset(name)
    if preset is None:
        available = ", ".join(BUILTIN_PRESETS.keys())
        if emit:
            emit_warning(f"Unknown preset: {name}")
            emit_info(f"Available presets: {available}")
        return False

    # Apply all preset values
    for key, value in preset.values.items():
        set_value(key, value)

    if emit:
        emit_success(f"Applied '{preset.display_name}' preset: {preset.description}")
        if preset.name == "full":
            emit_warning(
                "YOLO mode is now enabled - shell commands will execute without confirmation!"
            )

    return True


def get_current_preset_guess() -> str | None:
    """Try to guess which preset matches current config.

    Returns:
        Preset name if there's a good match, None otherwise
    """
    from code_puppy.config import (
        get_compaction_strategy,
        get_enable_streaming,
        get_pack_agents_enabled,
        get_safety_permission_level,
        get_universal_constructor_enabled,
        get_yolo_mode,
    )

    # Get current config state
    current = {
        "yolo_mode": str(get_yolo_mode()).lower(),
        "enable_pack_agents": str(get_pack_agents_enabled()).lower(),
        "enable_universal_constructor": str(
            get_universal_constructor_enabled()
        ).lower(),
        "safety_permission_level": get_safety_permission_level(),
        "compaction_strategy": get_compaction_strategy(),
        "enable_streaming": str(get_enable_streaming()).lower(),
    }

    # Check each preset for match
    for name, preset in BUILTIN_PRESETS.items():
        if all(current.get(k) == v.lower() for k, v in preset.values.items()):
            return name

    return None
