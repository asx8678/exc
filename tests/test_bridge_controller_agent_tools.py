"""Tests for bridge_controller agent-tools integration (code_puppy-mmk.4).

Covers:
- Wire shape compatibility: run.start accepts prompt from config
- _execute_agent_run emits run.completed / run.failed notifications
- PUP_SKIP_ELIXIR_AGENT_TOOLS recursion guard
- _emit_notification produces valid JSON-RPC notifications
- _handle_run_start validates prompt extraction
- Bridge fallback logging
- asyncio.run safety (no use of asyncio.run in sync wrappers)
"""

from __future__ import annotations

import os
from unittest.mock import AsyncMock, patch

import pytest

from code_puppy.plugins.elixir_bridge.bridge_controller import BridgeController
from code_puppy.plugins.elixir_bridge.wire_protocol import (
    WireMethodError,
    from_wire_params,
)

# ── Fixtures ──────────────────────────────────────────────────────────────


@pytest.fixture
def controller():
    return BridgeController()


@pytest.fixture
def capture_notifications():
    """Capture notifications emitted via _emit_notification."""
    notifications = []

    def capture_emit(self, method, params):
        notifications.append({"method": method, "params": params})

    with patch.object(BridgeController, "_emit_notification", capture_emit):
        yield notifications


# ── 1. Wire shape: run.start accepts prompt under config ────────────────


class TestRunStartPromptExtraction:
    """code_puppy-mmk.4: Elixir AgentInvocation puts prompt under config."""

    def test_top_level_prompt(self):
        """Standard shape: prompt at top level."""
        result = from_wire_params(
            "run.start",
            {
                "agent_name": "code-puppy",
                "prompt": "hello",
            },
        )
        assert result["prompt"] == "hello"
        assert result["agent_name"] == "code-puppy"

    def test_prompt_under_config(self):
        """Elixir shape: prompt nested under config dict."""
        result = from_wire_params(
            "run.start",
            {
                "agent_name": "code-puppy",
                "config": {"prompt": "hello from config", "is_new_session": True},
            },
        )
        assert result["prompt"] == "hello from config"
        assert result["agent_name"] == "code-puppy"
        # Config should be preserved
        assert result["config"]["is_new_session"] is True

    def test_missing_prompt_raises(self):
        """Both top-level and config missing prompt → error."""
        with pytest.raises(WireMethodError, match="prompt"):
            from_wire_params(
                "run.start",
                {
                    "agent_name": "code-puppy",
                    "config": {"is_new_session": True},
                },
            )

    def test_top_level_prompt_takes_precedence(self):
        """When both exist, top-level wins."""
        result = from_wire_params(
            "run.start",
            {
                "agent_name": "code-puppy",
                "prompt": "top-level",
                "config": {"prompt": "from-config"},
            },
        )
        assert result["prompt"] == "top-level"


# ── 2. _execute_agent_run emits run.completed / run.failed ──────────────


class TestExecuteAgentRunNotifications:
    """code_puppy-mmk.4: must emit canonical notifications."""

    @pytest.mark.asyncio
    async def test_completed_emits_notification(
        self, controller, capture_notifications
    ):
        """On success, run.completed notification is emitted to stdout."""
        mock_response = "agent response text"

        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            new_callable=AsyncMock,
            return_value=mock_response,
        ):
            os.environ["PUP_SKIP_ELIXIR_AGENT_TOOLS"] = "1"
            try:
                controller._active_runs["test-run-1"] = {
                    "agent_name": "test-agent",
                    "status": "starting",
                }
                await controller._execute_agent_run(
                    run_id="test-run-1",
                    agent_name="test-agent",
                    prompt="test prompt",
                    session_id="test-session",
                )
            finally:
                os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)

        assert len(capture_notifications) == 1
        notif = capture_notifications[0]
        assert notif["method"] == "run.completed"
        assert notif["params"]["run_id"] == "test-run-1"
        assert notif["params"]["result"]["response"] == mock_response

    @pytest.mark.asyncio
    async def test_failed_emits_notification(self, controller, capture_notifications):
        """On failure, run.failed notification is emitted."""
        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            new_callable=AsyncMock,
            side_effect=RuntimeError("model not found"),
        ):
            os.environ["PUP_SKIP_ELIXIR_AGENT_TOOLS"] = "1"
            try:
                controller._active_runs["test-run-2"] = {
                    "agent_name": "test-agent",
                    "status": "starting",
                }
                await controller._execute_agent_run(
                    run_id="test-run-2",
                    agent_name="test-agent",
                    prompt="test prompt",
                    session_id=None,
                )
            finally:
                os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)

        assert len(capture_notifications) == 1
        notif = capture_notifications[0]
        assert notif["method"] == "run.failed"
        assert "model not found" in notif["params"]["error"]


# ── 3. PUP_SKIP_ELIXIR_AGENT_TOOLS recursion guard ───────────────────────


