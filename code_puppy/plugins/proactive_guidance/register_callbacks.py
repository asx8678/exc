"""Proactive Guidance Plugin - Next-step suggestions after tool execution.

This plugin provides contextual guidance and follow-up suggestions after
tools like write_file, run_shell_command, and invoke_agent are executed.

Configuration (puppy.cfg):
    [default]
    proactive_guidance_enabled = true  # Enable/disable the plugin
    guidance_verbosity = normal      # minimal|normal|verbose

Hooks:
    - post_tool_call: Injects next-step guidance after tool execution
    - custom_command: Provides /guidance command for status/toggle
    - agent_run_start: Surfaces task context when agents begin
"""

from __future__ import annotations

import asyncio
import logging
import os
import subprocess
from typing import Any

from code_puppy.callbacks import register_callback
from code_puppy.plugins.proactive_guidance._guidance import (  # noqa: F401
    _get_agent_guidance,
    _get_exploratory_guidance,
    _get_shell_guidance,
    _get_write_guidance,
)

logger = logging.getLogger(__name__)

# --------------------------------------------------------------------------
# Config helpers (lazy-imported to avoid cycles at plugin load time)
# --------------------------------------------------------------------------

_CONFIG_KEY_ENABLED = "proactive_guidance_enabled"
_CONFIG_KEY_VERBOSITY = "guidance_verbosity"
_VALID_VERBOSITY = {"minimal", "normal", "verbose"}

# Track state
_state: dict[str, Any] = {
    "enabled": True,
    "verbosity": "normal",
    "last_tool": None,
    "guidance_count": 0,
    "last_agent": None,
    "last_agent_model": None,
}


def _get_config_enabled() -> bool:
    """Read the enabled state from puppy.cfg; default to True."""
    try:
        from code_puppy.config import get_value

        raw = get_value(_CONFIG_KEY_ENABLED)
        if raw is not None:
            return raw.strip().lower() in ("true", "1", "yes", "on")
    except Exception as exc:
        logger.debug("proactive_guidance: config read error: %s", exc)
    return True


def _get_config_verbosity() -> str:
    """Read verbosity from puppy.cfg; default to 'normal'."""
    try:
        from code_puppy.config import get_value

        raw = get_value(_CONFIG_KEY_VERBOSITY)
        if raw and raw.strip().lower() in _VALID_VERBOSITY:
            return raw.strip().lower()
    except Exception as exc:
        logger.debug("proactive_guidance: config read error: %s", exc)
    return "normal"


def _is_enabled() -> bool:
    """Check if guidance is enabled (config + runtime state)."""
    return _state["enabled"] and _get_config_enabled()


# --------------------------------------------------------------------------
# Task-context helpers (fail gracefully, never crash)
# --------------------------------------------------------------------------


