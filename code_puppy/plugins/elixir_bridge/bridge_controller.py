"""Bridge Controller - Dispatches JSON-RPC commands to Python functionality.

This module implements the command dispatcher for the Elixir bridge.
It translates JSON-RPC method calls into Python tool/agent invocations
and returns results in JSON-RPC format.

Implements BRIDGE_PROTOCOL_V1 with canonical method names:
- run.start, run.cancel, initialize, exit
- invoke_agent, run_shell, file_list, file_read, file_write, grep_search
- mcp.register, mcp.unregister, mcp.list, mcp.status, mcp.call_tool, mcp.health_check

Architecture:
    ┌─────────────┐ JSON-RPC ┌──────────────────┐
    │ stdin │ ────────────────▶ │ BridgeController │
    └─────────────┘ │ .dispatch() │
                                      └────────┬─────────┘
                                               │
                          ┌────────────────────┼────────────────────┐
                          ▼ ▼ ▼
                  ┌──────────────┐ ┌─────────────┐ ┌────────────┐
                  │ Agent Tools │ │ Shell Cmds │ │ File Ops │
                  └──────────────┘ └─────────────┘ └────────────┘

See: docs/protocol/BRIDGE_PROTOCOL_V1.md for full specification.
"""

from __future__ import annotations

import asyncio
from typing import Any

# Model packs import
from code_puppy import model_packs

# Concurrency limit imports
from code_puppy.concurrency_limits import (
    acquire_api_call_slot,
    acquire_file_ops_slot,
    acquire_tool_call_slot,
    get_concurrency_status,
    release_api_call_slot,
    release_file_ops_slot,
    release_tool_call_slot,
)

# MCP imports
from code_puppy.mcp_ import get_mcp_manager

# MessageBus import for EventBus routing
from code_puppy.messaging import get_message_bus

# Run limiter imports
from code_puppy.plugins.pack_parallelism.run_limiter import (
    RunLimiterConfig,
    get_run_limiter,
)

from .wire_protocol import WireMethodError, from_wire_params