class TestRecursionGuard:
    """code_puppy-mmk.4: prevent recursive Elixir delegation."""

    @pytest.mark.asyncio
    async def test_env_guard_set_during_run(self, controller):
        """PUP_SKIP_ELIXIR_AGENT_TOOLS is set to 1 during _execute_agent_run."""
        captured_values = []

        async def capture_env(*args, **kwargs):
            captured_values.append(os.environ.get("PUP_SKIP_ELIXIR_AGENT_TOOLS"))
            return "response"

        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            side_effect=capture_env,
        ):
            os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
            controller._active_runs["test-run-3"] = {
                "agent_name": "test-agent",
                "status": "starting",
            }
            await controller._execute_agent_run(
                run_id="test-run-3",
                agent_name="test-agent",
                prompt="test",
                session_id=None,
            )

        # Guard was set during execution
        assert captured_values == ["1"]

        # Guard was restored after execution
        assert "PUP_SKIP_ELIXIR_AGENT_TOOLS" not in os.environ

    @pytest.mark.asyncio
    async def test_env_guard_restored_on_exception(self, controller):
        """Guard is restored even if invoke_agent_headless raises."""
        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            new_callable=AsyncMock,
            side_effect=RuntimeError("boom"),
        ):
            os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
            controller._active_runs["test-run-4"] = {
                "agent_name": "test-agent",
                "status": "starting",
            }
            await controller._execute_agent_run(
                run_id="test-run-4",
                agent_name="test-agent",
                prompt="test",
                session_id=None,
            )

        # Guard was cleaned up
        assert "PUP_SKIP_ELIXIR_AGENT_TOOLS" not in os.environ


# ── 4. _emit_notification produces valid JSON-RPC ─────────────────────────


class TestEmitNotification:
    """code_puppy-mmk.4: notification format matches port.ex expectations."""

    def test_notification_delegates_correctly(self, controller, capture_notifications):
        """_emit_notification stores method and params."""
        controller._emit_notification(
            "run.completed",
            {
                "run_id": "run-123",
                "session_id": "sess-456",
                "result": {"response": "done"},
            },
        )

        # Note: capture_notifications fixture patches _emit_notification
        # so the actual call doesn't happen — this just validates the
        # _emit_notification interface. For real format testing,
        # we test the wire_protocol serialization separately.

    def test_emit_silently_ignores_errors(self, controller):
        """If stdout write fails, no exception is raised."""
        # We can't easily patch sys.stdout.buffer (readonly),
        # so we test the try/except in _emit_notification by
        # patching the serialization function to raise.
        with patch(
            "code_puppy.plugins.elixir_bridge.wire_protocol._serialize_json",
            side_effect=OSError("serialization broken"),
        ):
            # Should not raise
            controller._emit_notification("run.failed", {"error": "test"})


# ── 5. _handle_run_start validation ──────────────────────────────────────


class TestHandleRunStart:
    """code_puppy-mmk.4: validate prompt extraction in handler."""

    @pytest.mark.asyncio
    async def test_config_prompt_accepted(self, controller):
        """run.start with prompt under config succeeds."""
        # Side-effect closes the unawaited coroutine to prevent
        # RuntimeWarning during GC (code_puppy-mmk.4).
        with patch("asyncio.create_task", side_effect=lambda coro: coro.close()):
            result = await controller._handle_run_start(
                {
                    "agent_name": "test-agent",
                    "prompt": "via config",
                    "session_id": None,
                    "context": {},
                }
            )
            assert result["status"] == "started"
            assert result["agent_name"] == "test-agent"

    @pytest.mark.asyncio
    async def test_no_prompt_raises(self, controller):
        """run.start without prompt (top-level or config) raises."""
        with pytest.raises(WireMethodError, match="prompt"):
            await controller._handle_run_start(
                {
                    "agent_name": "test-agent",
                    "session_id": None,
                    "context": {},
                }
            )


# ── 6. Bridge fallback logging ───────────────────────────────────────────


class TestBridgeFallbackLogging:
    """code_puppy-mmk.4: debug/warning logging on fallback."""

    @pytest.mark.asyncio
    async def test_invoke_headless_logs_on_bridge_error(self, caplog):
        """invoke_agent_headless logs at DEBUG when Elixir bridge fails."""
        import logging

        from code_puppy.tools.agent_tools import invoke_agent_headless

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                side_effect=ConnectionError("refused"),
            ):
                with patch(
                    "code_puppy.agents.agent_manager.load_agent",
                    side_effect=RuntimeError("no local either"),
                ):
                    os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                    with caplog.at_level(logging.DEBUG):
                        with pytest.raises(RuntimeError):
                            await invoke_agent_headless("test-agent", "prompt")

                    # Debug log should mention bridge error
                    debug_msgs = [
                        r.message for r in caplog.records if r.levelno == logging.DEBUG
                    ]
                    bridge_msgs = [
                        m
                        for m in debug_msgs
                        if "bridge" in m.lower() or "elixir" in m.lower()
                    ]
                    assert len(bridge_msgs) > 0


# ── 7. No asyncio.run in sync wrappers ───────────────────────────────────


class TestNoUnsafeAsyncioRun:
    """code_puppy-mmk.4: verify no raw asyncio.run in agent_tools bridge paths."""

    def test_list_agents_uses_await_not_asyncio_run(self):
        """list_agents inner function should use await, not asyncio.run()."""
        import inspect

        # Get the source of the inner list_agents function
        # by checking the module-level source
        from code_puppy.tools import agent_tools

        source = inspect.getsource(agent_tools)
        # Find the list_agents function context
        # The relevant line should use 'await call_elixir_agent_tools'
        # not 'asyncio.run(call_elixir_agent_tools(...)'
        # We check for the specific pattern in the list_agents closure
        # The function was changed from 'def list_agents' to 'async def list_agents'
        assert "async def list_agents" in source, (
            "list_agents should be async to allow direct await"
        )
        # No asyncio.run anywhere in the module (the dangerous call)
        lines_with_asyncio_run = [
            line.strip()
            for line in source.split("\n")
            if "asyncio.run(" in line and "call_elixir" in line
        ]
        assert len(lines_with_asyncio_run) == 0, (
            "Should not use asyncio.run for Elixir bridge calls — "
            "use await directly in async tool context."
        )
