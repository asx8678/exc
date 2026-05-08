"""SecurityBoundary - Centralized security enforcement for code_puppy.

This module provides a SecurityBoundary class that centralizes security enforcement
instead of relying solely on plugins for command/path/model/server trust decisions.

The SecurityBoundary:
1. Integrates with the existing callback system (run_shell_command, file_permission hooks)
2. Provides a central place to enforce security policies
3. Coordinates between PolicyEngine rules and plugin-based security checks
4. Provides a consistent interface for security decisions across the codebase

Usage:
    from code_puppy.security import get_security_boundary

    security = get_security_boundary()

    # Check shell command
    if security.check_shell_command("rm -rf /", cwd="/home/user"):
        print("Command allowed")
    else:
        print("Command blocked")

    # Check file access
    if security.check_file_access("/etc/passwd", "read"):
        print("Access allowed")
    else:
        print("Access denied")

This is part of an epic to move security enforcement into the core (code_puppy-vdfn).
"""

import logging
import threading
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)


@dataclass
class SecurityDecision:
    """Represents a security decision with reasoning.

    Attributes:
        allowed: Whether the operation is allowed
        reason: Human-readable explanation for the decision
        metadata: Optional additional context about the decision
    """

    allowed: bool
    reason: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def __bool__(self) -> bool:
        """Allow using SecurityDecision in boolean contexts."""
        return self.allowed


