"""Structured conversation and workflow flags.

This module tracks actions taken during a run, providing a snapshot of workflow
state that can be used by callbacks, session management, and UI rendering.

Workflow Flags:
- did_generate_code: Code was generated/created
- did_execute_shell: Shell command was executed
- did_load_context: Context/files were loaded
- did_create_plan: A plan was created
- did_encounter_error: An error occurred
- needs_user_confirmation: User confirmation is pending
- did_save_session: Session was saved
- did_use_fallback_model: A fallback model was used
- did_trigger_compaction: Context compaction occurred

Usage:
    from code_puppy.workflow_state import get_workflow_state, set_flag

    # Check if code was generated
    if get_workflow_state().did_generate_code:
        # Do something post-code-generation

    # Set a flag
    set_flag("did_create_plan")
"""

import contextvars
import logging
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Any

logger = logging.getLogger(__name__)


class WorkflowFlag(Enum):
    """Enumeration of all workflow flags."""

    DID_GENERATE_CODE = auto()
    DID_EXECUTE_SHELL = auto()
    DID_LOAD_CONTEXT = auto()
    DID_CREATE_PLAN = auto()
    DID_ENCOUNTER_ERROR = auto()
    NEEDS_USER_CONFIRMATION = auto()
    DID_SAVE_SESSION = auto()
    DID_USE_FALLBACK_MODEL = auto()
    DID_TRIGGER_COMPACTION = auto()
    DID_MAKE_API_CALL = auto()
    DID_EDIT_FILE = auto()
    DID_CREATE_FILE = auto()
    DID_DELETE_FILE = auto()
    DID_RUN_TESTS = auto()
    DID_CHECK_LINT = auto()


@dataclass
class WorkflowState:
    """Tracks workflow state for a single agent run or session.

    Attributes:
        flags: Set of active workflow flags
        metadata: Additional context data (timestamps, counts, etc.)
        start_time: Unix timestamp when state was created
    """

    flags: set[WorkflowFlag] = field(default_factory=set)
    metadata: dict[str, Any] = field(default_factory=dict)
    start_time: float = field(default_factory=lambda: __import__("time").time())

    # Flag properties for easy access
    @property
    def did_generate_code(self) -> bool:
        """Code was generated or modified."""
        return WorkflowFlag.DID_GENERATE_CODE in self.flags

    @property
    def did_execute_shell(self) -> bool:
        """Shell command was executed."""
        return WorkflowFlag.DID_EXECUTE_SHELL in self.flags

    @property
    def did_load_context(self) -> bool:
        """Context or files were loaded."""
        return WorkflowFlag.DID_LOAD_CONTEXT in self.flags

    @property
    def did_create_plan(self) -> bool:
        """A plan was created."""
        return WorkflowFlag.DID_CREATE_PLAN in self.flags

    @property
    def did_encounter_error(self) -> bool:
        """An error occurred during execution."""
        return WorkflowFlag.DID_ENCOUNTER_ERROR in self.flags

    @property
    def needs_user_confirmation(self) -> bool:
        """User confirmation is pending."""
        return WorkflowFlag.NEEDS_USER_CONFIRMATION in self.flags

    @property
    def did_save_session(self) -> bool:
        """Session was saved."""
        return WorkflowFlag.DID_SAVE_SESSION in self.flags

    @property
    def did_use_fallback_model(self) -> bool:
        """A fallback model was used."""
        return WorkflowFlag.DID_USE_FALLBACK_MODEL in self.flags

    @property
    def did_trigger_compaction(self) -> bool:
        """Context compaction occurred."""
        return WorkflowFlag.DID_TRIGGER_COMPACTION in self.flags

    @property
    def did_make_api_call(self) -> bool:
        """API call was made to a model."""
        return WorkflowFlag.DID_MAKE_API_CALL in self.flags

    @property
    def did_edit_file(self) -> bool:
        """A file was edited."""
        return WorkflowFlag.DID_EDIT_FILE in self.flags

    @property
    def did_create_file(self) -> bool:
        """A file was created."""
        return WorkflowFlag.DID_CREATE_FILE in self.flags

    @property
    def did_delete_file(self) -> bool:
        """A file was deleted."""
        return WorkflowFlag.DID_DELETE_FILE in self.flags

    @property
    def did_run_tests(self) -> bool:
        """Tests were run."""
        return WorkflowFlag.DID_RUN_TESTS in self.flags

    @property
    def did_check_lint(self) -> bool:
        """Linting was performed."""
        return WorkflowFlag.DID_CHECK_LINT in self.flags

    def to_dict(self) -> dict[str, Any]:
        """Convert state to dictionary for serialization."""
        return {
            "flags": [f.name for f in self.flags],
            "metadata": self.metadata,
            "start_time": self.start_time,
            "summary": self.summary(),
        }

    def summary(self) -> str:
        """Generate a human-readable summary of workflow state."""
        active = [f.name.replace("_", " ").title() for f in self.flags]
        if not active:
            return "No actions recorded"
        return ", ".join(sorted(active))


