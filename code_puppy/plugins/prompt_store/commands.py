"""Slash command handlers for the /prompts command.

Provides interactive CRUD operations for prompt templates:
    list, show, create, edit, duplicate, delete, activate, reset, help
"""

import logging
import os
import shlex
import subprocess
import tempfile
from typing import Any

from code_puppy.agents.agent_manager import get_current_agent, get_current_agent_name
from code_puppy.messaging import emit_error, emit_info, emit_success, emit_warning

from .store import PromptStore

logger = logging.getLogger(__name__)

# Global store instance - lazily initialized
_store: PromptStore | None = None


def _invalidate_system_prompt_cache(agent_name: str) -> None:
    """Invalidate system prompt cache for the current agent if it matches.

    Called when prompt templates are activated/reset to ensure the next
    agent invocation picks up the new prompt.

    Args:
        agent_name: Name of the agent whose prompt changed
    """
    try:
        agent = get_current_agent()
    except Exception:
        # No active agent or other error - cache invalidation is best-effort
        return

    if agent is None:
        return

    try:
        # Only invalidate if the current agent matches the affected agent
        if hasattr(agent, "name") and agent.name == agent_name:
            if hasattr(agent, "_state") and hasattr(
                agent._state, "invalidate_system_prompt_cache"
            ):
                agent._state.invalidate_system_prompt_cache()
                logger.debug(
                    f"Invalidated system prompt + overhead cache for {agent_name}"
                )
            elif hasattr(agent, "_state") and hasattr(
                agent._state, "cached_system_prompt"
            ):
                # Fallback for older state objects
                agent._state.cached_system_prompt = None
                logger.debug(f"Invalidated system prompt cache for {agent_name}")
    except Exception:
        # Best-effort: never crash slash commands due to cache invalidation
        logger.debug(
            "prompt_store: cache invalidation failed (non-critical)", exc_info=True
        )


def _get_store() -> PromptStore:
    """Get or create the global PromptStore instance."""
    global _store
    if _store is None:
        _store = PromptStore()
    return _store


# Sentinel-style comment prefix for editor-added comments.
# Using '# // ' as the sentinel ensures it won't collide with:
#   - Markdown headers (e.g., '# Heading', '## Subheader')
#   - Code comments (e.g., '# This is a Python comment')
# Editor comments MUST use this exact prefix to be stripped.
_COMMENT_SENTINEL = "# // "


def _strip_editor_comments(content: str) -> str:
    """Strip editor-added comments from content.

    Uses sentinel-style approach: only lines starting with '# // ' are stripped.
    This preserves all other content, including:
        - Markdown headers (for example: '# Heading', '## Subheader')
        - Code comments (for example: '# TODO: fix this')
        - Any other lines starting with '#'

    Args:
        content: Raw content from editor

    Returns:
        Content with editor comments removed
    """
    lines = content.split("\n")
    result_lines = []
    for line in lines:
        stripped = line.strip()
        # Only strip lines that start with '# // ' (sentinel for editor comments)
        if stripped.startswith(_COMMENT_SENTINEL):
            continue
        result_lines.append(line)
    return "\n".join(result_lines).strip()


def _get_editor_command() -> list[str]:
    """Get the editor command to use, tokenized for subprocess.

    Priority: $VISUAL > $EDITOR > nano (Unix) / notepad (Windows)

    Returns:
        List of command arguments (e.g., ["code", "--wait"] for EDITOR="code --wait")
    """
    editor = os.environ.get("VISUAL") or os.environ.get("EDITOR")
    if editor:
        return shlex.split(editor)
    # Platform defaults
    if os.name == "nt":
        return ["notepad"]
    return ["nano"]


