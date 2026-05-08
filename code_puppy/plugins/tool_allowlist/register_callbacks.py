"""Tool allowlist plugin for config-driven tool restriction.

This plugin provides allowlist/denylist functionality for tools via the
pre_tool_call hook. Configuration is read from puppy.cfg:

    [puppy]
    tool_allowlist = read_file,write_file,grep
    tool_denylist = agent_run_shell_command
    tool_policy_default = allow    # Options: allow, deny, audit (default: allow)

Empty or missing allowlist/denylist means no restrictions (disabled by default).
The tool_policy_default setting controls behavior when both lists are empty:
- 'allow': All tools allowed (default, for backward compatibility)
- 'deny': All tools denied when no allowlist configured (fail-safe mode)
- 'audit': All tools allowed but logged (for monitoring)

Usage:
    The plugin auto-registers on import. To test the registration:

    >>> from code_puppy.plugins.tool_allowlist import register_callbacks
    >>> from code_puppy import callbacks as cb
    >>> assert any(
    ...     getattr(c, "__name__", None) == "_on_pre_tool_call"
    ...     for c in cb.get_callbacks("pre_tool_call")
    ... )
"""

import logging
from typing import Any

from code_puppy.callbacks import register_callback
from code_puppy.config import get_value
from code_puppy.permission_decision import Deny

logger = logging.getLogger(__name__)


def _parse_tool_list(config_value: str | None) -> set[str]:
    """Parse a comma-separated list of tool names from config.

    Args:
        config_value: Raw config value, may be None or comma-separated string.

    Returns:
        Set of normalized (stripped, lowercase) tool names.
    """
    if not config_value:
        return set()

    tools = set()
    for item in config_value.split(","):
        tool_name = item.strip().lower()
        if tool_name:
            tools.add(tool_name)
    return tools


def _get_allowlist() -> set[str]:
    """Get the configured tool allowlist.

    Returns:
        Set of allowed tool names (empty if not configured).
    """
    raw = get_value("tool_allowlist")
    return _parse_tool_list(raw)


def _get_denylist() -> set[str]:
    """Get the configured tool denylist.

    Returns:
        Set of denied tool names (empty if not configured).
    """
    raw = get_value("tool_denylist")
    return _parse_tool_list(raw)


def _get_default_policy() -> str:
    """Get the default policy when no allowlist/denylist configured.

    Returns:
        Policy string: 'allow' (default), 'deny', or 'audit'
    """
    raw = get_value("tool_policy_default")
    if not raw:
        return "allow"
    policy = str(raw).strip().lower()
    if policy in ("deny", "block"):
        return "deny"
    if policy in ("audit", "log"):
        return "audit"
    return "allow"


def _is_tool_allowed(
    tool_name: str,
    allowlist: set[str],
    denylist: set[str],
    default_policy: str = "allow",
) -> bool:
    """Check if a tool is allowed based on allowlist and denylist.

    Priority:
    1. If denylist contains the tool -> DENIED
    2. If allowlist is set and tool not in it -> DENIED
    3. Apply default_policy if no lists configured:
       - 'allow': All tools allowed
       - 'deny': All tools denied
       - 'audit': All tools allowed (but logged separately)
    4. Otherwise -> ALLOWED

    Args:
        tool_name: Name of the tool being called.
        allowlist: Set of allowed tool names (empty means no allowlist restriction).
        denylist: Set of denied tool names.
        default_policy: Policy when no lists configured ('allow', 'deny', 'audit').

    Returns:
        True if tool is allowed, False otherwise.
    """
    normalized_name = tool_name.lower()

    # Check denylist first (highest priority)
    if normalized_name in denylist:
        return False

    # Check allowlist if it's configured
    if allowlist and normalized_name not in allowlist:
        return False

    # If no restrictions configured, apply default policy
    if not allowlist and not denylist:
        if default_policy == "deny":
            return False
        # 'allow' and 'audit' both permit tools

    return True


def _on_pre_tool_call(
    tool_name: str, tool_args: dict[str, Any], context: Any = None
) -> Deny | None:
    """Pre-tool-call callback to enforce allowlist/denylist restrictions.

    Args:
        tool_name: Name of the tool being called.
        tool_args: Arguments being passed to the tool.
        context: Optional context data for the tool call.

    Returns:
        None if the tool is allowed to proceed.
        Deny object if the tool should be denied.
    """
    allowlist = _get_allowlist()
    denylist = _get_denylist()
    default_policy = _get_default_policy()

    # Always audit log the tool call attempt
    _audit_log_tool_call(tool_name, tool_args, context)

    # If no restrictions configured, apply default policy
    if not allowlist and not denylist:
        if default_policy == "deny":
            reason = f"Tool '{tool_name}' blocked by default policy (no allowlist configured)"
            logger.warning("Tool blocked: %s", reason)
            return Deny(
                reason=reason,
                user_feedback=f"🚫 Tool blocked: {reason}",
            )
        # 'allow' and 'audit' policies permit tools when no restrictions configured
        if default_policy == "audit":
            logger.info("Tool audit (allowed): %s", tool_name)
        return None

    if _is_tool_allowed(tool_name, allowlist, denylist, default_policy):
        logger.info("Tool allowed: %s", tool_name)
        return None

    # Tool is blocked - determine reason
    normalized_name = tool_name.lower()
    if normalized_name in denylist:
        reason = f"Tool '{tool_name}' is in the denylist"
    elif allowlist:
        reason = f"Tool '{tool_name}' is not in the allowlist"
    else:
        reason = f"Tool '{tool_name}' is blocked by policy"

    logger.warning("Tool blocked: %s", reason)

    return Deny(
        reason=reason,
        user_feedback=f"🚫 Tool blocked: {reason}",
    )


def _audit_log_tool_call(
    tool_name: str, tool_args: dict[str, Any], context: Any = None
) -> None:
    """Write audit log entry for tool call attempt.

    Logs the tool name and timestamp for security auditing.
    Sensitive arguments are not logged.

    Args:
        tool_name: Name of the tool being called.
        tool_args: Arguments being passed to the tool.
        context: Optional context data for the tool call.
    """
    # Extract non-sensitive context info if available
    agent_name = None
    session_id = None
    if context and isinstance(context, dict):
        agent_name = context.get("agent_name")
        session_id = context.get("session_id")

    # Build audit log message
    audit_parts = [f"tool={tool_name}"]
    if agent_name:
        audit_parts.append(f"agent={agent_name}")
    if session_id:
        audit_parts.append(f"session={session_id}")

    # Log at DEBUG level with structured info
    # Use a child logger for audit events that can be separately configured
    audit_logger = logger.getChild("audit")
    audit_logger.debug(" | ".join(audit_parts))


def register():
    """Register the tool allowlist callback."""
    register_callback("pre_tool_call", _on_pre_tool_call)


# Auto-register on import
register()


__all__ = [
    "_parse_tool_list",
    "_get_allowlist",
    "_get_denylist",
    "_is_tool_allowed",
    "_on_pre_tool_call",
    "register",
]
