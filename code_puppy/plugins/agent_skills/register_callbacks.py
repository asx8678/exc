"""Agent Skills plugin - registers callbacks for skill integration.

This plugin:
1. Injects available skills into system prompts (with progressive disclosure)
2. Registers skill-related tools
3. Provides /skills slash command (and alias /skill)

Progressive Disclosure (default):
    - Only metadata (name, description, path) is injected into prompts
    - Agents use `read_file(file_path="<path>")` to load full SKILL.md on demand
    - Prevents context explosion with many skills installed

Legacy Mode (deprecated):
    - Full SKILL.md content injected into prompts
    - Can be enabled via `progressive_skill_disclosure = false` in config
"""

import logging
from pathlib import Path
from typing import Any

from code_puppy.callbacks import register_callback

logger = logging.getLogger(__name__)


def _get_skills_prompt_section() -> str | None:
    """Build the skills section to inject into system prompts.

    Uses progressive disclosure (metadata-only) by default. Falls back to
    legacy full-content injection for skills without YAML frontmatter.

    Returns None if skills are disabled or no skills found.
    """
    from .config import (
        get_disabled_skills,
        get_progressive_skill_disclosure,
        get_skill_directories,
        get_skills_enabled,
    )
    from .discovery import discover_skills
    from .metadata import MAX_SKILL_FILE_SIZE, SkillMetadata, parse_skill_metadata
    from .prompt_builder import (
        build_available_skills_markdown,
        build_available_skills_xml,
        build_skills_guidance,
    )

    # 1. Check if enabled
    if not get_skills_enabled():
        logger.debug("Skills integration is disabled, skipping prompt injection")
        return None

    # 2. Check if progressive disclosure is enabled
    use_progressive = get_progressive_skill_disclosure()

    # 3. Discover skills
    skill_dirs = [Path(d) for d in get_skill_directories()]
    discovered = discover_skills(skill_dirs)

    if not discovered:
        logger.debug("No skills discovered, skipping prompt injection")
        return None

    # 4. Parse metadata for each and filter out disabled skills
    disabled_skills = get_disabled_skills()
    skills_metadata: list[SkillMetadata] = []
    legacy_skills: list[tuple[Path, str]] = []  # (skill_path, full_content)

    for skill_info in discovered:
        # Skip disabled skills
        if skill_info.name in disabled_skills:
            logger.debug(f"Skipping disabled skill: {skill_info.name}")
            continue

        # Only include skills with valid SKILL.md
        if not skill_info.has_skill_md:
            logger.debug(f"Skipping skill without SKILL.md: {skill_info.name}")
            continue

        # Try to parse metadata (requires YAML frontmatter)
        metadata = parse_skill_metadata(skill_info.path)
        if metadata:
            skills_metadata.append(metadata)
        else:
            # No valid frontmatter - treat as legacy skill
            # In legacy mode, we inject the full content
            skill_md_path = skill_info.path / "SKILL.md"
            try:
                # Check size for DoS prevention
                file_size = skill_md_path.stat().st_size
                if file_size > MAX_SKILL_FILE_SIZE:
                    logger.warning(
                        f"Legacy skill file too large ({file_size} bytes), skipping: {skill_info.name}"
                    )
                    continue
                full_content = skill_md_path.read_text(encoding="utf-8")
                legacy_skills.append((skill_info.path, full_content))
                logger.warning(
                    f"Legacy skill '{skill_info.name}' has no YAML frontmatter. "
                    "Add frontmatter to enable progressive disclosure. "
                    "Full content will be injected (deprecated)."
                )
            except Exception as e:
                logger.warning(f"Failed to read legacy skill {skill_info.name}: {e}")

    # 5. Build the skills section based on mode
    sections: list[str] = []

    # Progressive disclosure mode (default)
    if use_progressive and skills_metadata:
        skills_block = build_available_skills_markdown(skills_metadata)
        if skills_block:
            sections.append(skills_block)
            logger.debug(
                f"Injecting progressive disclosure for {len(skills_metadata)} skills"
            )

    # Legacy XML mode (or progressive disabled)
    elif not use_progressive and skills_metadata:
        xml_section = build_available_skills_xml(skills_metadata)
        sections.append(xml_section)
        sections.append(build_skills_guidance())
        logger.debug(f"Injecting legacy XML for {len(skills_metadata)} skills")

    # Legacy skills without frontmatter (deprecation warning)
    if legacy_skills:
        deprecation_notice = """
## ⚠️ Legacy Skills (Deprecation Warning)

The following skills do not have YAML frontmatter and use the deprecated
full-content injection method. Please update these skills to use the new format:

```yaml
---
name: skill-name
description: What this skill does
---
```

**Legacy skill content:**
"""
        sections.append(deprecation_notice)
        for skill_path, content in legacy_skills:
            sections.append(f"### Skill at {skill_path}")
            sections.append("```markdown")
            sections.append(content[:50000])  # Limit to 50KB per legacy skill
            if len(content) > 50000:
                sections.append("... (content truncated, 50KB limit)")
            sections.append("```")
            sections.append("")
        logger.warning(
            f"Injected {len(legacy_skills)} legacy skills with full content (deprecated)"
        )

    # 6. Return combined string if we have any sections
    if not sections:
        logger.debug("No valid skills to inject, skipping prompt injection")
        return None

    combined = "\n\n".join(sections)
    return combined