# Context-local storage for per-run workflow state
# ContextVar properly propagates across async tasks, unlike threading.local
_current_state: contextvars.ContextVar[WorkflowState | None] = contextvars.ContextVar(
    "workflow_state", default=None
)


def get_workflow_state() -> WorkflowState:
    """Get the current context's workflow state.

    Returns:
        WorkflowState for the current async context, creating one if needed.
    """
    state = _current_state.get()
    if state is None:
        state = WorkflowState()
        _current_state.set(state)
    return state


def reset_workflow_state() -> WorkflowState:
    """Reset and return a fresh workflow state.

    Returns:
        New WorkflowState instance.
    """
    state = WorkflowState()
    _current_state.set(state)
    return state


def set_flag(flag: WorkflowFlag | str, value: bool = True) -> None:
    """Set a workflow flag.

    Args:
        flag: Flag to set (WorkflowFlag enum or string name)
        value: True to set, False to clear
    """
    state = get_workflow_state()

    # Convert string to enum if needed
    if isinstance(flag, str):
        try:
            flag = WorkflowFlag[flag.upper()]
        except KeyError:
            logger.warning(f"Unknown workflow flag: {flag}")
            return

    if value:
        state.flags.add(flag)
    else:
        state.flags.discard(flag)

    logger.debug(f"Workflow flag {flag.name} = {value}")


def clear_flag(flag: WorkflowFlag | str) -> None:
    """Clear a workflow flag.

    Args:
        flag: Flag to clear (WorkflowFlag enum or string name)
    """
    set_flag(flag, False)


def has_flag(flag: WorkflowFlag | str) -> bool:
    """Check if a flag is set.

    Args:
        flag: Flag to check (WorkflowFlag enum or string name)

    Returns:
        True if flag is set, False otherwise
    """
    state = get_workflow_state()

    if isinstance(flag, str):
        try:
            flag = WorkflowFlag[flag.upper()]
        except KeyError:
            return False

    return flag in state.flags


def set_metadata(key: str, value: Any) -> None:
    """Store metadata in the workflow state.

    Args:
        key: Metadata key
        value: Metadata value (must be JSON serializable)
    """
    state = get_workflow_state()
    state.metadata[key] = value


def get_metadata(key: str, default: Any = None) -> Any:
    """Get metadata from the workflow state.

    Args:
        key: Metadata key
        default: Default value if key not found

    Returns:
        Metadata value or default
    """
    state = get_workflow_state()
    return state.metadata.get(key, default)


def increment_counter(key: str, amount: int = 1) -> int:
    """Increment a counter in metadata.

    Args:
        key: Counter key
        amount: Amount to increment (default 1)

    Returns:
        New counter value
    """
    state = get_workflow_state()
    current = state.metadata.get(key, 0)
    new_value = current + amount
    state.metadata[key] = new_value
    return new_value


# =============================================================================
# Callback Integration Functions
# =============================================================================


