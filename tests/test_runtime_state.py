"""Tests for code_puppy.runtime_state Python wrapper (code_puppy-ctj.4).

Covers:
- Cache getter/setter transport routes
- Cache invalidation transport routes
- finalize_autosave_session transport route + degraded mode
- puppy_rules_cache parity with Elixir
- All methods fall back gracefully in degraded mode (PUP_ALLOW_ELIXIR_DEGRADED=1)
"""

from __future__ import annotations

import os
from unittest.mock import MagicMock, patch

# We mock the transport since these tests verify the Python→Elixir routing,
# not the Elixir GenServer itself.


def _mock_transport():
    """Create a mock transport with _send_request."""
    transport = MagicMock()
    return transport


# ---------------------------------------------------------------------------
# Cache Getter / Setter Transport Tests
# ---------------------------------------------------------------------------


class TestCacheGetterSetterTransport:
    """Verify Python wrappers route cache get/set to the correct transport method."""

    def test_get_cached_system_prompt(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"cached_system_prompt": "hello"}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            assert runtime_state.get_cached_system_prompt() == "hello"
            transport._send_request.assert_called_once_with(
                "runtime_get_cached_system_prompt", {}
            )

    def test_set_cached_system_prompt(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.set_cached_system_prompt("world")
            transport._send_request.assert_called_once_with(
                "runtime_set_cached_system_prompt", {"prompt": "world"}
            )

    def test_get_cached_tool_defs(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"cached_tool_defs": [{"name": "t"}]}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            assert runtime_state.get_cached_tool_defs() == [{"name": "t"}]
            transport._send_request.assert_called_once_with(
                "runtime_get_cached_tool_defs", {}
            )

    def test_set_cached_tool_defs(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.set_cached_tool_defs([{"name": "x"}])
            transport._send_request.assert_called_once_with(
                "runtime_set_cached_tool_defs", {"tool_defs": [{"name": "x"}]}
            )

    def test_get_model_name_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"model_name_cache": "gpt-4o"}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            assert runtime_state.get_model_name_cache() == "gpt-4o"

    def test_set_model_name_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.set_model_name_cache("claude-3")
            transport._send_request.assert_called_once_with(
                "runtime_set_model_name_cache", {"model_name": "claude-3"}
            )

    def test_get_delayed_compaction_requested(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"delayed_compaction_requested": True}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            assert runtime_state.get_delayed_compaction_requested() is True

    def test_set_delayed_compaction_requested(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.set_delayed_compaction_requested(True)
            transport._send_request.assert_called_once_with(
                "runtime_set_delayed_compaction_requested", {"value": True}
            )

    def test_get_tool_ids_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"tool_ids_cache": {"a": "b"}}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            assert runtime_state.get_tool_ids_cache() == {"a": "b"}

    def test_set_tool_ids_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.set_tool_ids_cache({"x": "y"})
            transport._send_request.assert_called_once_with(
                "runtime_set_tool_ids_cache", {"cache": {"x": "y"}}
            )

    def test_get_cached_context_overhead(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"cached_context_overhead": 42}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            assert runtime_state.get_cached_context_overhead() == 42

    def test_set_cached_context_overhead(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.set_cached_context_overhead(99)
            transport._send_request.assert_called_once_with(
                "runtime_set_cached_context_overhead", {"value": 99}
            )

    def test_get_resolved_model_components_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {
            "resolved_model_components_cache": {"provider": "anthropic"}
        }
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            assert runtime_state.get_resolved_model_components_cache() == {
                "provider": "anthropic"
            }

    def test_set_resolved_model_components_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.set_resolved_model_components_cache({"k": "v"})
            transport._send_request.assert_called_once_with(
                "runtime_set_resolved_model_components_cache", {"cache": {"k": "v"}}
            )

    def test_get_puppy_rules_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"puppy_rules_cache": "AGENTS.md"}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            assert runtime_state.get_puppy_rules_cache() == "AGENTS.md"

    def test_set_puppy_rules_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.set_puppy_rules_cache("rules content")
            transport._send_request.assert_called_once_with(
                "runtime_set_puppy_rules_cache", {"rules": "rules content"}
            )


# ---------------------------------------------------------------------------
# Cache Invalidation Transport Tests
# ---------------------------------------------------------------------------


class TestCacheInvalidationTransport:
    """Verify cache invalidation Python wrappers route to correct transport method."""

    def test_invalidate_caches(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"reset": True}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.invalidate_caches()
            transport._send_request.assert_called_once_with(
                "runtime_invalidate_caches", {}
            )

    def test_invalidate_all_token_caches(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"reset": True}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.invalidate_all_token_caches()
            transport._send_request.assert_called_once_with(
                "runtime_invalidate_all_token_caches", {}
            )

    def test_invalidate_system_prompt_cache(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"reset": True}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            runtime_state.invalidate_system_prompt_cache()
            transport._send_request.assert_called_once_with(
                "runtime_invalidate_system_prompt_cache", {}
            )


# ---------------------------------------------------------------------------
# finalize_autosave_session Transport Tests
# ---------------------------------------------------------------------------


class TestFinalizeAutosaveSessionTransport:
    """Verify finalize_autosave_session routes correctly and falls back gracefully."""

    def test_finalize_via_transport(self):
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"autosave_id": "20250101_120000"}
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch("code_puppy.config.auto_save_session_if_enabled") as mock_save:
                result = runtime_state.finalize_autosave_session()
                assert result == "20250101_120000"
                # Python autosave is called before transport finalize/rotation
                mock_save.assert_called_once()
                transport._send_request.assert_called_once_with(
                    "runtime_finalize_autosave_session", {}
                )

    def test_finalize_normal_path_calls_python_autosave_before_transport(self):
        """In the normal (non-degraded) path, Python auto_save must be
        invoked BEFORE the transport finalize/rotation call.

        This is the parity guarantee: whether Elixir is available or not,
        the Python-side autosave callback fires first so the snapshot
        is persisted before the session ID rotates.
        """
        from code_puppy import runtime_state

        transport = _mock_transport()
        transport._send_request.return_value = {"autosave_id": "20250101_120000"}
        call_order = []

        def _record_transport_call(method, params):
            call_order.append(("transport", method))
            return {"autosave_id": "20250101_120000"}

        transport._send_request.side_effect = _record_transport_call

        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch(
                "code_puppy.config.auto_save_session_if_enabled",
                side_effect=lambda: call_order.append(("python_autosave", None)),
            ) as mock_save:
                result = runtime_state.finalize_autosave_session()
                assert result == "20250101_120000"
                # Python autosave must appear before transport finalize
                mock_save.assert_called_once()
                assert call_order[0] == ("python_autosave", None), (
                    f"Expected python_autosave first, got: {call_order}"
                )
                assert call_order[1] == (
                    "transport",
                    "runtime_finalize_autosave_session",
                ), f"Expected transport finalize second, got: {call_order}"

    def test_finalize_degraded_mode_calls_python_autosave(self):
        """In degraded mode, finalize still calls auto_save before rotation."""
        from code_puppy import runtime_state
        from code_puppy.elixir_transport import ElixirTransportError

        transport = _mock_transport()
        transport._send_request.side_effect = ElixirTransportError("down")

        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch.dict(os.environ, {"PUP_ALLOW_ELIXIR_DEGRADED": "1"}):
                with patch(
                    "code_puppy.config.auto_save_session_if_enabled"
                ) as mock_save:
                    with patch(
                        "code_puppy.runtime_state.rotate_autosave_id",
                        return_value="20250101_120000",
                    ):
                        result = runtime_state.finalize_autosave_session()
                        # Save must be called before rotation
                        mock_save.assert_called_once()
                        assert "20250101" in result


