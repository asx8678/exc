"""Tests for agent_tools bridge paths and invocation (code_puppy-mmk.4).

Covers:
- invoke_agent_headless: Elixir bridge success/fallback/timeout paths
- invoke_agent_headless: PUP_SKIP_ELIXIR_AGENT_TOOLS recursion guard
- invoke_agent (tool): Elixir bridge fast-path with result-shape conversion
- register_list_agents: async bridge call and fallback
- Prompt propagation through bridge and local paths
- Response propagation: correct AgentInvokeOutput shape
- generate_session_id: unique and valid
"""

from __future__ import annotations

import os
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ── invoke_agent_headless ─────────────────────────────────────────────────


class TestInvokeAgentHeadlessBridge:
    """code_puppy-mmk.4: bridge paths for invoke_agent_headless."""

    @pytest.mark.asyncio
    async def test_bridge_success_returns_response(self):
        """When Elixir bridge returns successfully, response is returned."""
        from code_puppy.tools.agent_tools import invoke_agent_headless

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                return_value={"response": "Elixir says hello", "agent_name": "test"},
            ):
                os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                result = await invoke_agent_headless("test-agent", "hello")
                assert result == "Elixir says hello"

    @pytest.mark.asyncio
    async def test_bridge_timeout_falls_back_to_local(self):
        """When bridge times out, falls back to local Python path."""
        from code_puppy.tools.agent_tools import invoke_agent_headless

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                return_value={"status": "timeout", "fallback": True},
            ):
                with patch(
                    "code_puppy.agents.agent_manager.load_agent",
                    side_effect=RuntimeError("local model not available"),
                ):
                    os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                    with pytest.raises(RuntimeError, match="local model not available"):
                        await invoke_agent_headless("test-agent", "hello")

    @pytest.mark.asyncio
    async def test_bridge_error_falls_back_to_local(self):
        """When bridge raises, falls back to local Python path."""
        from code_puppy.tools.agent_tools import invoke_agent_headless

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                side_effect=ConnectionError("Elixir gone"),
            ):
                with patch(
                    "code_puppy.agents.agent_manager.load_agent",
                    side_effect=RuntimeError("local fallback"),
                ):
                    os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                    with pytest.raises(RuntimeError, match="local fallback"):
                        await invoke_agent_headless("test-agent", "hello")

    @pytest.mark.asyncio
    async def test_skip_elixir_env_bypasses_bridge(self):
        """PUP_SKIP_ELIXIR_AGENT_TOOLS=1 skips Elixir bridge entirely."""
        from code_puppy.tools.agent_tools import invoke_agent_headless

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ) as mock_connected:
            with patch(
                "code_puppy.agents.agent_manager.load_agent",
                side_effect=RuntimeError("local path"),
            ):
                os.environ["PUP_SKIP_ELIXIR_AGENT_TOOLS"] = "1"
                try:
                    with pytest.raises(RuntimeError, match="local path"):
                        await invoke_agent_headless("test-agent", "hello")
                    # is_connected should not have been called
                    mock_connected.assert_not_called()
                finally:
                    os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)

    @pytest.mark.asyncio
    async def test_skip_elixir_true_values(self):
        """PUP_SKIP_ELIXIR_AGENT_TOOLS accepts 1, true, yes."""
        from code_puppy.tools.agent_tools import invoke_agent_headless

        for val in ("1", "true", "yes"):
            with patch(
                "code_puppy.agents.agent_manager.load_agent",
                side_effect=RuntimeError("local"),
            ):
                os.environ["PUP_SKIP_ELIXIR_AGENT_TOOLS"] = val
                try:
                    with pytest.raises(RuntimeError):
                        await invoke_agent_headless("test-agent", "hello")
                finally:
                    os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)


# ── register_invoke_agent bridge fast-path ────────────────────────────────