def _inject_skills_into_prompt(
    model_name: str, default_system_prompt: str, user_prompt: str
) -> dict[str, Any] | None:
    """Callback to inject skills into system prompt.

    This is registered with the 'get_model_system_prompt' callback phase.
    """
    skills_section = _get_skills_prompt_section()

    if not skills_section:
        return None  # No skills, don't modify prompt

    # Append skills section to system prompt
    enhanced_prompt = f"{default_system_prompt}\n\n{skills_section}"

    return {
        "instructions": enhanced_prompt,
        "user_prompt": user_prompt,
        "handled": False,  # Let other handlers also process
    }


def _register_skills_tools() -> list[dict[str, Any]]:
    """Callback to register skills tools.

    This is registered with the 'register_tools' callback phase.
    Returns tool definitions for the tool registry.
    """
    from code_puppy.tools.skills_tools import (
        register_activate_skill,
        register_list_or_search_skills,
    )

    return [
        {"name": "activate_skill", "register_func": register_activate_skill},
        {
            "name": "list_or_search_skills",
            "register_func": register_list_or_search_skills,
        },
    ]


# ---------------------------------------------------------------------------
# Slash command: /skills (and alias /skill)
# ---------------------------------------------------------------------------

_COMMAND_NAME = "skills"
_ALIASES = "skill"


def _skills_command_help() -> list[tuple[str, str]]:
    """Advertise /skills in the /help menu."""
    return [
        ("skills", "Manage agent skills – browse, enable, disable, install"),
        ("skill", "Alias for /skills"),
    ]


