"""Register callbacks for the Agent Memory plugin.

Phases 5 & 6: Full plugin integration with config support and CLI.
Wires together storage, extraction, signal detection, prompt injection,
and CLI commands for end-to-end memory functionality.

This is a thin entry point that delegates to submodules:
- core: State management and lifecycle callbacks
- messaging: Message extraction and normalization
- processing: Signal confidence updates and fact extraction
- prompts: Memory formatting and prompt injection
- agent_run_end: Agent run completion callback
- commands: CLI command handlers

Callbacks registered:
- startup: Initialize the memory system (with config-based opt-in)
- shutdown: Flush pending writes
- agent_run_end: Extract facts from conversations, apply signal confidence updates
- get_model_system_prompt: Inject relevant memories into system prompts
- custom_command: Handle /memory show/clear/export/help commands
- custom_command_help: Add /memory to help listing

Config keys (puppy.cfg):
    enable_agent_memory = false         # OPT-IN, default off
    memory_debounce_seconds = 30        # Write debounce window
    memory_max_facts = 50               # Max facts per agent
    memory_token_budget = 500           # Token budget for injection
    memory_extraction_model = ""         # Optional model override
"""

# Re-export functions for backward compatibility (tests import these directly)
# Import callback registration for prompts
from code_puppy.callbacks import register_callback

from .agent_run_end import (
    register_agent_run_end_callback,
)
from .commands import (
    register_command_callbacks,
)
from .core import (
    register_core_callbacks,
)
from .prompts import (
    _on_load_prompt,
)

# Register all callbacks (idempotent due to callback deduplication)
register_core_callbacks()
register_agent_run_end_callback()
register_command_callbacks()

# Register prompt callback directly
register_callback("get_model_system_prompt", _on_load_prompt)
