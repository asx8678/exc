"""Agent Memory plugin — persists agent knowledge across sessions.

This plugin provides the foundation for the agent memory system,
allowing agents to store and recall facts learned during conversations.

Phase 1: Storage layer
- File-based per-agent storage
- Thread-safe CRUD operations
- Graceful corruption handling

Phase 2: Debounced batch updater
- Batched writes with configurable debounce window
- Automatic deduplication by fact text
- Immediate operations for reinforce/remove (bypass debounce)
- Graceful flush on shutdown

Phase 4: Signal detection
- Correction/reinforcement/preference pattern detection
- Regex-based analysis of user messages
- Configurable confidence deltas per signal type

Phase 5: Full plugin integration
- Callback-based fact extraction on agent_run_end
- Signal-based confidence updates
- Memory injection into system prompts via get_model_system_prompt
- Non-blocking async extraction with debounced storage

Phase 6: Configuration and CLI
- Config-based opt-in activation
- /memory slash command with subcommands
- Rich formatted memory display
- JSON export for transparency
"""

from .config import MemoryConfig, get_config, is_memory_enabled, load_config
from .extraction import (
    DEFAULT_EXTRACTION_PROMPT,
    ExtractedFact,
    FactExtractor,
    MockLLMClient,
)
from .signal_safeguards import (
    DEFAULT_DECAY_HOURS,
    DEFAULT_MAX_PREFERENCE_SIGNALS,
    DEFAULT_RATE_LIMIT_SECONDS,
    SafeguardManager,
    SignalApplication,
    SignalTracker,
    get_safeguard_manager,
)
from .signals import (
    CORRECTION_DELTA,
    PREFERENCE_DELTA,
    REINFORCEMENT_DELTA,
    Signal,
    SignalDetector,
    SignalType,
    detect_signals,
    has_correction,
    has_preference,
    has_reinforcement,
)
from .storage import Fact, FileMemoryStorage
from .updater import DEFAULT_DEBOUNCE_MS, MemoryUpdater

__all__ = [
    # Core components
    "DEFAULT_DEBOUNCE_MS",
    "DEFAULT_EXTRACTION_PROMPT",
    "ExtractedFact",
    "Fact",
    "FactExtractor",
    "FileMemoryStorage",
    "MemoryConfig",
    "MemoryUpdater",
    "MockLLMClient",
    # Signal components
    "CORRECTION_DELTA",
    "PREFERENCE_DELTA",
    "REINFORCEMENT_DELTA",
    "Signal",
    "SignalDetector",
    "SignalType",
    "detect_signals",
    "has_correction",
    "has_preference",
    "has_reinforcement",
    # Signal safeguards (code-puppy-eed)
    "DEFAULT_DECAY_HOURS",
    "DEFAULT_MAX_PREFERENCE_SIGNALS",
    "DEFAULT_RATE_LIMIT_SECONDS",
    "SafeguardManager",
    "SignalApplication",
    "SignalTracker",
    "get_safeguard_manager",
    # Config
    "load_config",
    "get_config",
    "is_memory_enabled",
]