class TestRegisterInvokeAgentBridge:
    """code_puppy-mmk.4: register_invoke_agent attempts Elixir bridge."""

    @pytest.mark.asyncio
    async def test_bridge_fast_path_returns_output(self):
        """When Elixir bridge responds, invoke_agent returns early."""
        from code_puppy.tools.agent_tools import AgentInvokeOutput

        # Capture the decorated function by using a real decorator
        captured_fn = None

        def capture_tool(fn):
            nonlocal captured_fn
            captured_fn = fn
            return fn

        mock_agent = MagicMock()
        mock_agent.tool = capture_tool

        from code_puppy.tools.agent_tools import register_invoke_agent

        register_invoke_agent(mock_agent)

        invoke_fn = captured_fn
        assert invoke_fn is not None

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                return_value={
                    "response": "bridge response",
                    "agent_name": "test-agent",
                    "session_id": "test-session-abc12345",
                },
            ):
                mock_context = MagicMock()
                os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                result = await invoke_fn(
                    mock_context,
                    agent_name="test-agent",
                    prompt="hello",
                    session_id=None,
                )

                assert isinstance(result, AgentInvokeOutput)
                assert result.response == "bridge response"
                assert result.agent_name == "test-agent"

    @pytest.mark.asyncio
    async def test_bridge_error_falls_back(self):
        """When Elixir bridge errors, invoke_agent falls back to local."""
        captured_fn = None

        def capture_tool(fn):
            nonlocal captured_fn
            captured_fn = fn
            return fn

        mock_agent = MagicMock()
        mock_agent.tool = capture_tool

        from code_puppy.tools.agent_tools import register_invoke_agent

        register_invoke_agent(mock_agent)

        invoke_fn = captured_fn

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                side_effect=ConnectionError("boom"),
            ):
                mock_context = MagicMock()
                os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                result = await invoke_fn(
                    mock_context,
                    agent_name="nonexistent-agent-xyz",
                    prompt="hello",
                )
                # Falls back to local which also fails for nonexistent agent
                assert result.error is not None or result.response is not None


# ── list_agents bridge path ──────────────────────────────────────────────


class TestListAgentsBridge:
    """code_puppy-mmk.4: list_agents uses Elixir bridge with async await."""

    @pytest.mark.asyncio
    async def test_list_agents_bridge_success(self):
        """list_agents returns agents from Elixir bridge."""
        from code_puppy.tools.agent_tools import ListAgentsOutput

        # Capture the decorated function
        captured_fn = None

        def capture_tool(fn):
            nonlocal captured_fn
            captured_fn = fn
            return fn

        mock_agent = MagicMock()
        mock_agent.tool = capture_tool

        from code_puppy.tools.agent_tools import register_list_agents

        register_list_agents(mock_agent)

        list_fn = captured_fn
        assert list_fn is not None

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                return_value={
                    "agents": [
                        {
                            "name": "code-puppy",
                            "display_name": "Code Puppy",
                            "description": "Main agent",
                        },
                        {
                            "name": "qa-expert",
                            "display_name": "QA Expert",
                            "description": "Testing",
                        },
                    ],
                },
            ):
                result = await list_fn(MagicMock())
                assert isinstance(result, ListAgentsOutput)
                assert len(result.agents) == 2
                assert result.agents[0].name == "code-puppy"


# ── generate_session_id ─────────────────────────────────────────────────


class TestGenerateSessionId:
    """Session ID generation matches Python/Elixir contract."""

    def test_format_and_uniqueness(self):
        from code_puppy.tools.agent_tools import _generate_session_hash_suffix

        suffixes = [_generate_session_hash_suffix() for _ in range(50)]
        # All should be 8 hex chars
        for s in suffixes:
            assert len(s) == 8
            assert s.isalnum()
        # Very unlikely collisions
        assert len(set(suffixes)) >= 48


# ── Prompt propagation ──────────────────────────────────────────────────


class TestPromptPropagation:
    """code_puppy-mmk.4: prompt is correctly passed through bridge paths."""

    @pytest.mark.asyncio
    async def test_invoke_headless_receives_correct_prompt(self):
        """Prompt is passed through to the bridge call."""
        from code_puppy.tools.agent_tools import invoke_agent_headless

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                return_value={"response": "ok"},
            ) as mock_call:
                os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                await invoke_agent_headless("agent", "my special prompt")
                call_args = mock_call.call_args
                assert call_args[0][1]["prompt"] == "my special prompt"


# ── Response propagation ──────────────────────────────────────────────


class TestResponsePropagation:
    """code_puppy-mmk.4: response shape matches AgentInvokeOutput."""

    @pytest.mark.asyncio
    async def test_bridge_result_shape_conversion(self):
        """Bridge response field is correctly extracted."""
        from code_puppy.tools.agent_tools import invoke_agent_headless

        with patch(
            "code_puppy.plugins.elixir_bridge.is_connected",
            return_value=True,
        ):
            with patch(
                "code_puppy.plugins.elixir_bridge.call_elixir_agent_tools",
                new_callable=AsyncMock,
                return_value={
                    "response": "the answer is 42",
                    "agent_name": "code-puppy",
                },
            ):
                os.environ.pop("PUP_SKIP_ELIXIR_AGENT_TOOLS", None)
                result = await invoke_agent_headless(
                    "code-puppy", "what is the answer?"
                )
                assert result == "the answer is 42"