def _open_editor(initial_content: str) -> str | None:
    """Open the user's preferred editor with initial content.

    Args:
        initial_content: Content to pre-fill in the editor

    Returns:
        The edited content, or None if the user cancelled/failed
    """
    editor_cmd = _get_editor_command()

    # Create temp file with initial content
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".txt", delete=False, encoding="utf-8"
    ) as f:
        f.write(initial_content)
        temp_path = f.name

    try:
        # Launch editor (editor_cmd is already a list, append temp_path)
        result = subprocess.call([*editor_cmd, temp_path])
        if result != 0:
            logger.warning(f"Editor exited with code {result}")
            return None

        # Read back the content
        with open(temp_path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        emit_error(f"Editor not found: {editor_cmd[0]}")
        emit_info(
            "Set $VISUAL or $EDITOR environment variable to your preferred editor"
        )
        return None
    except Exception as e:
        emit_error(f"Failed to open editor: {e}")
        return None
    finally:
        # Clean up temp file
        try:
            os.unlink(temp_path)
        except Exception:
            pass


def _handle_list(args: list[str]) -> None:
    """Handle /prompts list [agent] command."""
    store = _get_store()

    agent_filter = None
    if len(args) > 0:
        agent_filter = args[0]

    templates = store.list_templates(agent_name=agent_filter)

    if not templates:
        if agent_filter:
            emit_info(f"No templates found for agent: {agent_filter}")
        else:
            emit_info(
                "No templates found. Create one with: /prompts create <agent> <name>"
            )
        return

    # Group by agent
    by_agent: dict[str, list] = {}
    active_map = {}  # agent -> active template_id

    # Get active templates for context
    if agent_filter:
        active_tmpl = store.get_active_for_agent(agent_filter)
        if active_tmpl:
            active_map[agent_filter] = active_tmpl.id
    else:
        # Get all unique agent names and check their active templates
        agents = set(t.agent_name for t in templates)
        for agent in agents:
            active_tmpl = store.get_active_for_agent(agent)
            if active_tmpl:
                active_map[agent] = active_tmpl.id

    for tmpl in templates:
        by_agent.setdefault(tmpl.agent_name, []).append(tmpl)

    emit_info(f"📋 Prompt Templates ({len(templates)} total):\n")

    for agent_name in sorted(by_agent.keys()):
        emit_info(f"🔹 {agent_name}:")
        for tmpl in by_agent[agent_name]:
            active_marker = " ⭐" if tmpl.id == active_map.get(agent_name) else ""
            locked_marker = " 🔒" if tmpl.locked else ""
            source_marker = " [built-in]" if tmpl.source == "default" else ""
            emit_info(f"  • {tmpl.name}{active_marker}{locked_marker}{source_marker}")
            emit_info(f"    ID: {tmpl.id}")
        emit_info("")


def _handle_show(args: list[str]) -> None:
    """Handle /prompts show <id> command."""
    if not args:
        emit_error("Usage: /prompts show <id>")
        return

    template_id = args[0]
    store = _get_store()
    tmpl = store.get_template(template_id)

    if tmpl is None:
        emit_error(f"Template not found: {template_id}")
        return

    active_for = None
    for agent in set(t.agent_name for t in store.list_templates()):
        active = store.get_active_for_agent(agent)
        if active and active.id == tmpl.id:
            active_for = agent
            break

    emit_info(f"📄 Template: {tmpl.name}")
    emit_info(f"   ID: {tmpl.id}")
    emit_info(f"   Agent: {tmpl.agent_name}")
    emit_info(f"   Source: {tmpl.source}{' 🔒' if tmpl.locked else ''}")
    if active_for:
        emit_info(f"   ⭐ Active for: {active_for}")
    emit_info(f"   Created: {tmpl.created_at}")
    emit_info(f"   Updated: {tmpl.updated_at}")
    emit_info("")
    emit_info("Content:")
    emit_info("-" * 40)
    emit_info(tmpl.content)
    emit_info("-" * 40)


def _handle_create(args: list[str]) -> None:
    """Handle /prompts create <agent> <name> command."""
    if len(args) < 2:
        emit_error("Usage: /prompts create <agent> <name>")
        emit_info('Example: /prompts create code-puppy "My Custom Prompt"')
        return

    agent_name = args[0]
    name = " ".join(args[1:])  # Allow multi-word names

    store = _get_store()

    # Open editor with starter content.
    # IMPORTANT: Editor comments must use '# // ' prefix to be stripped.
    starter = f"""# // Add extra instructions for {agent_name}
# // These lines are appended to the built-in agent prompt.
# // Lines starting with '# // ' are ignored (all other lines preserved)

Prefer concise, actionable responses.
"""
    content = _open_editor(starter)

    if content is None:
        emit_warning("Creation cancelled")
        return

    # Strip editor comments (sentinel-style: only lines starting with '# // ')
    content = _strip_editor_comments(content)

    if not content:
        emit_error("Prompt content cannot be empty")
        return

    try:
        tmpl = store.create_template(name=name, agent_name=agent_name, content=content)
        emit_success(f"✅ Created template: {tmpl.id}")
        emit_info(f"   Name: {tmpl.name}")
        emit_info(f"   Agent: {tmpl.agent_name}")
        emit_info(f"\nUse '/prompts activate {agent_name} {tmpl.id}' to activate it")
    except ValueError as e:
        emit_error(f"Failed to create template: {e}")


def _handle_edit(args: list[str]) -> None:
    """Handle /prompts edit <id> command."""
    if not args:
        emit_error("Usage: /prompts edit <id>")
        return

    template_id = args[0]
    store = _get_store()
    tmpl = store.get_template(template_id)

    if tmpl is None:
        emit_error(f"Template not found: {template_id}")
        return

    if tmpl.locked:
        emit_error(f"Template is locked and cannot be edited: {template_id}")
        emit_info("Use '/prompts duplicate' to create an editable copy")
        return

    # Open editor with current content.
    # IMPORTANT: Editor comments must use '# // ' prefix to be stripped.
    header = (
        f"# // Editing instructions for: {tmpl.name} ({tmpl.id})\n"
        "# // These instructions are appended to the built-in agent prompt.\n"
        f"# // Lines starting with '# // ' are ignored (all other lines preserved)\n\n"
    )
    content = _open_editor(header + tmpl.content)

    if content is None:
        emit_warning("Edit cancelled")
        return

    # Strip editor comments (sentinel-style: only lines starting with '# // ')
    content = _strip_editor_comments(content)

    if not content:
        emit_error("Prompt content cannot be empty")
        return

    try:
        updated = store.update_template(template_id, content=content)
        emit_success(f"✅ Updated template: {updated.id}")
        emit_info(f"   Updated at: {updated.updated_at}")
    except ValueError as e:
        emit_error(f"Failed to update template: {e}")


def _handle_duplicate(args: list[str]) -> None:
    """Handle /prompts duplicate <id> <new-name> command."""
    if len(args) < 2:
        emit_error("Usage: /prompts duplicate <id> <new-name>")
        emit_info('Example: /prompts duplicate code-puppy.custom-1 "My Copy"')
        return

    source_id = args[0]
    new_name = " ".join(args[1:])

    store = _get_store()

    try:
        new_tmpl = store.duplicate_template(source_id, new_name)
        emit_success(f"✅ Duplicated template: {new_tmpl.id}")
        emit_info(f"   Name: {new_tmpl.name}")
        emit_info(f"   Source: {source_id}")
        emit_info(f"\nUse '/prompts edit {new_tmpl.id}' to customize it")
    except ValueError as e:
        emit_error(f"Failed to duplicate template: {e}")


def _handle_delete(args: list[str]) -> None:
    """Handle /prompts delete <id> command."""
    if not args:
        emit_error("Usage: /prompts delete <id>")
        return

    template_id = args[0]
    store = _get_store()

    tmpl = store.get_template(template_id)
    if tmpl is None:
        emit_error(f"Template not found: {template_id}")
        return

    if tmpl.locked:
        emit_error(f"Template is locked and cannot be deleted: {template_id}")
        return

    try:
        deleted = store.delete_template(template_id)
        if deleted:
            emit_success(f"✅ Deleted template: {template_id}")
        else:
            emit_error(f"Failed to delete template: {template_id}")
    except ValueError as e:
        emit_error(f"Failed to delete template: {e}")


def _handle_activate(args: list[str]) -> None:
    """Handle /prompts activate <agent> <id> command."""
    if len(args) < 2:
        emit_error("Usage: /prompts activate <agent> <id>")
        return

    agent_name = args[0]
    template_id = args[1]

    store = _get_store()

    tmpl = store.get_template(template_id)
    if tmpl is None:
        emit_error(f"Template not found: {template_id}")
        return

    # Check if template is for this agent (warn but allow)
    if tmpl.agent_name != agent_name:
        emit_warning(
            f"Template {template_id} was created for '{tmpl.agent_name}', "
            f"not '{agent_name}'"
        )

    try:
        store.set_active_for_agent(agent_name, template_id)
        _invalidate_system_prompt_cache(agent_name)
        emit_success(f"✅ Activated template for {agent_name}: {tmpl.name}")
        emit_info(f"   ID: {template_id}")
        emit_info(
            "\nThe next time you use this agent, it will append these custom instructions."
        )
    except ValueError as e:
        emit_error(f"Failed to activate template: {e}")


def _handle_reset(args: list[str]) -> None:
    """Handle /prompts reset <agent> command."""
    if not args:
        emit_error("Usage: /prompts reset <agent>")
        return

    agent_name = args[0]
    store = _get_store()

    store.clear_active_for_agent(agent_name)
    _invalidate_system_prompt_cache(agent_name)
    emit_success(f"✅ Reset prompt for {agent_name}")
    emit_info("Next run will use the default built-in prompt without this addition.")


def _handle_help() -> None:
    """Handle /prompts help command."""
    emit_info("📖 Prompt Store Commands:\n")
    emit_info(
        "  /prompts list [agent]        - List all templates (optionally filter by agent)"
    )
    emit_info("  /prompts show <id>           - Show full content of a template")
    emit_info(
        "  /prompts create <agent> <name> - Create prompt instructions (opens $EDITOR)"
    )
    emit_info("  /prompts edit <id>           - Edit existing template")
    emit_info(
        "  /prompts duplicate <id> <new-name> - Create editable copy of any template"
    )
    emit_info("  /prompts delete <id>          - Delete a user template")
    emit_info("  /prompts activate <agent> <id> - Activate template for an agent")
    emit_info(
        "  /prompts reset <agent>        - Remove the custom prompt addition for an agent"
    )
    emit_info("  /prompts help                 - Show this help\n")
    emit_info("Workflow: create → edit → activate")
    emit_info("Storage: ~/.code_puppy/prompt_store.json")


def handle_prompts_command(command: str, name: str) -> Any | None:
    """Main entry point for /prompts commands.

    Args:
        command: The full command string (e.g., "/prompts list code-puppy")
        name: The command name without slash (e.g., "prompts")

    Returns:
        True if handled, None if not (allows other handlers)
    """
    if name != "prompts":
        return None

    tokens = command.split()
    # tokens[0] is "/prompts", tokens[1] is subcommand if present

    if len(tokens) == 1:
        # Just "/prompts" - default to list
        _handle_list([])
        return True

    subcommand = tokens[1].lower()
    args = tokens[2:]

    try:
        if subcommand == "list":
            _handle_list(args)
        elif subcommand == "show":
            _handle_show(args)
        elif subcommand == "create":
            _handle_create(args)
        elif subcommand == "edit":
            _handle_edit(args)
        elif subcommand == "duplicate":
            _handle_duplicate(args)
        elif subcommand == "delete":
            _handle_delete(args)
        elif subcommand == "activate":
            _handle_activate(args)
        elif subcommand == "reset":
            _handle_reset(args)
        elif subcommand == "help":
            _handle_help()
        else:
            emit_error(f"Unknown subcommand: {subcommand}")
            emit_info("Run '/prompts help' for available commands")
        return True
    except Exception as e:
        logger.exception(f"Error handling /prompts {subcommand}")
        emit_error(f"Internal error: {e}")
        return True


def get_prompts_help() -> list[tuple[str, str]]:
    """Return help entries for custom_command_help hook."""
    return [
        ("/prompts list [agent]", "List prompt templates (all or for one agent)"),
        ("/prompts show <id>", "Show full content of a template"),
        ("/prompts create <agent> <name>", "Create prompt instructions (opens editor)"),
        ("/prompts edit <id>", "Edit an existing user template"),
        (
            "/prompts duplicate <id> <new-name>",
            "Duplicate a template (creates editable copy)",
        ),
        ("/prompts delete <id>", "Delete a user template"),
        ("/prompts activate <agent> <id>", "Activate a template for an agent"),
        ("/prompts reset <agent>", "Remove the custom prompt addition for an agent"),
        ("/prompts help", "Show this help"),
    ]


def load_custom_prompt() -> str | None:
    """Callback for load_prompt hook.

    If the user has set active prompt instructions for the current agent,
    return them so they can be appended to the built-in prompt.

    This runs BEFORE get_model_system_prompt hooks, so later prompt plugins
    can further enhance the combined prompt without losing these user
    instructions.

    Returns:
        Prompt instructions if an active template exists, None otherwise
    """
    try:
        agent_name = get_current_agent_name()
    except Exception:
        return None

    if not agent_name:
        return None

    store = _get_store()
    template = store.get_active_for_agent(agent_name)

    if template is None:
        return None  # Let other handlers process

    # Return the active template content so it is appended via load_prompt.
    return template.content
