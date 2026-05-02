# Prompt Store Plugin

User-editable prompt templates for code_puppy agents. Add per-agent prompt instructions without writing Python code.

## Overview

The Prompt Store plugin provides a JSON-backed store for prompt templates. You can create and edit custom prompt instructions, switch between templates per agent, duplicate templates, and keep user instructions separate from built-in defaults.

## Commands

- /prompts list [agent] — List all templates.
- /prompts show <id> — Show a template.
- /prompts create <agent> <name> — Create prompt instructions.
- /prompts edit <id> — Edit a template.
- /prompts duplicate <id> <new-name> — Duplicate a template.
- /prompts delete <id> — Delete a template.
- /prompts activate <agent> <id> — Activate a template for an agent.
- /prompts reset <agent> — Remove the custom prompt addition for an agent.

## Additive behavior note

Prompt Store templates are appended to the built-in agent prompt. They are intended for extra instructions such as tone, format, or workflow preferences. They do not replace the built-in agent identity prompt.

## Integration

The plugin hooks into load_prompt. The agent builds its built-in system prompt first, then prompt_store appends any active instructions, and later get_model_system_prompt plugins can further enhance the combined prompt.

The get_model_system_prompt callback chain is applied sequentially so additive plugins can cooperate without clobbering earlier prompt content.

## Editor Comments

Lines starting with # // are treated as editor comments and stripped from the final content. Markdown headers such as # Heading and regular comments such as # TODO: fix this are preserved.