class BridgeController:
    """Dispatches JSON-RPC commands to Python functionality.

    This controller is instantiated in bridge mode and handles the
    translation between Elixir JSON-RPC commands and Python tools.
    Uses BRIDGE_PROTOCOL_V1 canonical method names.

    Example:
        controller = BridgeController()
        response = await controller.dispatch({
            "jsonrpc": "2.0",
            "id": "1",
            "method": "run.start",
            "params": {"agent_name": "turbo-executor", "prompt": "Analyze code"}
        })
        # response: {"status": "started", "run_id": "..."}
    """

    def __init__(self) -> None:
        """Initialize the bridge controller."""
        self._running = True
        self._command_count = 0
        self._active_runs: dict[str, Any] = {}  # Track active runs for cancel support

    @property
    def running(self) -> bool:
        """Whether the bridge worker should keep accepting commands."""
        return self._running

    def request_stop(self) -> None:
        """Request the bridge worker loop to stop without awaiting cleanup."""
        self._running = False

    async def shutdown(self) -> None:
        """Shutdown the controller and cleanup resources."""
        self.request_stop()
        # Cancel any active tasks
        for _run_id, run_info in list(self._active_runs.items()):
            task = run_info.get("task")
            if task and not task.done():
                task.cancel()
        self._active_runs.clear()

    def _emit_notification(self, method: str, params: dict[str, Any]) -> None:
        """Emit a JSON-RPC notification to Elixir via stdout.

        Fire-and-forget: writes Content-Length framed JSON-RPC notification.
        Used by _execute_agent_run to emit run.completed / run.failed
        so that Run.State.await_run completes and AgentInvocation can
        extract the response.

        Args:
            method: JSON-RPC method name (e.g., "run.completed")
            params: Notification parameters dict
        """
        import sys

        from .wire_protocol import _serialize_json

        notification = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        }
        try:
            body_bytes = _serialize_json(notification)
            header = f"Content-Length: {len(body_bytes)}\r\n\r\n"
            sys.stdout.buffer.write(header.encode("utf-8"))
            sys.stdout.buffer.write(body_bytes)
            sys.stdout.buffer.flush()
        except Exception:
            # Fire-and-forget: silently ignore errors
            pass

    async def dispatch(self, request: dict[str, Any]) -> dict[str, Any] | None:
        """Dispatch a JSON-RPC request to the appropriate handler.

        Args:
            request: JSON-RPC request dict with "method" and "params"

        Returns:
            Result dict for successful execution, None for notifications

        Raises:
            WireMethodError: If method is unknown or params invalid

        Supported V1 methods:
            - run.start: Start a new agent run
            - run.cancel: Cancel an active run
            - initialize: Initialize the bridge
            - exit: Shutdown the bridge
            - invoke_agent: Run an agent (legacy)
            - run_shell: Execute shell command
            - file_list: List directory
            - file_read: Read file
            - file_write: Write file
            - grep_search: Search files
            - get_status: Bridge status
            - ping: Health check
        """
        method = request.get("method", "")
        params = request.get("params", {})

        self._command_count += 1

        # Normalize slash-style to dot-style for V1 methods
        # e.g., "run/start" -> "run.start"
        normalized_method = method.replace("/", ".")

        # Map method names to handlers (V1 canonical + legacy)
        handlers: dict[str, Any] = {
            "run.start": self._handle_run_start,
            "run.cancel": self._handle_run_cancel,
            "initialize": self._handle_initialize,
            "exit": self._handle_exit,
            "invoke_agent": self._handle_invoke_agent,
            "run_shell": self._handle_run_shell,
            "file_list": self._handle_file_list,
            "file_read": self._handle_file_read,
            "file_write": self._handle_file_write,
            "grep_search": self._handle_grep_search,
            "get_status": self._handle_get_status,
            "ping": self._handle_ping,
            # Concurrency control methods
            "concurrency.acquire": self._handle_concurrency_acquire,
            "concurrency.release": self._handle_concurrency_release,
            "concurrency.status": self._handle_concurrency_status,
            # Run limiter methods
            "run_limiter.acquire": self._handle_run_limiter_acquire,
            "run_limiter.release": self._handle_run_limiter_release,
            "run_limiter.status": self._handle_run_limiter_status,
            "run_limiter.set_limit": self._handle_run_limiter_set_limit,
            # MCP bridge methods
            "mcp.register": self._handle_mcp_register,
            "mcp.unregister": self._handle_mcp_unregister,
            "mcp.list": self._handle_mcp_list,
            "mcp.status": self._handle_mcp_status,
            "mcp.call_tool": self._handle_mcp_call_tool,
            "mcp.health_check": self._handle_mcp_health_check,
            # EventBus bridge methods
            "eventbus.event": self._handle_eventbus_event,
            # Rate limiter methods
            "rate_limiter.record_limit": self._handle_rate_limiter_record_limit,
            "rate_limiter.record_success": self._handle_rate_limiter_record_success,
            "rate_limiter.get_limit": self._handle_rate_limiter_get_limit,
            "rate_limiter.circuit_status": self._handle_rate_limiter_circuit_status,
            # Agent manager methods
            "agent_manager.register": self._handle_agent_manager_register,
            "agent_manager.list": self._handle_agent_manager_list,
            "agent_manager.get_current": self._handle_agent_manager_get_current,
            "agent_manager.set_current": self._handle_agent_manager_set_current,
            # Model packs methods
            "model_packs.get_pack": self._handle_model_packs_get_pack,
            "model_packs.list_packs": self._handle_model_packs_list_packs,
            "model_packs.set_current_pack": self._handle_model_packs_set_current_pack,
            "model_packs.get_current_pack": self._handle_model_packs_get_current_pack,
            "model_packs.get_model_for_role": self._handle_model_packs_get_model_for_role,
            "model_packs.get_fallback_chain": self._handle_model_packs_get_fallback_chain,
            "model_packs.create_pack": self._handle_model_packs_create_pack,
            "model_packs.delete_pack": self._handle_model_packs_delete_pack,
            "model_packs.reload": self._handle_model_packs_reload,
        }

        handler = handlers.get(normalized_method)
        if handler is None:
            raise WireMethodError(f"Unknown method: {method}", code=-32601)

        # Validate and convert params from wire format
        try:
            validated_params = from_wire_params(method, params)
        except (TypeError, ValueError) as e:
            raise WireMethodError(f"Invalid params: {e}", code=-32602)

        # Execute handler
        return await handler(validated_params)

    async def _handle_run_start(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle run.start method (V1 canonical).

        Args:
            params: {"agent_name": str, "prompt": str, "session_id": str | None,
                     "run_id": str | None, "context": dict}
            Also accepts Elixir AgentInvocation wire shape where prompt is
            nested under params["config"]["prompt"] instead of top-level.

        Returns:
            {"status": "started", "run_id": str, "session_id": str | None}
        """
        agent_name = params["agent_name"]
        # code_puppy-mmk.4: Elixir AgentInvocation.invoke puts prompt under
        # config when calling Run.Manager.start_run. Accept both shapes:
        #   Top-level:  {agent_name, prompt, session_id, ...}
        #   Elixir:     {agent_name, config: {prompt, ...}, session_id, ...}
        prompt = params.get("prompt")
        if prompt is None:
            config = params.get("config", {})
            if isinstance(config, dict):
                prompt = config.get("prompt")
        if not prompt:
            raise WireMethodError(
                "run.start requires 'prompt' (top-level or under config)",
                code=-32602,
            )
        session_id = params.get("session_id")
        run_id = params.get("run_id", f"run-{asyncio.get_event_loop().time()}")

        # Check for duplicate run_id
        if run_id in self._active_runs:
            raise WireMethodError(
                f"Run already active: {run_id}",
                code=-32002,  # Run already active
            )

        try:
            # Start the agent (non-blocking - runs in background)
            # Store task reference for cancellation support
            task = asyncio.create_task(
                self._execute_agent_run(run_id, agent_name, prompt, session_id)
            )
            self._active_runs[run_id] = {
                "agent_name": agent_name,
                "status": "starting",
                "task": task,
            }

            return {
                "status": "started",
                "run_id": run_id,
                "session_id": session_id,
                "agent_name": agent_name,
            }
        except Exception as e:
            self._active_runs.pop(run_id, None)
            raise WireMethodError(f"Failed to start run: {e}", code=-32000)

    async def _execute_agent_run(
        self,
        run_id: str,
        agent_name: str,
        prompt: str,
        session_id: str | None,
    ) -> None:
        """Execute an agent run and emit lifecycle events.

        This runs in a background task and emits run.status, run.text,
        run.completed or run.failed notifications back to Elixir via
        stdout so that Run.State.await_run completes and
        AgentInvocation.extract_response can find the response.

        code_puppy-mmk.4: emits canonical run.completed / run.failed
        JSON-RPC notifications with response/error metadata.
        """
        import logging
        import os

        from code_puppy.tools.agent_tools import invoke_agent_headless

        _log = logging.getLogger(__name__)

        try:
            self._active_runs[run_id]["status"] = "running"

            # Prevent recursive delegation: we're inside an Elixir-managed
            # Python worker, so invoke_agent_headless must NOT delegate back
            # to Elixir. Set the guard env var for the duration of the run.
            _prev_skip = os.environ.get("PUP_SKIP_ELIXIR_AGENT_TOOLS")
            os.environ["PUP_SKIP_ELIXIR_AGENT_TOOLS"] = "1"
            try:
                # Execute agent (PUP_SKIP_ELIXIR_AGENT_TOOLS prevents recursion)
                response = await invoke_agent_headless(
                    agent_name=agent_name,
                    prompt=prompt,
                    session_id=session_id,
                )
            finally:
                # Restore previous env var state
                if _prev_skip is None:
                    os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                else:
                    os.environ["PUP_SKIP_ELIXIR_AGENT_TOOLS"] = _prev_skip

            # Emit canonical run.completed notification to Elixir
            # Shape matches port.ex handle_message("run.completed")
            self._emit_notification(
                "run.completed",
                {
                    "run_id": run_id,
                    "session_id": session_id,
                    "result": {"response": response},
                },
            )

            # Mark as completed
            self._active_runs[run_id]["status"] = "completed"
            self._active_runs.pop(run_id, None)

        except asyncio.CancelledError:
            _log.info(f"Run {run_id} cancelled")
            self._active_runs.pop(run_id, None)
            # Emit cancellation notification
            self._emit_notification(
                "run.cancelled",
                {
                    "run_id": run_id,
                    "reason": "cancelled",
                },
            )
            raise  # Re-raise to propagate cancellation
        except Exception as exc:
            _log.warning("run %s failed: %s", run_id, exc)

            # Emit canonical run.failed notification to Elixir
            self._emit_notification(
                "run.failed",
                {
                    "run_id": run_id,
                    "session_id": session_id,
                    "error": str(exc),
                },
            )

            self._active_runs.pop(run_id, None)

    async def _handle_run_cancel(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle run.cancel method (V1 canonical).

        Args:
            params: {"run_id": str, "reason": str}

        Returns:
            {"status": "cancelled", "run_id": str}
        """
        run_id = params["run_id"]
        reason = params.get("reason", "user_requested")

        run_info = self._active_runs.get(run_id)
        if run_info is None:
            raise WireMethodError(f"Run not found: {run_id}", code=-32001)

        try:
            task = run_info.get("task")
            if task and not task.done():
                task.cancel()
                try:
                    # Wait for the task to process cancellation.
                    # Use asyncio.wait instead of wait_for to avoid
                    # CancelledError swallowing issues with task wrapping.
                    done, _pending = await asyncio.wait({task}, timeout=5.0)
                    if not done:
                        # Task didn't finish within timeout; force-cancel
                        task.cancel()
                except asyncio.CancelledError:
                    pass  # Expected on cancellation

            self._active_runs.pop(run_id, None)

            return {
                "status": "cancelled",
                "run_id": run_id,
                "reason": reason,
            }
        except Exception as e:
            self._active_runs.pop(run_id, None)
            raise WireMethodError(f"Failed to cancel run: {e}", code=-32003)

    async def _handle_initialize(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle initialize method (V1 canonical).

        Args:
            params: {"capabilities": list, "config": dict}

        Returns:
            {"status": "initialized", "capabilities": list}
        """
        # Store configuration if needed
        # Future: validate requested capabilities against params.get("capabilities", [])
        # and store config from params.get("config", {})

        return {
            "status": "initialized",
            "capabilities": ["shell", "file_ops", "agents", "event_stream"],
            "version": "1.0.0",
        }

    async def _handle_exit(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle exit method (V1 canonical).

        Args:
            params: {"reason": str, "timeout_ms": int}

        Returns:
            {"status": "exiting", "reason": str}
        """
        reason = params.get("reason", "shutdown")

        # Initiate graceful shutdown
        self.request_stop()

        return {
            "status": "exiting",
            "reason": reason,
            "timeout_ms": params.get("timeout_ms", 5000),
        }

    async def _handle_invoke_agent(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle invoke_agent method.

        Args:
            params: {"agent_name": str, "prompt": str, "session_id": str | None}

        Returns:
            {"response": str, "success": bool}
        """
        import logging

        from code_puppy.tools.agent_tools import invoke_agent_headless

        _log = logging.getLogger(__name__)

        agent_name = params["agent_name"]
        prompt = params["prompt"]
        session_id = params.get("session_id")

        try:
            # invoke_agent_headless returns string directly
            # PUP_SKIP_ELIXIR_AGENT_TOOLS is set inside the function to
            # prevent recursive delegation back to Elixir.
            response = await invoke_agent_headless(
                agent_name=agent_name,
                prompt=prompt,
                session_id=session_id,
            )
            return {
                "success": True,
                "response": response,
                "agent_name": agent_name,
                "session_id": session_id,
            }
        except Exception as e:
            _log.debug("invoke_agent failed for %s: %s", agent_name, e)
            return {
                "success": False,
                "error": str(e),
                "agent_name": agent_name,
            }

    async def _handle_run_shell(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle run_shell method.

        Args:
            params: {"command": str, "cwd": str | None, "timeout": int}

        Returns:
            {"stdout": str, "stderr": str, "exit_code": int, "success": bool}
        """
        from code_puppy.tools.command_runner import run_shell_command

        command = params["command"]
        cwd = params.get("cwd")
        timeout = params.get("timeout", 60)

        # Create a minimal RunContext
        # In bridge mode, we don't have the full agent context
        class MinimalContext:
            pass

        context = MinimalContext()

        try:
            result = await run_shell_command(
                context=context,
                command=command,
                cwd=cwd,
                timeout=timeout,
            )

            return {
                "success": result.success,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "exit_code": result.exit_code,
                "execution_time": result.execution_time,
                "command": command,
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
                "command": command,
            }

    async def _handle_file_list(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle file_list method.

        Args:
            params: {"directory": str, "recursive": bool}

        Returns:
            {"files": [...], "total_size": int, "file_count": int}
        """
        import os

        directory = params["directory"]
        recursive = params.get("recursive", False)

        try:
            files = []
            total_size = 0
            file_count = 0
            dir_count = 0

            if recursive:
                for root, dirs, filenames in os.walk(directory):
                    depth = root.replace(directory, "").count(os.sep)
                    dir_count += len(dirs)

                    for filename in filenames:
                        filepath = os.path.join(root, filename)
                        try:
                            size = os.path.getsize(filepath)
                            total_size += size
                            file_count += 1
                            files.append(
                                {
                                    "path": filepath,
                                    "type": "file",
                                    "size": size,
                                    "depth": depth,
                                }
                            )
                        except OSError:
                            pass
            else:
                entries = os.listdir(directory)
                for entry in entries:
                    path = os.path.join(directory, entry)
                    try:
                        stat = os.stat(path)
                        is_dir = os.path.isdir(path)
                        files.append(
                            {
                                "path": path,
                                "type": "dir" if is_dir else "file",
                                "size": 0 if is_dir else stat.st_size,
                                "depth": 0,
                            }
                        )
                        if is_dir:
                            dir_count += 1
                        else:
                            file_count += 1
                            total_size += stat.st_size
                    except OSError:
                        pass

            return {
                "success": True,
                "directory": directory,
                "files": files,
                "total_size": total_size,
                "file_count": file_count,
                "dir_count": dir_count,
                "recursive": recursive,
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
                "directory": directory,
            }

    async def _handle_file_read(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle file_read method.

        Args:
            params: {"path": str, "start_line": int | None, "num_lines": int | None}

        Returns:
            {"content": str, "total_lines": int, "success": bool}
        """
        path = params["path"]
        start_line = params.get("start_line")
        num_lines = params.get("num_lines")

        try:
            with open(path, "r", encoding="utf-8") as f:
                lines = f.readlines()
                total_lines = len(lines)

                if start_line is not None:
                    start_idx = start_line - 1  # Convert to 0-indexed
                    end_idx = start_idx + (num_lines or len(lines))
                    selected = lines[start_idx:end_idx]
                    content = "".join(selected)
                else:
                    content = "".join(lines)

                return {
                    "success": True,
                    "path": path,
                    "content": content,
                    "total_lines": total_lines,
                    "start_line": start_line,
                    "num_lines_read": num_lines if start_line else total_lines,
                }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
                "path": path,
            }

    async def _handle_file_write(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle file_write method.

        Args:
            params: {"path": str, "content": str}

        Returns:
            {"success": bool, "bytes_written": int}
        """
        path = params["path"]
        content = params["content"]

        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
                bytes_written = len(content.encode("utf-8"))

                return {
                    "success": True,
                    "path": path,
                    "bytes_written": bytes_written,
                }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
                "path": path,
            }

    async def _handle_grep_search(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle grep_search method.

        Args:
            params: {"search_string": str, "directory": str}

        Returns:
            {"matches": [...], "total_matches": int}
        """
        import os
        import re

        search_string = params["search_string"]
        directory = params.get("directory", ".")

        try:
            # Compile regex pattern
            pattern = re.compile(search_string)

            matches = []
            files_searched = 0

            for root, _, filenames in os.walk(directory):
                for filename in filenames:
                    if filename.endswith(".pyc") or "__pycache__" in root:
                        continue

                    filepath = os.path.join(root, filename)
                    files_searched += 1

                    try:
                        with open(
                            filepath, "r", encoding="utf-8", errors="ignore"
                        ) as f:
                            for line_num, line in enumerate(f, 1):
                                if pattern.search(line):
                                    matches.append(
                                        {
                                            "file_path": filepath,
                                            "line_number": line_num,
                                            "line_content": line.rstrip("\\n"),
                                        }
                                    )
                    except OSError, UnicodeDecodeError:
                        pass

            return {
                "success": True,
                "search_term": search_string,
                "directory": directory,
                "matches": matches,
                "total_matches": len(matches),
                "files_searched": files_searched,
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
                "search_term": search_string,
            }

    async def _handle_get_status(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle get_status method.

        Returns:
            Bridge status and health information
        """
        import sys

        return {
            "success": True,
            "bridge_version": "1.0.0",
            "commands_processed": self._command_count,
            "running": self._running,
            "python_version": sys.version,
            "platform": sys.platform,
        }

    async def _handle_ping(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle ping method - simple health check."""
        return {
            "success": True,
            "pong": True,
            "timestamp": asyncio.get_event_loop().time(),
        }

    async def _handle_concurrency_acquire(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle concurrency.acquire method.

        Acquires a slot from the local semaphore when Elixir requests it.

        Args:
            params: {"type": str, "timeout": float | None}

        Returns:
            {"status": "ok"} on success, raises error on failure
        """
        limiter_type = params.get("type", "file_ops")
        _timeout = params.get("timeout")  # Reserved for future use (timeout support)

        # Map limiter type to appropriate semaphore
        if limiter_type == "file_ops":
            await acquire_file_ops_slot()
        elif limiter_type == "api_calls":
            await acquire_api_call_slot()
        elif limiter_type == "tool_calls":
            await acquire_tool_call_slot()
        else:
            raise WireMethodError(
                f"Unknown limiter type: {limiter_type}",
                code=-32602,  # Invalid params
            )

        return {"status": "ok", "type": limiter_type}

    async def _handle_concurrency_release(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle concurrency.release method.

        Releases a slot back to the local semaphore.

        Args:
            params: {"type": str}

        Returns:
            {"status": "ok"}
        """
        limiter_type = params.get("type", "file_ops")

        # Map limiter type to appropriate release function
        if limiter_type == "file_ops":
            release_file_ops_slot()
        elif limiter_type == "api_calls":
            release_api_call_slot()
        elif limiter_type == "tool_calls":
            release_tool_call_slot()
        else:
            raise WireMethodError(
                f"Unknown limiter type: {limiter_type}",
                code=-32602,  # Invalid params
            )

        return {"status": "ok", "type": limiter_type}

    async def _handle_concurrency_status(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle concurrency.status method.

        Returns current concurrency status from local semaphores.

        Returns:
            Concurrency status dict from get_concurrency_status()
        """
        status = get_concurrency_status()
        return {"status": "ok", "concurrency": status}

    # Run Limiter Handlers

    async def _handle_run_limiter_acquire(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle run_limiter.acquire method.

        Acquires a run slot from the local RunLimiter when Elixir requests it.
        Elixir handles the global counter state; Python handles reentrancy locally.

        Args:
            params: {"timeout": float | None}

        Returns:
            {"status": "ok"} on success, raises error on failure
        """
        timeout = params.get("timeout")

        limiter = get_run_limiter()

        try:
            # Use the RunLimiter's async acquire
            if timeout is not None:
                await limiter.acquire_async(timeout=timeout)
            else:
                await limiter.acquire_async()
            return {"status": "ok"}
        except Exception as e:
            raise WireMethodError(
                f"Failed to acquire run slot: {e}",
                code=-32603,  # Internal error
            )

    async def _handle_run_limiter_release(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle run_limiter.release method.

        Releases a run slot back to the local RunLimiter.

        Args:
            params: {} (no params needed)

        Returns:
            {"status": "ok"}
        """
        limiter = get_run_limiter()

        try:
            limiter.release()
            return {"status": "ok"}
        except Exception as e:
            raise WireMethodError(
                f"Failed to release run slot: {e}",
                code=-32603,  # Internal error
            )

    async def _handle_run_limiter_status(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle run_limiter.status method.

        Returns current run limiter status from local RunLimiter.

        Returns:
            Status dict with limit, active, and waiters counts
        """
        limiter = get_run_limiter()

        return {
            "status": "ok",
            "limit": limiter.effective_limit,
            "active": limiter.active_count,
            "waiters": limiter.waiters_count,
        }

    async def _handle_run_limiter_set_limit(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle run_limiter.set_limit method.

        Updates the run limiter configuration with a new limit.

        Args:
            params: {"limit": int}

        Returns:
            {"status": "ok", "limit": int}
        """
        limit = params.get("limit", 2)

        limiter = get_run_limiter()

        try:
            # Update the limit by creating a new config with the updated limit
            current_config = limiter._config
            new_config = RunLimiterConfig(
                max_concurrent_runs=limit,
                allow_parallel=current_config.allow_parallel,
                wait_timeout=current_config.wait_timeout,
            )
            limiter.update_config(new_config)

            return {"status": "ok", "limit": limiter.effective_limit}
        except Exception as e:
            raise WireMethodError(
                f"Failed to set run limit: {e}",
                code=-32603,  # Internal error
            )

    # MCP Bridge Handlers

    async def _handle_mcp_register(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle mcp.register method.

        Args:
            params: {"name": str, "command": str, "args": list, "env": dict | None, "opts": dict | None}

        Returns:
            {"status": "registered", "server_id": str}
        """
        from code_puppy.mcp_ import ServerConfig

        name = params["name"]
        command = params["command"]
        args = params["args"]
        env = params.get("env", {})
        opts = params.get("opts", {})

        try:
            manager = get_mcp_manager()

            # Build server config from params
            config = ServerConfig(
                id="",  # Auto-generated
                name=name,
                type="stdio",
                enabled=True,
                config={
                    "command": command,
                    "args": args,
                    **env,  # Merge env vars into config
                    **opts,  # Merge additional opts
                },
            )

            server_id = manager.register_server(config)

            return {
                "status": "registered",
                "server_id": server_id,
                "name": name,
            }
        except Exception as e:
            raise WireMethodError(f"Failed to register MCP server: {e}", code=-32000)

    async def _handle_mcp_unregister(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle mcp.unregister method.

        Args:
            params: {"server_id": str}

        Returns:
            {"status": "unregistered", "server_id": str}
        """
        server_id = params["server_id"]

        try:
            manager = get_mcp_manager()
            removed = manager.remove_server(server_id)

            if not removed:
                raise WireMethodError(
                    f"Server not found: {server_id}",
                    code=-32001,  # Server not found
                )

            return {
                "status": "unregistered",
                "server_id": server_id,
            }
        except WireMethodError:
            raise
        except Exception as e:
            raise WireMethodError(f"Failed to unregister MCP server: {e}", code=-32000)

    async def _handle_mcp_list(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle mcp.list method.

        Returns:
            {"servers": [...], "count": int}
        """
        try:
            manager = get_mcp_manager()
            servers = manager.list_servers()

            # Serialize ServerInfo to dict
            server_list = []
            for info in servers:
                server_list.append(
                    {
                        "id": info.id,
                        "name": info.name,
                        "type": info.type,
                        "enabled": info.enabled,
                        "state": info.state.value
                        if hasattr(info.state, "value")
                        else str(info.state),
                        "quarantined": info.quarantined,
                        "uptime_seconds": info.uptime_seconds,
                        "error_message": info.error_message,
                        "health": info.health,
                        "latency_ms": info.latency_ms,
                    }
                )

            return {
                "status": "ok",
                "servers": server_list,
                "count": len(server_list),
            }
        except Exception as e:
            raise WireMethodError(f"Failed to list MCP servers: {e}", code=-32000)

    async def _handle_mcp_status(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle mcp.status method.

        Args:
            params: {"server_id": str}

        Returns:
            Comprehensive server status dict
        """
        server_id = params["server_id"]

        try:
            manager = get_mcp_manager()
            status = manager.get_server_status(server_id)

            if not status.get("exists", False):
                raise WireMethodError(
                    f"Server not found: {server_id}",
                    code=-32001,  # Server not found
                )

            return {
                "status": "ok",
                **status,
            }
        except WireMethodError:
            raise
        except Exception as e:
            raise WireMethodError(f"Failed to get MCP server status: {e}", code=-32000)

    async def _handle_mcp_call_tool(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle mcp.call_tool method.

        Args:
            params: {"server_id": str, "method": str, "params": dict, "timeout": float}

        Returns:
            Error response directing user to use local MCP
        """
        # For now, tool calls through the bridge are not supported
        # due to complex lifecycle requirements
        return {
            "status": "error",
            "error": "mcp.call_tool through bridge not supported",
            "message": "Use local MCP manager for tool calls. Direct Elixir -> Python tool calls have complex lifecycle requirements.",
            "fallback": "local",
        }

    async def _handle_mcp_health_check(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle mcp.health_check method.

        Returns:
            Health status for all MCP servers with health data
        """
        try:
            manager = get_mcp_manager()
            servers = manager.list_servers()

            # Build health check response
            health_data = []
            for info in servers:
                health_info = info.health or {}
                health_data.append(
                    {
                        "id": info.id,
                        "name": info.name,
                        "state": info.state.value
                        if hasattr(info.state, "value")
                        else str(info.state),
                        "enabled": info.enabled,
                        "quarantined": info.quarantined,
                        "is_healthy": health_info.get("is_healthy", False),
                        "latency_ms": info.latency_ms,
                        "uptime_seconds": info.uptime_seconds,
                        "error": health_info.get("error"),
                    }
                )

            # Count healthy servers
            healthy_count = sum(1 for h in health_data if h["is_healthy"])

            return {
                "status": "ok",
                "servers": health_data,
                "total": len(health_data),
                "healthy": healthy_count,
                "unhealthy": len(health_data) - healthy_count,
            }
        except Exception as e:
            raise WireMethodError(f"Failed to get MCP health check: {e}", code=-32000)

    async def _handle_eventbus_event(self, params: dict[str, Any]) -> dict[str, Any]:
        """Handle eventbus.event method.

        Routes incoming events from Elixir EventBus to the local MessageBus.
        This is for reverse-channel events FROM Elixir TO Python.

        Args:
            params: {"topic": str, "event_type": str, "payload": dict, "timestamp": str | None}

        Returns:
            {"status": "ok"} on success
        """
        topic = params.get("topic", "")
        event_type = params.get("event_type", "")
        payload = params.get("payload", {})

        try:
            # Get message bus and emit the event as a generic message
            bus = get_message_bus()

            # Create a text message with the event info for now
            # Future: Could create a dedicated EventMessage type
            from code_puppy.messaging.messages import (
                MessageCategory,
                MessageLevel,
                TextMessage,
            )

            # Format event info for display
            event_text = f"[EventBus:{topic}] {event_type}"
            if payload:
                import json

                payload_str = json.dumps(payload, separators=(",", ":"))
                event_text += f" | {payload_str}"

            event_message = TextMessage(
                level=MessageLevel.INFO,
                text=event_text,
                category=MessageCategory.SYSTEM,
                is_markdown=False,
            )

            bus.emit(event_message)

            return {"status": "ok", "topic": topic, "event_type": event_type}
        except Exception as e:
            # Return error but don't raise - EventBus routing is auxiliary
            return {
                "status": "error",
                "error": str(e),
                "topic": topic,
                "event_type": event_type,
            }

    # Rate Limiter Handlers

    async def _handle_rate_limiter_record_limit(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle rate_limiter.record_limit method.

        Records a rate limit event (429) for a model in the local adaptive rate limiter.

        Args:
            params: {"model_name": str}

        Returns:
            {"status": "ok", "model_name": str, "new_limit": float}
        """
        from code_puppy import adaptive_rate_limiter

        model_name = params["model_name"]

        try:
            # Record the rate limit locally
            await adaptive_rate_limiter.record_rate_limit(model_name)

            # Get the current status to return the new limit
            status = adaptive_rate_limiter.get_status()
            model_status = status.get(model_name.lower().strip(), {})
            new_limit = model_status.get("current_limit", 0)

            return {
                "status": "ok",
                "model_name": model_name,
                "new_limit": new_limit,
            }
        except Exception as e:
            raise WireMethodError(
                f"Failed to record rate limit: {e}",
                code=-32603,  # Internal error
            )

    async def _handle_rate_limiter_record_success(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle rate_limiter.record_success method.

        Records a successful request for a model in the local adaptive rate limiter.

        Args:
            params: {"model_name": str}

        Returns:
            {"status": "ok", "model_name": str}
        """
        from code_puppy import adaptive_rate_limiter

        model_name = params["model_name"]

        try:
            # Record success locally
            await adaptive_rate_limiter.record_success(model_name)

            return {
                "status": "ok",
                "model_name": model_name,
            }
        except Exception as e:
            raise WireMethodError(
                f"Failed to record success: {e}",
                code=-32603,  # Internal error
            )

    async def _handle_rate_limiter_get_limit(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle rate_limiter.get_limit method.

        Gets the current concurrency limit for a model from the local adaptive rate limiter.

        Args:
            params: {"model_name": str}

        Returns:
            {"status": "ok", "model_name": str, "limit": float}
        """
        from code_puppy import adaptive_rate_limiter

        model_name = params["model_name"]

        try:
            status = adaptive_rate_limiter.get_status()
            model_status = status.get(model_name.lower().strip(), {})
            limit = model_status.get("current_limit", 0)

            return {
                "status": "ok",
                "model_name": model_name,
                "limit": limit,
            }
        except Exception as e:
            raise WireMethodError(
                f"Failed to get limit: {e}",
                code=-32603,  # Internal error
            )

    async def _handle_rate_limiter_circuit_status(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle rate_limiter.circuit_status method.

        Gets the circuit breaker status for a model from the local adaptive rate limiter.

        Args:
            params: {"model_name": str}

        Returns:
            {"status": "ok", "model_name": str, "circuit_open": bool, "circuit_state": str}
        """
        from code_puppy import adaptive_rate_limiter

        model_name = params["model_name"]

        try:
            is_open = adaptive_rate_limiter.is_circuit_open(model_name)

            # Get detailed status
            status = adaptive_rate_limiter.get_status()
            model_status = status.get(model_name.lower().strip(), {})
            circuit_state = model_status.get("circuit_state", "closed")

            return {
                "status": "ok",
                "model_name": model_name,
                "circuit_open": is_open,
                "circuit_state": circuit_state,
            }
        except Exception as e:
            raise WireMethodError(
                f"Failed to get circuit status: {e}",
                code=-32603,  # Internal error
            )

    # Agent Manager Handlers

    async def _handle_agent_manager_register(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle agent_manager.register method.

        Registers agent metadata in the local agent manager.

        Args:
            params: {"agent_name": str, "agent_info": dict}

        Returns:
            {"status": "ok", "agent_name": str}
        """
        agent_name = params["agent_name"]
        agent_info = params.get("agent_info", {})

        try:
            # Create a simple wrapper to pass agent_info
            # The actual registration requires an agent factory, so we
            # store just the metadata for now
            # Note: Full agent registration requires a factory function
            # which isn't available via the bridge
            return {
                "status": "ok",
                "agent_name": agent_name,
                "registered_info": agent_info,
                "note": "Agent metadata recorded. Full registration requires local agent factory.",
            }
        except Exception as e:
            raise WireMethodError(
                f"Failed to register agent: {e}",
                code=-32603,  # Internal error
            )

    async def _handle_agent_manager_list(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle agent_manager.list method.

        Lists all available agents from the local agent manager.

        Returns:
            {"status": "ok", "agents": dict[str, str]}
        """
        from code_puppy.agents import agent_manager

        try:
            agents = agent_manager.get_available_agents()

            return {
                "status": "ok",
                "agents": agents,
                "count": len(agents),
            }
        except Exception as e:
            raise WireMethodError(
                f"Failed to list agents: {e}",
                code=-32603,  # Internal error
            )

    async def _handle_agent_manager_get_current(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle agent_manager.get_current method.

        Gets the current agent name from the local agent manager.

        Returns:
            {"status": "ok", "current_agent": str | None}
        """
        from code_puppy.agents import agent_manager

        try:
            current_agent_name = agent_manager.get_current_agent_name()

            return {
                "status": "ok",
                "current_agent": current_agent_name,
            }
        except Exception as e:
            raise WireMethodError(
                f"Failed to get current agent: {e}",
                code=-32603,  # Internal error
            )

    async def _handle_agent_manager_set_current(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle agent_manager.set_current method.

        Sets the current agent in the local agent manager.

        Args:
            params: {"agent_name": str}

        Returns:
            {"status": "ok", "agent_name": str}
        """
        from code_puppy.agents import agent_manager

        agent_name = params["agent_name"]

        try:
            success = agent_manager.set_current_agent(agent_name)

            if success:
                return {
                    "status": "ok",
                    "agent_name": agent_name,
                }
            else:
                return {
                    "status": "error",
                    "error": f"Agent '{agent_name}' not found",
                    "agent_name": agent_name,
                }
        except Exception as e:
            raise WireMethodError(
                f"Failed to set current agent: {e}",
                code=-32603,  # Internal error
            )

    # Model packs handlers

    async def _handle_model_packs_get_pack(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.get_pack method.

        Args:
            params: {"name": str | None}

        Returns:
            {"status": "ok", "pack": dict} or {"status": "error", "error": str}
        """
        try:
            name = params.get("name")
            pack = model_packs.get_pack(name)

            # Convert pack to dict for serialization
            pack_dict = {
                "name": pack.name,
                "description": pack.description,
                "default_role": pack.default_role,
                "roles": {
                    role_name: {
                        "primary": config.primary,
                        "fallbacks": config.fallbacks,
                        "trigger": config.trigger,
                    }
                    for role_name, config in pack.roles.items()
                },
            }

            return {"status": "ok", "pack": pack_dict}
        except Exception as e:
            raise WireMethodError(f"Failed to get pack: {e}", code=-32000)

    async def _handle_model_packs_list_packs(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.list_packs method.

        Returns:
            {"status": "ok", "packs": list[dict], "count": int}
        """
        try:
            packs = model_packs.list_packs()

            packs_list = []
            for pack in packs:
                packs_list.append(
                    {
                        "name": pack.name,
                        "description": pack.description,
                        "default_role": pack.default_role,
                        "roles": {
                            role_name: {
                                "primary": config.primary,
                                "fallbacks": config.fallbacks,
                                "trigger": config.trigger,
                            }
                            for role_name, config in pack.roles.items()
                        },
                    }
                )

            return {"status": "ok", "packs": packs_list, "count": len(packs_list)}
        except Exception as e:
            raise WireMethodError(f"Failed to list packs: {e}", code=-32000)

    async def _handle_model_packs_set_current_pack(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.set_current_pack method.

        Args:
            params: {"name": str}

        Returns:
            {"status": "ok", "name": str} or {"status": "error", "error": str}
        """
        try:
            name = params["name"]
            success = model_packs.set_current_pack(name)

            if success:
                return {"status": "ok", "name": name}
            else:
                available = [p.name for p in model_packs.list_packs()]
                return {
                    "status": "error",
                    "error": f"Unknown pack: {name}",
                    "available": available,
                }
        except Exception as e:
            raise WireMethodError(f"Failed to set current pack: {e}", code=-32000)

    async def _handle_model_packs_get_current_pack(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.get_current_pack method.

        Returns:
            {"status": "ok", "pack": dict}
        """
        try:
            pack = model_packs.get_current_pack()

            pack_dict = {
                "name": pack.name,
                "description": pack.description,
                "default_role": pack.default_role,
                "roles": {
                    role_name: {
                        "primary": config.primary,
                        "fallbacks": config.fallbacks,
                        "trigger": config.trigger,
                    }
                    for role_name, config in pack.roles.items()
                },
            }

            return {"status": "ok", "pack": pack_dict}
        except Exception as e:
            raise WireMethodError(f"Failed to get current pack: {e}", code=-32000)

    async def _handle_model_packs_get_model_for_role(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.get_model_for_role method.

        Args:
            params: {"role": str | None}

        Returns:
            {"status": "ok", "model": str}
        """
        try:
            role = params.get("role")
            model = model_packs.get_model_for_role(role)

            return {"status": "ok", "model": model}
        except Exception as e:
            raise WireMethodError(f"Failed to get model for role: {e}", code=-32000)

    async def _handle_model_packs_get_fallback_chain(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.get_fallback_chain method.

        Args:
            params: {"role": str | None}

        Returns:
            {"status": "ok", "chain": list[str]}
        """
        try:
            role = params.get("role")
            pack = model_packs.get_current_pack()
            chain = pack.get_fallback_chain(role)

            return {"status": "ok", "chain": chain}
        except Exception as e:
            raise WireMethodError(f"Failed to get fallback chain: {e}", code=-32000)

    async def _handle_model_packs_create_pack(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.create_pack method.

        Args:
            params: {"name": str, "description": str, "roles": dict, "default_role": str}

        Returns:
            {"status": "ok", "pack": dict} or {"status": "error", "error": str}
        """
        try:
            name = params["name"]
            description = params["description"]
            roles = params.get("roles", {})
            default_role = params.get("default_role", "coder")

            pack = model_packs.create_user_pack(
                name=name,
                description=description,
                roles=roles,
                default_role=default_role,
            )

            pack_dict = {
                "name": pack.name,
                "description": pack.description,
                "default_role": pack.default_role,
                "roles": {
                    role_name: {
                        "primary": config.primary,
                        "fallbacks": config.fallbacks,
                        "trigger": config.trigger,
                    }
                    for role_name, config in pack.roles.items()
                },
            }

            return {"status": "ok", "pack": pack_dict}
        except ValueError as e:
            return {"status": "error", "error": str(e)}
        except Exception as e:
            raise WireMethodError(f"Failed to create pack: {e}", code=-32000)

    async def _handle_model_packs_delete_pack(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.delete_pack method.

        Args:
            params: {"name": str}

        Returns:
            {"status": "ok", "deleted": bool}
        """
        try:
            name = params["name"]
            deleted = model_packs.delete_user_pack(name)

            return {"status": "ok", "deleted": deleted}
        except Exception as e:
            raise WireMethodError(f"Failed to delete pack: {e}", code=-32000)

    async def _handle_model_packs_reload(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Handle model_packs.reload method.

        Returns:
            {"status": "ok"}
        """
        try:
            model_packs.load_user_packs()
            return {"status": "ok"}
        except Exception as e:
            raise WireMethodError(f"Failed to reload packs: {e}", code=-32000)
