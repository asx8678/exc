"""Build available_skills prompts for system prompt injection.

Supports two modes:
1. XML format (legacy): Wraps skill metadata in XML tags
2. Markdown format (progressive disclosure): Clean markdown with paths for read_file
"""

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .metadata import SkillMetadata


def build_available_skills_xml(skills: list["SkillMetadata"]) -> str:
    """Build Claude-optimized XML listing available skills.

    Args:
        skills: List of SkillMetadata objects to include in the XML.

    Returns:
        XML string listing available skills in the format:
        <available_skills>
          <skill>
            <name>skill-name</name>
            <description>What the skill does...</description>
          </skill>
          ...
        </available_skills>

    To use a skill, call activate_skill(skill_name) to load full instructions.
    """
    if not skills:
        return "<available_skills></available_skills>"

    xml_parts = ["<available_skills>"]

    for skill in skills:
        xml_parts.append("  <skill>")
        xml_parts.append(f"    <name>{skill.name}</name>")
        if skill.description:
            # Escape any XML special characters in the description
            escaped_desc = (
                skill.description.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace('"', "&quot;")
                .replace("'", "&#39;")
            )
            xml_parts.append(f"    <description>{escaped_desc}</description>")
        xml_parts.append("  </skill>")

    xml_parts.append("</available_skills>")

    return "\n".join(xml_parts)


def build_skills_guidance() -> str:
    """Return guidance text for how to use skills."""
    return """
# Agent Skills

When `<available_skills>` appears in context, match user tasks to skill descriptions.
Call `activate_skill(skill_name)` to load full instructions before starting the task.
Use `list_or_search_skills(query)` to search for relevant skills.
"""


def build_available_skills_markdown(skills: list["SkillMetadata"]) -> str | None:
    """Build markdown listing available skills for progressive disclosure.

    Progressive disclosure injects only metadata (name, description, path) into
    system prompts, allowing agents to pull full SKILL.md content on-demand
    using the read_file tool. This prevents context explosion with many skills.

    Args:
        skills: List of SkillMetadata objects to include.

    Returns:
        Markdown string with skill metadata, or None if no skills.
    """
    if not skills:
        return None

    lines = [
        "## Available Skills (Progressive Disclosure)",
        "",
        "The following skills are available. Each shows its name, when to use it,",
        "and the absolute path to its full instructions.",
        "**You must read the full SKILL.md file to use a skill** — the metadata below is only a summary.",
        "",
    ]

    for skill in skills:
        lines.append(f"### {skill.name}")
        lines.append(f"**When to use**: {skill.description}")
        lines.append(f"**Full instructions**: `{skill.skill_md_path}`")
        if skill.version:
            lines.append(f"**Version**: {skill.version}")
        if skill.author:
            lines.append(f"**Author**: {skill.author}")
        if skill.tags:
            lines.append(f"**Tags**: {', '.join(skill.tags)}")
        if skill.license:
            lines.append(f"**License**: {skill.license}")
        lines.append("")

    lines.extend(
        [
            "**How to use a skill:**",
            "1. **Recognize when a skill applies** — check 'When to use' descriptions above",
            '2. **Read the full SKILL.md** — use `read_file(file_path="<path>")` tool to load complete instructions',
            "3. **Follow the skill's workflow** — the SKILL.md contains detailed steps and examples",
            "",
        ]
    )

    return "\n".join(lines)


def build_progressive_disclosure_guidance() -> str:
    """Return guidance for using skills with progressive disclosure.

    Progressive disclosure only shows metadata in prompts; full content is
    loaded on-demand using the read_file tool.
    """
    return """
## Using Skills (Progressive Disclosure)

Skills available above provide metadata only. To use a skill:

1. **Identify the relevant skill** by matching the task to "When to use" descriptions
2. **Load the full skill** by calling `read_file(file_path="/path/to/skill/SKILL.md")` with the path shown
3. **Follow the instructions** in the loaded SKILL.md to complete the task

This approach keeps context small while giving you access to all installed skills.
"""
