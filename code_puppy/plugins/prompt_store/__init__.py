"""Prompt Store plugin for user-editable prompt templates.

This plugin provides a JSON-backed store for custom prompt templates,
allowing users to customize agent system prompts without writing Python code.

Usage:
    /prompts list [agent]      - List prompt templates
    /prompts show <id>          - Show template content
    /prompts create <agent> <name>  - Create new template (opens editor)
    /prompts edit <id>          - Edit existing template
    /prompts duplicate <id> <new-name>  - Duplicate a template
    /prompts delete <id>        - Delete a user template
    /prompts activate <agent> <id>    - Make template active for agent
    /prompts reset <agent>      - Clear active template (revert to default)
    /prompts help               - Show help

The store is located at ~/.code_puppy/prompt_store.json
"""

__version__ = "0.1.0"
