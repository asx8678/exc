"""Prompt injection and memory formatting for agent memory.

Handles formatting facts into memory sections and injecting them into
system prompts.
"""

import logging
from typing import TYPE_CHECKING, Any

from code_puppy.run_context import get_current_run_context

from .config import load_config
from .core import _get_storage, is_memory_enabled_global

if TYPE_CHECKING:
    from .storage import Fact

logger = logging.getLogger(__name__)


def _format_memory_section(
    facts: list[Fact],
    max_facts: int,
    token_budget: int,
) -> str | None:
    """Format facts into a memory section for prompt injection.

    Args:
        facts: List of facts to format
        max_facts: Maximum number of facts to include
        token_budget: Maximum tokens for the section

    Returns:
        Formatted memory section string, or None if no facts fit
    """
    if not facts:
        return None

    # Sort by confidence (highest first)
    sorted_facts = sorted(
        facts,
        key=lambda f: f.get("confidence", 0.0),
        reverse=True,
    )

    # Rough token estimation: ~4 chars per token
    chars_per_token = 4
    max_chars = token_budget * chars_per_token

    lines = ["## Memory"]
    current_chars = len(lines[0]) + 1  # +1 for newline

    for fact in sorted_facts[:max_facts]:
        text = fact.get("text", "").strip()
        confidence = fact.get("confidence", 0.5)

        if not text:
            continue

        line = f"- {text} (confidence: {confidence:.1f})"
        line_chars = len(line) + 1  # +1 for newline

        if current_chars + line_chars > max_chars:
            break

        lines.append(line)
        current_chars += line_chars

    if len(lines) == 1:  # Only header, no facts
        return None

    return "\n".join(lines)


def _on_load_prompt(
    model_name: str,
    default_system_prompt: str,
    user_prompt: str,
) -> dict[str, Any] | None:
    """Inject relevant memories into the system prompt.

    Loads top facts for the current agent (sorted by confidence) and
    injects them into the system prompt within the configured token budget.

    Args:
        model_name: Name of the model being used
        default_system_prompt: The default system prompt
        user_prompt: The user's prompt

    Returns:
        Dict with enhanced prompt if memories found, None otherwise
    """
    # Always call load_config() to support mocking in tests
    config = load_config()

    if not is_memory_enabled_global() or not config.enabled:
        return None

    try:
        # Get current agent name from context
        agent_name = None
        ctx = get_current_run_context()
        if ctx:
            agent_name = ctx.component_name

        if not agent_name:
            # Try to get from agent manager
            try:
                from code_puppy.agents import get_current_agent

                agent = get_current_agent()
                if agent:
                    agent_name = agent.name
            except Exception:
                pass

        if not agent_name:
            return None

        # Get facts for this agent
        storage = _get_storage(agent_name)
        facts = storage.get_facts(min_confidence=config.min_confidence)

        if not facts:
            return None

        # Format memory section
        memory_section = _format_memory_section(
            facts,
            max_facts=config.max_facts,
            token_budget=config.token_budget,
        )

        if not memory_section:
            return None

        # Inject into prompt
        enhanced_prompt = f"{default_system_prompt}\n\n{memory_section}"

        return {
            "instructions": enhanced_prompt,
            "user_prompt": user_prompt,
            "handled": False,  # Allow other plugins to also modify
        }

    except Exception as e:
        logger.debug(f"Memory prompt injection failed: {e}")
        return None
