"""Centralized resource and context-size limit constants.

Adopted from plandex's ``shared/context.go`` named-constants pattern.
Centralising limits here prevents magic numbers from scattering across
file tools, compaction, and context management code.

All values are conservative defaults designed to prevent resource
exhaustion while remaining generous enough for real-world projects.
Override individual limits via ``~/.code_puppy/puppy.cfg`` where noted.
"""

__all__ = [
    # File / context size limits
    "MAX_CONTEXT_BODY_BYTES",
    "MAX_CONTEXT_COUNT",
    "MAX_CONTEXT_MAP_PATHS",
    "MAX_CONTEXT_MAP_SINGLE_INPUT_BYTES",
    "MAX_CONTEXT_MAP_TOTAL_INPUT_BYTES",
    "MAX_TOTAL_CONTEXT_BYTES",
    "CONTEXT_MAP_MAX_BATCH_BYTES",
    "CONTEXT_MAP_MAX_BATCH_SIZE",
    # Token limits
    "MAX_READ_FILE_TOKENS",
    "MAX_GREP_MATCHES",
    "MAX_GREP_FILE_SIZE_BYTES",
    # Summarization defaults
    "SUMMARIZATION_TRIGGER_FRACTION_DEFAULT",
    "SUMMARIZATION_KEEP_FRACTION_DEFAULT",
    "SUMMARIZATION_ABSOLUTE_TRIGGER_DEFAULT",
    "SUMMARIZATION_ABSOLUTE_PROTECTED_DEFAULT",
    "SUMMARIZATION_MIN_TRIGGER_TOKENS",
    "SUMMARIZATION_MIN_KEEP_TOKENS",
    # Display limits
    "MAX_DIFF_CONTEXT_LINES_DEFAULT",
]

# ---------------------------------------------------------------------------
# File / context size limits  (mirroring plandex shared/context.go)
# ---------------------------------------------------------------------------

#: Maximum size of a single context body in bytes (25 MB).
MAX_CONTEXT_BODY_BYTES: int = 25 * 1024 * 1024

#: Maximum number of context items that can be loaded simultaneously.
MAX_CONTEXT_COUNT: int = 1_000

#: Maximum number of file-map paths tracked at once.
MAX_CONTEXT_MAP_PATHS: int = 3_000

#: Maximum size of a single file-map input (500 KB).
MAX_CONTEXT_MAP_SINGLE_INPUT_BYTES: int = 500 * 1024

#: Maximum total size of all file-map inputs combined (250 MB).
MAX_CONTEXT_MAP_TOTAL_INPUT_BYTES: int = 250 * 1024 * 1024

#: Hard ceiling on total context size across all items (1 GB).
MAX_TOTAL_CONTEXT_BYTES: int = 1 * 1024 * 1024 * 1024

#: Maximum size of a single file-map batch request (10 MB).
CONTEXT_MAP_MAX_BATCH_BYTES: int = 10 * 1024 * 1024

#: Maximum number of files in a single file-map batch.
CONTEXT_MAP_MAX_BATCH_SIZE: int = 500

# ---------------------------------------------------------------------------
# Token / tool limits
# ---------------------------------------------------------------------------

#: Token threshold above which _read_file refuses to return full content.
#: The tool prompts the user to read in chunks instead.
#: Configurable via ``max_read_file_tokens`` in puppy.cfg.
MAX_READ_FILE_TOKENS: int = 10_000

#: Maximum number of matches returned by a single grep invocation.
MAX_GREP_MATCHES: int = 50

#: Maximum file size (in bytes) that grep will search (5 MB).
MAX_GREP_FILE_SIZE_BYTES: int = 5 * 1024 * 1024

# ---------------------------------------------------------------------------
# Summarization defaults
# ---------------------------------------------------------------------------

#: Default fraction of context window that triggers summarization (85%).
SUMMARIZATION_TRIGGER_FRACTION_DEFAULT: float = 0.85

#: Default fraction of context window to preserve as recent messages (10%).
SUMMARIZATION_KEEP_FRACTION_DEFAULT: float = 0.10

#: Default absolute trigger threshold when model context is unknown.
SUMMARIZATION_ABSOLUTE_TRIGGER_DEFAULT: int = 170_000

#: Default absolute protected count when model context is unknown.
SUMMARIZATION_ABSOLUTE_PROTECTED_DEFAULT: int = 50_000

#: Minimum trigger threshold floor (never summarize below this).
SUMMARIZATION_MIN_TRIGGER_TOKENS: int = 1_000

#: Minimum keep threshold floor (never preserve less than this).
SUMMARIZATION_MIN_KEEP_TOKENS: int = 100

# ---------------------------------------------------------------------------
# Display defaults
# ---------------------------------------------------------------------------

#: Default number of context lines shown around diffs.
MAX_DIFF_CONTEXT_LINES_DEFAULT: int = 3