def _get_git_branch() -> str | None:
    """Best-effort git branch detection."""
    try:
        result = subprocess.run(
            ["git", "branch", "--show-current"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip() or None
    except Exception as exc:
        logger.debug("proactive_guidance: git branch detection failed: %s", exc)
    return None


def _get_git_head_short() -> str | None:
    """Best-effort short HEAD hash."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip() or None
    except Exception as exc:
        logger.debug("proactive_guidance: git rev-parse failed: %s", exc)
    return None


def _detect_task_context() -> dict[str, Any]:
    """Gather real context from env/session/git — fail gracefully.

    Returns a dict with whatever context was obtainable.
    """
    ctx: dict[str, Any] = {}

    # Git context
    branch = _get_git_branch()
    if branch:
        ctx["git_branch"] = branch
    head = _get_git_head_short()
    if head:
        ctx["git_head"] = head

    # Environment context
    ctx["cwd"] = os.getcwd()
    ctx["user"] = os.environ.get("USER", "unknown")

    # Task ID from env vars
    task_id = os.environ.get("PUP_TASK_ID") or os.environ.get("PUPPY_TASK_ID")
    if task_id:
        ctx["task_id"] = task_id

    return ctx


def _format_task_context(ctx: dict[str, Any]) -> str:
    """Format task context dict into a human-readable summary."""
    parts: list[str] = ["📋 Task Context"]

    if "task_id" in ctx:
        parts.append(f"   Task: {ctx['task_id']}")
    if "git_branch" in ctx:
        parts.append(f"   Branch: {ctx['git_branch']}")
    if "git_head" in ctx:
        parts.append(f"   Commit: {ctx['git_head']}")
    if "cwd" in ctx:
        parts.append(f"   CWD: {ctx['cwd']}")

    if len(parts) == 1:
        return ""  # No useful context gathered
    return "\n".join(parts)


# --------------------------------------------------------------------------
# Post-tool call hook
# --------------------------------------------------------------------------


async def _on_post_tool_call(
    tool_name: str,
    tool_args: dict,
    result: Any,
    duration_ms: float,
    context: Any = None,
) -> None:
    """Inject next-step guidance after tool execution.

    Args:
        tool_name: Name of the tool that was called
        tool_args: Arguments passed to the tool
        result: The result returned by the tool
        duration_ms: Execution time in milliseconds
        context: Optional context data for the tool call
    """
    if not _is_enabled():
        return

    try:
        from code_puppy.messaging import emit_info

        guidance: str | None = None

        if tool_name == "create_file":
            file_path = tool_args.get("file_path", "")
            content = tool_args.get("content", "")
            guidance = _get_write_guidance(
                file_path, content[:200] if content else None
            )
        elif tool_name == "replace_in_file":
            file_path = tool_args.get("file_path", "")
            guidance = _get_write_guidance(file_path, "replacement")
        elif tool_name == "agent_run_shell_command":
            command = tool_args.get("command", "")
            # Try to extract exit code from result
            exit_code = 0
            if isinstance(result, dict):
                exit_code = result.get("exit_code", 0)
            guidance = _get_shell_guidance(command, exit_code)
        elif tool_name == "invoke_agent":
            agent_name = tool_args.get("agent_name", "unknown")
            guidance = _get_agent_guidance(agent_name)
        elif tool_name in ("read_file", "grep", "list_files"):
            guidance = _get_exploratory_guidance(tool_name, tool_args)

        if guidance:
            emit_info(f"\n{guidance}")
            _state["guidance_count"] += 1
            _state["last_tool"] = tool_name

    except Exception as exc:
        # Never crash the app because of guidance
        logger.debug("proactive_guidance: error in post_tool_call: %s", exc)


# --------------------------------------------------------------------------
# Agent run start hook — surface task context
# --------------------------------------------------------------------------


async def _on_agent_run_start(
    agent_name: str,
    model_name: str,
    session_id: str | None = None,
    **kwargs: Any,
) -> None:
    """Surface task context when an agent starts a run."""
    if not _is_enabled():
        return

    _state["last_agent"] = agent_name
    _state["last_agent_model"] = model_name

    try:
        ctx = await asyncio.to_thread(_detect_task_context)
        summary = _format_task_context(ctx)
        if not summary:
            return

        from code_puppy.messaging import emit_info

        emit_info(f"\n{summary}")
    except Exception as exc:
        logger.debug("proactive_guidance: error in agent_run_start: %s", exc)


# --------------------------------------------------------------------------
# Slash command UX: /guidance status | on | off | test
# --------------------------------------------------------------------------


def _on_custom_help() -> list[tuple[str, str]]:
    return [
        ("/guidance", "Manage proactive guidance (status|on|off|test)"),
        ("/guidance verbosity minimal|normal|verbose", "Set guidance detail level"),
    ]


def _handle_custom_command(command: str, name: str) -> bool | str | None:
    if name != "guidance":
        return None  # Not ours — pass through.

    try:
        from code_puppy.messaging import emit_info
    except Exception as exc:
        logger.debug("proactive_guidance: emit_info unavailable: %s", exc)
        return True  # Can't emit — bail.

    parts = command.strip().split(maxsplit=2)
    sub = parts[1].strip().lower() if len(parts) >= 2 else "status"

    if sub == "status":
        config_enabled = _get_config_enabled()
        runtime_enabled = _state["enabled"]
        verbosity = _state["verbosity"]
        count = _state["guidance_count"]
        status_text = "enabled" if (config_enabled and runtime_enabled) else "disabled"

        msg = (
            f"🐾 Proactive Guidance: {status_text}\n"
            f"   Config enabled: {config_enabled}\n"
            f"   Runtime enabled: {runtime_enabled}\n"
            f"   Verbosity: {verbosity}\n"
            f"   Guidance shown: {count}\n"
            f"\nSet in puppy.cfg: proactive_guidance_enabled = true"
        )
        emit_info(msg)
        return True

    if sub in ("on", "enable"):
        _state["enabled"] = True
        emit_info("✅ Proactive guidance enabled for this session")
        return True

    if sub in ("off", "disable"):
        _state["enabled"] = False
        emit_info("⏸️ Proactive guidance disabled for this session")
        return True

    if sub == "verbosity" and len(parts) >= 3:
        new_verb = parts[2].strip().lower()
        if new_verb in _VALID_VERBOSITY:
            _state["verbosity"] = new_verb
            emit_info(f"📢 Guidance verbosity set to: {new_verb}")
        else:
            emit_info("❌ Invalid verbosity. Use: minimal, normal, or verbose")
        return True

    if sub == "test":
        # Show sample guidance
        emit_info("🧪 Sample guidance output:\n")
        emit_info(_get_write_guidance("test.py", "def hello(): pass") or "No guidance")
        emit_info("")
        emit_info(_get_shell_guidance("pytest test.py", 0) or "No guidance")
        return True

    if sub == "reset":
        _state["guidance_count"] = 0
        emit_info("🔄 Guidance counter reset")
        return True

    emit_info(
        f"Unknown /guidance subcommand: {sub!r} (try status|on|off|verbosity|test|reset)"
    )
    return True


# --------------------------------------------------------------------------
# Registration — module scope, as required by plugin loader
# --------------------------------------------------------------------------

# Initialize state from config
_state["enabled"] = _get_config_enabled()
_state["verbosity"] = _get_config_verbosity()

# Share state with the guidance submodule so generators can read verbosity
import code_puppy.plugins.proactive_guidance._guidance as _g  # noqa: E402

_g._state = _state

register_callback("post_tool_call", _on_post_tool_call)
register_callback("agent_run_start", _on_agent_run_start)
register_callback("custom_command_help", _on_custom_help)
register_callback("custom_command", _handle_custom_command)
