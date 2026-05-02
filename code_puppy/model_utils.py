"""Model-related utilities shared across agents and tools.

This module centralizes logic for handling model-specific behaviors,
particularly for claude-code models which require special prompt handling.

Plugins can register custom system prompt handlers via the 'get_model_system_prompt'
callback to extend support for additional model types.
"""

from dataclasses import dataclass

# The instruction override used for claude-code models
CLAUDE_CODE_INSTRUCTIONS = "You are Claude Code, Anthropic's official CLI for Claude."


@dataclass
class PreparedPrompt:
    """Result of preparing a prompt for a specific model.

    Attributes:
        instructions: The system instructions to use for the agent
        user_prompt: The user prompt (possibly modified)
        is_claude_code: Whether this is a claude-code model
    """

    instructions: str
    user_prompt: str
    is_claude_code: bool


def is_claude_code_model(model_name: str) -> bool:
    """Check if a model is a claude-code model."""
    return model_name.startswith("claude-code")


def prepare_prompt_for_model(
    model_name: str,
    system_prompt: str,
    user_prompt: str,
    prepend_system_to_user: bool = True,
) -> PreparedPrompt:
    """Prepare instructions and prompt for a specific model.

    This function handles model-specific system prompt requirements. Plugins can
    register custom handlers via the 'get_model_system_prompt' callback to extend
    support for additional model types.

    Args:
        model_name: The name of the model being used
        system_prompt: The default system prompt from the agent
        user_prompt: The user's prompt/message
        prepend_system_to_user: Whether to prepend system prompt to user prompt
            for models that require it (default: True)

    Returns:
        PreparedPrompt with instructions and user_prompt ready for the model.
    """
    # Check for plugin-registered system prompt handlers first
    from code_puppy import callbacks

    results = callbacks.on_get_model_system_prompt(
        model_name, system_prompt, user_prompt
    )
    effective_system_prompt = system_prompt
    effective_user_prompt = user_prompt
    plugin_fully_handled = False
    plugin_is_claude_code = False

    for result in results:
        if not result or not isinstance(result, dict):
            continue
        effective_system_prompt = result.get("instructions", effective_system_prompt)
        effective_user_prompt = result.get("user_prompt", effective_user_prompt)
        if result.get("handled"):
            plugin_fully_handled = True
            plugin_is_claude_code = result.get("is_claude_code", False)

    if plugin_fully_handled:
        return PreparedPrompt(
            instructions=effective_system_prompt,
            user_prompt=effective_user_prompt,
            is_claude_code=plugin_is_claude_code,
        )

    system_prompt = effective_system_prompt
    user_prompt = effective_user_prompt

    # Handle Claude Code models
    if is_claude_code_model(model_name):
        modified_prompt = user_prompt
        if prepend_system_to_user and system_prompt:
            modified_prompt = f"{system_prompt}\n\n{user_prompt}"
        return PreparedPrompt(
            instructions=CLAUDE_CODE_INSTRUCTIONS,
            user_prompt=modified_prompt,
            is_claude_code=True,
        )

    return PreparedPrompt(
        instructions=system_prompt, user_prompt=user_prompt, is_claude_code=False
    )


def get_claude_code_instructions() -> str:
    """Get the standard claude-code instructions string."""
    return CLAUDE_CODE_INSTRUCTIONS


def get_default_extended_thinking(model_name: str) -> str:
    """Return the default extended_thinking mode for an Anthropic model.

    Opus 4-6 models default to ``"adaptive"`` thinking; all other
    Anthropic models default to ``"enabled"``.

    Args:
        model_name: The model name string (e.g. ``"claude-opus-4-6"``).

    Returns:
        ``"adaptive"`` for Opus 4-6 variants, ``"enabled"`` otherwise.
    """
    lower = model_name.lower()
    if "opus-4-6" in lower or "4-6-opus" in lower:
        return "adaptive"
    return "enabled"