# ---------------------------------------------------------------------------
# Degraded Mode Fallback Tests
# ---------------------------------------------------------------------------


class TestDegradedModeFallback:
    """Verify all new methods fall back gracefully in degraded mode."""

    def test_get_cached_system_prompt_degraded(self):
        from code_puppy import runtime_state
        from code_puppy.elixir_transport import ElixirTransportError

        transport = _mock_transport()
        transport._send_request.side_effect = ElixirTransportError("down")
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch.dict(os.environ, {"PUP_ALLOW_ELIXIR_DEGRADED": "1"}):
                result = runtime_state.get_cached_system_prompt()
                assert result is None

    def test_get_puppy_rules_cache_degraded(self):
        from code_puppy import runtime_state
        from code_puppy.elixir_transport import ElixirTransportError

        transport = _mock_transport()
        transport._send_request.side_effect = ElixirTransportError("down")
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch.dict(os.environ, {"PUP_ALLOW_ELIXIR_DEGRADED": "1"}):
                result = runtime_state.get_puppy_rules_cache()
                assert result is None

    def test_set_puppy_rules_cache_degraded(self):
        from code_puppy import runtime_state
        from code_puppy.elixir_transport import ElixirTransportError

        transport = _mock_transport()
        transport._send_request.side_effect = ElixirTransportError("down")
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch.dict(os.environ, {"PUP_ALLOW_ELIXIR_DEGRADED": "1"}):
                # Should not raise
                runtime_state.set_puppy_rules_cache("test")

    def test_invalidate_caches_degraded(self):
        from code_puppy import runtime_state
        from code_puppy.elixir_transport import ElixirTransportError

        transport = _mock_transport()
        transport._send_request.side_effect = ElixirTransportError("down")
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch.dict(os.environ, {"PUP_ALLOW_ELIXIR_DEGRADED": "1"}):
                # Should not raise
                runtime_state.invalidate_caches()

    def test_invalidate_all_token_caches_degraded(self):
        from code_puppy import runtime_state
        from code_puppy.elixir_transport import ElixirTransportError

        transport = _mock_transport()
        transport._send_request.side_effect = ElixirTransportError("down")
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch.dict(os.environ, {"PUP_ALLOW_ELIXIR_DEGRADED": "1"}):
                # Should not raise
                runtime_state.invalidate_all_token_caches()

    def test_invalidate_system_prompt_cache_degraded(self):
        from code_puppy import runtime_state
        from code_puppy.elixir_transport import ElixirTransportError

        transport = _mock_transport()
        transport._send_request.side_effect = ElixirTransportError("down")
        with patch("code_puppy.runtime_state._get_transport", return_value=transport):
            with patch.dict(os.environ, {"PUP_ALLOW_ELIXIR_DEGRADED": "1"}):
                # Should not raise
                runtime_state.invalidate_system_prompt_cache()