# Callback handler functions (defined at module level so they can be unregistered)
def _on_delete_file(*args, **kwargs):
    set_flag(WorkflowFlag.DID_DELETE_FILE)


def _on_run_shell_command(context, command, cwd=None, timeout=60):
    set_flag(WorkflowFlag.DID_EXECUTE_SHELL)
    # Track specific tool usage
    if "test" in command.lower() or "pytest" in command.lower():
        set_flag(WorkflowFlag.DID_RUN_TESTS)
    if any(x in command.lower() for x in ["lint", "flake8", "pylint", "ruff"]):
        set_flag(WorkflowFlag.DID_CHECK_LINT)


def _on_agent_run_start(*args, **kwargs):
    reset_workflow_state()
    set_metadata("agent_name", kwargs.get("agent_name", "unknown"))
    set_metadata("model_name", kwargs.get("model_name", "unknown"))


def _on_agent_run_end(*args, **kwargs):
    success = kwargs.get("success", False)
    if not success:
        set_flag(WorkflowFlag.DID_ENCOUNTER_ERROR)
    set_metadata("end_time", __import__("time").time())
    set_metadata("success", success)


def _on_pre_tool_call(tool_name, tool_args, context=None):
    # Track context loading
    if tool_name in ["read_file", "list_files", "grep", "search_files"]:
        set_flag(WorkflowFlag.DID_LOAD_CONTEXT)
    # Track shell execution
    if tool_name == "agent_run_shell_command":
        set_flag(WorkflowFlag.DID_EXECUTE_SHELL)
    # Track file creation (create_file tool)
    if tool_name == "create_file":
        set_flag(WorkflowFlag.DID_CREATE_FILE)
        set_flag(WorkflowFlag.DID_GENERATE_CODE)
    # Track file editing (replace_in_file, delete_snippet, and legacy edit_file)
    if tool_name in ("replace_in_file", "delete_snippet", "edit_file"):
        set_flag(WorkflowFlag.DID_EDIT_FILE)
        set_flag(WorkflowFlag.DID_GENERATE_CODE)


def register_callback_handlers():
    """Register handlers for existing callbacks to auto-set flags.

    Call this function to enable automatic flag tracking via callbacks.
    """
    from code_puppy import callbacks

    # File operations (delete_file hook fires; create_file/replace_in_file
    # set their flags via pre_tool_call below)
    callbacks.register_callback("delete_file", _on_delete_file)

    # Shell commands
    callbacks.register_callback("run_shell_command", _on_run_shell_command)

    # Agent run lifecycle
    callbacks.register_callback("agent_run_start", _on_agent_run_start)
    callbacks.register_callback("agent_run_end", _on_agent_run_end)

    # Tool calls (catch-all for API calls)
    callbacks.register_callback("pre_tool_call", _on_pre_tool_call)

    logger.debug("Workflow state callback handlers registered")


def unregister_callback_handlers():
    """Unregister all workflow state callback handlers."""
    from code_puppy import callbacks

    callbacks.unregister_callback("delete_file", _on_delete_file)
    callbacks.unregister_callback("run_shell_command", _on_run_shell_command)
    callbacks.unregister_callback("agent_run_start", _on_agent_run_start)
    callbacks.unregister_callback("agent_run_end", _on_agent_run_end)
    callbacks.unregister_callback("pre_tool_call", _on_pre_tool_call)

    logger.debug("Workflow state callback handlers unregistered")


def detect_and_mark_plan_from_response(response_text: str, min_tasks: int = 2) -> bool:
    """Parse the given response; if it contains a plan, flip DID_CREATE_PLAN.

    Returns True iff DID_CREATE_PLAN was set as a result of this call.
    Helper provided; auto-wiring intentionally deferred to a future ticket.
    """
    from code_puppy.utils.subtask_parser import has_plan

    if has_plan(response_text, min_tasks=min_tasks):
        set_flag(WorkflowFlag.DID_CREATE_PLAN, True)
        return True
    return False