def _handle_skills_command(command: str, name: str) -> Any | None:
    """Handle /skills and /skill slash commands.

    Sub-commands:
        /skills                     – Launch interactive TUI menu
        /skills list                – Quick text list of all skills
        /skills install             – Browse & install from remote catalog
        /skills enable              – Enable skills integration globally
        /skills disable             – Disable skills integration globally
        /skills progressive         – Show progressive disclosure status
        /skills progressive enable  – Enable progressive disclosure
        /skills progressive disable – Disable progressive disclosure (legacy mode)
    """
    if name not in (_COMMAND_NAME, *_ALIASES):
        return None

    from code_puppy.messaging import emit_error, emit_info, emit_success, emit_warning
    from code_puppy.plugins.agent_skills.config import (
        get_disabled_skills,
        get_progressive_skill_disclosure,
        get_skill_directories,
        get_skills_enabled,
        set_progressive_skill_disclosure,
        set_skills_enabled,
    )
    from code_puppy.plugins.agent_skills.discovery import discover_skills
    from code_puppy.plugins.agent_skills.metadata import parse_skill_metadata
    from code_puppy.plugins.agent_skills.skills_menu import show_skills_menu

    tokens = command.split()

    if len(tokens) > 1:
        subcommand = tokens[1].lower()

        if subcommand == "list":
            disabled_skills = get_disabled_skills()
            skills = discover_skills()
            enabled = get_skills_enabled()
            progressive = get_progressive_skill_disclosure()

            if not skills:
                emit_info("No skills found.")
                emit_info("Create skills in:")
                for d in get_skill_directories():
                    emit_info(f"  - {d}/")
                return True

            emit_info(
                f"\U0001f6e0\ufe0f Skills (integration: {'enabled' if enabled else 'disabled'}"
                f", progressive: {'on' if progressive else 'off'})"
            )
            emit_info(f"Found {len(skills)} skill(s):\n")

            for skill in skills:
                metadata = parse_skill_metadata(skill.path)
                if metadata:
                    status = (
                        "\U0001f534 disabled"
                        if metadata.name in disabled_skills
                        else "\U0001f7e2 enabled"
                    )
                    version_str = f" v{metadata.version}" if metadata.version else ""
                    author_str = f" by {metadata.author}" if metadata.author else ""
                    emit_info(f"  {status} {metadata.name}{version_str}{author_str}")
                    emit_info(f"      {metadata.description}")
                    if metadata.tags:
                        emit_info(f"      tags: {', '.join(metadata.tags)}")
                else:
                    status = (
                        "\U0001f534 disabled"
                        if skill.name in disabled_skills
                        else "\U0001f7e2 enabled"
                    )
                    emit_info(f"  {status} {skill.name}")
                    emit_info("      (legacy - no SKILL.md metadata)")
                emit_info("")
            return True

        elif subcommand == "install":
            from code_puppy.plugins.agent_skills.skills_install_menu import (
                run_skills_install_menu,
            )

            run_skills_install_menu()
            return True

        elif subcommand == "enable":
            set_skills_enabled(True)
            emit_success("\u2705 Skills integration enabled globally")
            return True

        elif subcommand == "disable":
            set_skills_enabled(False)
            emit_warning("\U0001f534 Skills integration disabled globally")
            return True

        elif subcommand == "progressive":
            # Progressive disclosure subcommands
            if len(tokens) > 2:
                progressive_subcmd = tokens[2].lower()
                if progressive_subcmd == "enable":
                    set_progressive_skill_disclosure(True)
                    emit_success(
                        "\u2705 Progressive disclosure enabled. "
                        "Only metadata will be injected; use `read_file` to load skills."
                    )
                    return True
                elif progressive_subcmd == "disable":
                    set_progressive_skill_disclosure(False)
                    emit_warning(
                        "\U0001f534 Progressive disclosure disabled (legacy mode). "
                        "Full skill content may be injected into prompts."
                    )
                    return True
                else:
                    emit_error(f"Unknown progressive subcommand: {progressive_subcmd}")
                    emit_info("Usage: /skills progressive [enable|disable]")
                    return True
            else:
                # Show current status
                progressive = get_progressive_skill_disclosure()
                if progressive:
                    emit_info(
                        "Progressive disclosure: ENABLED (default)\n"
                        "Only skill metadata is injected into prompts. "
                        "Agents use `read_file` to load full SKILL.md on demand.\n"
                        "This prevents context explosion with many skills."
                    )
                else:
                    emit_warning(
                        "Progressive disclosure: DISABLED (legacy mode)\n"
                        "Full skill content may be injected into prompts. "
                        "Not recommended for many skills.\n"
                        "Run `/skills progressive enable` to switch."
                    )
                return True

        else:
            emit_error(f"Unknown subcommand: {subcommand}")
            emit_info("Usage: /skills [list|install|enable|disable|progressive]")
            return True

    # No subcommand – launch TUI menu
    show_skills_menu()
    return True


# ---------------------------------------------------------------------------
# Register all callbacks
# ---------------------------------------------------------------------------
register_callback("get_model_system_prompt", _inject_skills_into_prompt)
register_callback("register_tools", _register_skills_tools)
register_callback("custom_command_help", _skills_command_help)
register_callback("custom_command", _handle_skills_command)

logger.info("Agent Skills plugin loaded")
