"""Compaction module: enhanced summarization utilities.

This module provides four enhancements to code_puppy's existing summarization:
1. Model-aware fraction thresholds (thresholds.py)
2. Tool arg pre-truncation phase (tool_arg_truncation.py)
3. History offload to file (history_offload.py)
4. File operations tracking for context retention (file_ops_tracker.py)
"""

from code_puppy.compaction.file_ops_tracker import (
    FileOpsTracker,
    extract_file_ops_from_messages,
    format_file_ops_xml,
)
from code_puppy.compaction.history_offload import (
    offload_evicted_messages,
)
from code_puppy.compaction.shadow_mode import (
    shadow_hash_messages,
    shadow_prune_and_filter,
)
from code_puppy.compaction.thresholds import (
    SummarizationThresholds,
    compute_summarization_thresholds,
    get_model_context_window,
)
from code_puppy.compaction.tool_arg_truncation import (
    pretruncate_messages,
    truncate_tool_arg,
    truncate_tool_call_args,
    truncate_tool_return_content,
)

__all__ = [
    "compute_summarization_thresholds",
    "extract_file_ops_from_messages",
    "FileOpsTracker",
    "format_file_ops_xml",
    "get_model_context_window",
    "offload_evicted_messages",
    "pretruncate_messages",
    "shadow_hash_messages",
    "shadow_prune_and_filter",
    "SummarizationThresholds",
    "truncate_tool_arg",
    "truncate_tool_call_args",
    "truncate_tool_return_content",
]
