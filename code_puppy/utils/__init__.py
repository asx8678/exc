"""Shared utility modules for Code Puppy.

Inspired by patterns from oh-my-pi (omp) project.
"""

from .agent_helpers import invert_conversation_roles
from .checkpoint import CheckpointStore
from .clipboard import copy_to_clipboard, osc52_copy
from .config_resolve import (
    clear_config_value_cache,
    resolve_config_value,
    resolve_config_value_sync,
    resolve_headers,
    resolve_headers_sync,
)
from .dag import build_dependency_graph, build_execution_waves, detect_cycles
from .emit import emit_error, emit_info, emit_success, emit_warning
from .eol import restore_bom, strip_bom
from .file_display import (
    format_content_with_line_numbers,
    inject_scope_context,
    open_nofollow,
    safe_write_file,
    truncate_with_guidance,
)
from .file_mutex import (
    active_lock_count,
    cross_process_file_lock,
    cross_process_file_lock_sync,
    file_lock,
    file_lock_sync,
)

# New utilities from comparative review (oh-my-pi patterns)
from .fs_errors import (
    get_fs_code,
    has_fs_code,
    is_eacces,
    is_eexist,
    is_eisdir,
    is_enoent,
    is_enospc,
    is_enotdir,
    is_enotempty,
    is_eperm,
    is_erofs,
    is_fs_error,
)
from .install_hints import format_missing_tool_message, install_hint
from .llm_parsing import extract_json_from_text
from .macos_path import resolve_path_with_variants
from .overflow_detect import is_context_overflow, is_rate_limit_error
from .parallel import (
    Bulkhead,
    BulkheadFullError,
    BulkheadStats,
    BulkheadTimeoutError,
    ParallelResult,
    Semaphore,
    map_with_concurrency,
)
from .path_safety import (
    PathSafetyError,
    PathTraversalError,
    UnsafeComponentError,
    safe_join,
    safe_path_component,
    verify_contained,
)
from .peek_file import peek_file, peek_file_sync, reset_pools
from .ring_buffer import RingBuffer
from .shell_split import split_compound_command
from .stream_parser import SSEParser, StreamLineParser, parse_jsonl_lenient
from .thread_safe_cache import thread_safe_cache, thread_safe_lru_cache


def format_duration(seconds: float) -> str:
    """Format a duration into a compact human-friendly string.

    Examples:
        0.25 -> "250ms"
        1.5 -> "1.5s"
        90.5 -> "1m 30.5s"
        3665 -> "1h 1m"
    """
    if seconds < 1:
        return f"{seconds * 1000:.0f}ms"
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, remainder = divmod(seconds, 60)
    if minutes < 60:
        return f"{int(minutes)}m {remainder:.1f}s"
    hours, minutes = divmod(minutes, 60)
    return f"{int(hours)}h {int(minutes)}m"


__all__ = [
    # Duration formatting
    "format_duration",
    "invert_conversation_roles",
    # Emit utilities
    "emit_error",
    "emit_info",
    "emit_success",
    "emit_warning",
    # Existing utilities
    "RingBuffer",
    "map_with_concurrency",
    "Semaphore",
    "ParallelResult",
    "Bulkhead",
    "BulkheadStats",
    "BulkheadFullError",
    "BulkheadTimeoutError",
    # File mutation serialization (ported from pi-mono-main)
    "file_lock",
    "file_lock_sync",
    "active_lock_count",
    # Cross-process file locking (ported from oh-my-pi)
    "cross_process_file_lock",
    "cross_process_file_lock_sync",
    # Context overflow detection (ported from pi-mono-main)
    "is_context_overflow",
    "is_rate_limit_error",
    # macOS path variant resolution (ported from pi-mono-main)
    "resolve_path_with_variants",
    # Clipboard with OSC 52 (ported from pi-mono-main)
    "copy_to_clipboard",
    "osc52_copy",
    # BOM handling (ported from pi-mono-main)
    "strip_bom",
    "restore_bom",
    "build_dependency_graph",
    "detect_cycles",
    "build_execution_waves",
    "split_compound_command",
    "StreamLineParser",
    "SSEParser",
    "parse_jsonl_lenient",
    # LLM parsing utilities
    "extract_json_from_text",
    # File display utilities (ported from deepagents)
    "format_content_with_line_numbers",
    "truncate_with_guidance",
    "open_nofollow",
    "safe_write_file",
    "inject_scope_context",
    # Checkpointing (ported from Agentless skip_existing pattern)
    "CheckpointStore",
    # Install hints (ported from deepagents)
    "install_hint",
    "format_missing_tool_message",
    # Path safety utilities (security)
    "PathSafetyError",
    "PathTraversalError",
    "UnsafeComponentError",
    "safe_path_component",
    "safe_join",
    "verify_contained",
    # FS error type guards (ported from oh-my-pi)
    "is_fs_error",
    "is_enoent",
    "is_eacces",
    "is_eisdir",
    "is_enotdir",
    "is_eexist",
    "is_enotempty",
    "is_eperm",
    "is_enospc",
    "is_erofs",
    "has_fs_code",
    "get_fs_code",
    # Config value resolution (ported from oh-my-pi)
    "resolve_config_value",
    "resolve_config_value_sync",
    "resolve_headers",
    "resolve_headers_sync",
    "clear_config_value_cache",
    # Buffer-pooled file peeking (ported from oh-my-pi)
    "peek_file_sync",
    "peek_file",
    "reset_pools",
    # Thread-safe cache decorators (for Python 3.14t free-threading)
    "thread_safe_lru_cache",
    "thread_safe_cache",
]