class SecurityBoundary:
    """Centralized security enforcement for shell commands and file operations.

    The SecurityBoundary provides a unified interface for security checks that:
    1. Consults the PolicyEngine for explicit rules
    2. Triggers plugin callbacks for additional validation
    3. Enforces yolo_mode and sensitive path protections
    4. Provides consistent logging and decision tracking

    This class is designed to be used as a singleton via get_security_boundary().
    """

    def __init__(self):
        self._stats_lock = threading.Lock()
        self._check_count = 0
        self._block_count = 0

    async def check_shell_command(
        self,
        command: str,
        cwd: str | None = None,
        timeout: int = 60,
        context: Any = None,
    ) -> SecurityDecision:
        """Check if a shell command is allowed to execute.

        This method:
        1. Consults the PolicyEngine for explicit allow/deny rules
        2. Triggers run_shell_command callbacks for plugin validation
        3. Returns a SecurityDecision with reasoning

        Args:
            command: The shell command to check
            cwd: Optional working directory for the command
            timeout: Command timeout (passed to callbacks)
            context: Optional execution context

        Returns:
            SecurityDecision: allowed=True if command can proceed, False otherwise
        """
        with self._stats_lock:
            self._check_count += 1

        if not command or not command.strip():
            return SecurityDecision(
                allowed=False,
                reason="Command cannot be empty",
            )

        # --- PolicyEngine fast-path ----------------------------------------
        # Check explicit policy rules before triggering callbacks
        try:
            from code_puppy.permission_decision import Allow, Deny
            from code_puppy.policy_engine import get_policy_engine

            engine = get_policy_engine()
            policy_result = engine.check_shell_command_explicit(command, cwd)

            if isinstance(policy_result, Deny):
                with self._stats_lock:
                    self._block_count += 1
                logger.info(f"Command blocked by PolicyEngine: {command[:50]}...")
                return SecurityDecision(
                    allowed=False,
                    reason=f"Blocked by policy: {policy_result.reason}",
                    metadata={
                        "blocked_by": "policy_engine",
                        "reason": policy_result.reason,
                    },
                )

            if isinstance(policy_result, Allow):
                logger.debug(f"Command allowed by PolicyEngine: {command[:50]}...")
                return SecurityDecision(
                    allowed=True,
                    reason=f"Allowed by policy: {policy_result.reason}",
                    metadata={"allowed_by": "policy_engine"},
                )
            # AskUser - fall through to callback checks
        except Exception as e:
            logger.warning(f"PolicyEngine check failed: {e}, falling back to callbacks")

        # --- Plugin callback checks ------------------------------------------
        # Trigger run_shell_command callbacks for plugin validation
        from code_puppy.callbacks import on_run_shell_command

        callback_results = await on_run_shell_command(context, command, cwd, timeout)

        # Check if any callback blocked the command
        for result in callback_results:
            if isinstance(result, dict) and result.get("blocked"):
                with self._stats_lock:
                    self._block_count += 1
                reason = result.get("reasoning") or result.get(
                    "error_message", "Blocked by security plugin"
                )
                logger.info(f"Command blocked by plugin: {command[:50]}...")
                return SecurityDecision(
                    allowed=False,
                    reason=reason,
                    metadata={
                        "blocked_by": "plugin",
                        "plugin_result": result,
                    },
                )

        # Command passed all checks
        logger.debug(f"Command allowed after security checks: {command[:50]}...")
        return SecurityDecision(
            allowed=True,
            reason="Passed all security checks",
        )

    def check_file_access(
        self,
        path: str,
        operation: str,
        context: Any = None,
        preview: str | None = None,
        message_group: str | None = None,
        operation_data: Any = None,
    ) -> SecurityDecision:
        """Check if file access is allowed.

        This method:
        1. Checks for sensitive paths (even in yolo_mode)
        2. Consults the PolicyEngine for explicit rules
        3. Triggers file_permission callbacks for plugin validation
        4. Returns a SecurityDecision with reasoning

        Args:
            path: Path to the file being accessed
            operation: Description of the operation (e.g., "read", "write", "delete")
            context: Optional execution context
            preview: Optional preview of changes
            message_group: Optional message group for organizing output
            operation_data: Operation-specific data for preview generation

        Returns:
            SecurityDecision: allowed=True if access can proceed, False otherwise
        """
        with self._stats_lock:
            self._check_count += 1

        if not path:
            return SecurityDecision(
                allowed=False,
                reason="Path cannot be empty",
            )

        # --- Sensitive path check --------------------------------------------
        # Even in yolo_mode, protect sensitive paths
        try:
            from code_puppy.tools.file_operations import _is_sensitive_path

            if _is_sensitive_path(path):
                with self._stats_lock:
                    self._block_count += 1
                logger.warning(f"Access to sensitive path blocked: {path}")
                return SecurityDecision(
                    allowed=False,
                    reason="Access to sensitive paths (SSH keys, credentials) is never allowed",
                    metadata={"blocked_by": "sensitive_path_check"},
                )
        except Exception as e:
            logger.warning(f"Sensitive path check failed: {e}")

        # --- PolicyEngine check ------------------------------------------------
        try:
            from code_puppy.permission_decision import Allow, Deny
            from code_puppy.policy_engine import get_policy_engine

            engine = get_policy_engine()
            policy_result = engine.check_explicit(
                "file_permission",
                {"file_path": path, "operation": operation},
            )

            if isinstance(policy_result, Deny):
                with self._stats_lock:
                    self._block_count += 1
                logger.info(f"File access blocked by PolicyEngine: {path}")
                return SecurityDecision(
                    allowed=False,
                    reason=f"Blocked by policy: {policy_result.reason}",
                    metadata={"blocked_by": "policy_engine"},
                )

            if isinstance(policy_result, Allow):
                logger.debug(f"File access allowed by PolicyEngine: {path}")
                return SecurityDecision(
                    allowed=True,
                    reason=f"Allowed by policy: {policy_result.reason}",
                    metadata={"allowed_by": "policy_engine"},
                )
            # AskUser - fall through to callback checks
        except Exception as e:
            logger.warning(f"PolicyEngine check failed: {e}, falling back to callbacks")

        # --- Plugin callback checks --------------------------------------------
        # Trigger file_permission callbacks for plugin validation
        from code_puppy.callbacks import on_file_permission

        callback_results = on_file_permission(
            context,
            path,
            operation,
            preview,
            message_group,
            operation_data,
        )

        # Check if any callback denied permission
        # file_permission callbacks return bool (True = allowed, False = denied)
        for result in callback_results:
            if result is False:
                with self._stats_lock:
                    self._block_count += 1
                logger.info(f"File access denied by plugin: {path}")
                return SecurityDecision(
                    allowed=False,
                    reason="Denied by security plugin",
                    metadata={"denied_by": "plugin"},
                )

        # All checks passed
        logger.debug(f"File access allowed: {path}")
        return SecurityDecision(
            allowed=True,
            reason="Passed all security checks",
        )

    def get_stats(self) -> dict[str, int]:
        """Get security check statistics.

        Returns:
            Dictionary with check_count and block_count
        """
        with self._stats_lock:
            return {
                "check_count": self._check_count,
                "block_count": self._block_count,
            }

    def reset_stats(self) -> None:
        """Reset security check statistics."""
        with self._stats_lock:
            self._check_count = 0
            self._block_count = 0


# Global singleton instance (thread-safe via double-checked locking)
_security_lock = threading.Lock()
_security_boundary: SecurityBoundary | None = None


def get_security_boundary() -> SecurityBoundary:
    """Get the global SecurityBoundary instance.

    Uses double-checked locking to prevent race conditions that could
    create duplicate boundaries with inconsistent policies.

    Returns:
        The singleton SecurityBoundary instance
    """
    global _security_boundary
    if _security_boundary is None:
        with _security_lock:
            if _security_boundary is None:
                _security_boundary = SecurityBoundary()
    return _security_boundary


def set_security_boundary(boundary: SecurityBoundary) -> None:
    """Set a custom SecurityBoundary instance (mainly for testing).

    Args:
        boundary: The SecurityBoundary instance to use
    """
    global _security_boundary
    with _security_lock:
        _security_boundary = boundary


def reset_security_boundary() -> None:
    """Reset the global SecurityBoundary instance.

    This is mainly useful for testing to ensure clean state.
    """
    global _security_boundary
    with _security_lock:
        _security_boundary = None
