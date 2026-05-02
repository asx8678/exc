"""Tests for code_puppy.tui.launcher — env-flag behaviour and deprecation warning."""

from __future__ import annotations

import asyncio
import os
import warnings
from unittest.mock import AsyncMock, patch

import pytest

from code_puppy.tui.launcher import (
    emit_tui_deprecation_warning,
    is_tui_deprecated,
    is_tui_enabled,
    textual_interactive_mode,
)

# ---------------------------------------------------------------------------
# is_tui_enabled
# ---------------------------------------------------------------------------


class TestIsTuiEnabled:
    """CODE_PUPPY_TUI controls whether the TUI is opted-in."""

    def test_enabled_when_set(self) -> None:
        with patch.dict(os.environ, {"CODE_PUPPY_TUI": "1"}):
            assert is_tui_enabled() is True

    def test_disabled_by_default(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            # Ensure no leftover from other tests
            os.environ.pop("CODE_PUPPY_TUI", None)
            assert is_tui_enabled() is False

    def test_false_explicitly(self) -> None:
        with patch.dict(os.environ, {"CODE_PUPPY_TUI": "0"}):
            assert is_tui_enabled() is False

    def test_truthy_values(self) -> None:
        for val in ("1", "true", "yes", "on", "TRUE", "YES", "ON"):
            with patch.dict(os.environ, {"CODE_PUPPY_TUI": val}):
                assert is_tui_enabled() is True, (
                    f"CODE_PUPPY_TUI={val!r} should be True"
                )


# ---------------------------------------------------------------------------
# is_tui_deprecated
# ---------------------------------------------------------------------------


class TestIsTuiDeprecated:
    """PUP_TUI_DEPRECATED controls whether the deprecation warning fires."""

    def test_enabled_when_set(self) -> None:
        with patch.dict(os.environ, {"PUP_TUI_DEPRECATED": "1"}):
            assert is_tui_deprecated() is True

    def test_disabled_by_default(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("PUP_TUI_DEPRECATED", None)
            assert is_tui_deprecated() is False

    def test_uses_pup_prefix(self) -> None:
        """Legacy PUPPY_ prefix must NOT be accepted — PUP_ is canonical."""
        with patch.dict(os.environ, {"PUPPY_TUI_DEPRECATED": "1"}, clear=True):
            os.environ.pop("PUP_TUI_DEPRECATED", None)
            assert is_tui_deprecated() is False


# ---------------------------------------------------------------------------
# emit_tui_deprecation_warning
# ---------------------------------------------------------------------------


class TestEmitTuiDeprecationWarning:
    """The helper should write to stderr and issue a DeprecationWarning."""

    def test_prints_to_stderr(self, capsys: pytest.CaptureFixture[str]) -> None:
        # pytest.warns captures the DeprecationWarning so it never leaks
        # to the runner — this is the preferred hygiene pattern over
        # manual warnings.catch_warnings(simplefilter="ignore").
        with pytest.warns(DeprecationWarning, match="TUI"):
            emit_tui_deprecation_warning()
        captured = capsys.readouterr()
        assert captured.err  # something on stderr
        assert "deprecated" in captured.err.lower()
        # stdout must be untouched (Textual uses it)
        assert captured.out == ""

    def test_issues_deprecation_warning(self) -> None:
        with pytest.warns(DeprecationWarning, match="TUI") as record:
            emit_tui_deprecation_warning()
        assert len(record) == 1
        assert "TUI" in str(record[0].message)


# ---------------------------------------------------------------------------
# Interaction guard: no warning when TUI is not enabled
# ---------------------------------------------------------------------------


class TestInteractionGuard:
    """Even if PUP_TUI_DEPRECATED is set, we must NOT warn unless TUI is enabled."""

    def test_no_warning_when_tui_disabled(self) -> None:
        """Simulates app_runner logic: warn only when both flags are True."""
        with patch.dict(
            os.environ,
            {"PUP_TUI_DEPRECATED": "1"},
            clear=True,
        ):
            os.environ.pop("CODE_PUPPY_TUI", None)
            tui_on = is_tui_enabled()
            dep_on = is_tui_deprecated()
            # Guard: app_runner should only call emit when BOTH are True
            should_warn = tui_on and dep_on
            assert should_warn is False

    def test_warning_when_both_flags_true(self) -> None:
        with patch.dict(
            os.environ,
            {"CODE_PUPPY_TUI": "1", "PUP_TUI_DEPRECATED": "1"},
        ):
            should_warn = is_tui_enabled() and is_tui_deprecated()
            assert should_warn is True

    def test_no_warning_for_one_shot_prompt_mode(self) -> None:
        """One-shot (args.prompt) mode never enters TUI at all."""
        with patch.dict(
            os.environ,
            {"CODE_PUPPY_TUI": "1", "PUP_TUI_DEPRECATED": "1"},
        ):
            # app_runner uses: is_tui_enabled() and not args.prompt
            has_prompt = True  # simulates args.prompt being truthy
            should_warn = is_tui_enabled() and not has_prompt and is_tui_deprecated()
            assert should_warn is False


# ---------------------------------------------------------------------------
# Direct coverage for textual_interactive_mode()
# ---------------------------------------------------------------------------


class TestTextualInteractiveMode:
    """Verify the async entry point's warning + launch behaviour."""

    @staticmethod
    def _run(coro):
        """Run an async coroutine in a sync test (no pytest-asyncio dependency)."""
        return asyncio.run(coro)

    def test_warns_before_launch_when_deprecated(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """When PUP_TUI_DEPRECATED=1, warning fires *before* app.run_async()."""
        with patch.dict(os.environ, {"PUP_TUI_DEPRECATED": "1"}):
            with patch("code_puppy.tui.app.CodePuppyApp") as MockApp:
                mock_instance = MockApp.return_value
                mock_instance.run_async = AsyncMock()

                with pytest.warns(DeprecationWarning, match="TUI"):
                    self._run(textual_interactive_mode())

                # App was still launched despite deprecation
                mock_instance.run_async.assert_awaited_once()

        # Stderr got the user-facing message too
        captured = capsys.readouterr()
        assert "deprecated" in captured.err.lower()

    def test_no_warning_when_not_deprecated(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """When PUP_TUI_DEPRECATED is unset, no warning is emitted."""
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("PUP_TUI_DEPRECATED", None)
            with patch("code_puppy.tui.app.CodePuppyApp") as MockApp:
                mock_instance = MockApp.return_value
                mock_instance.run_async = AsyncMock()

                with warnings.catch_warnings(record=True) as w:
                    warnings.simplefilter("always")
                    self._run(textual_interactive_mode())
                    dep = [x for x in w if issubclass(x.category, DeprecationWarning)]
                    assert len(dep) == 0

                # App still launches normally
                mock_instance.run_async.assert_awaited_once()

        captured = capsys.readouterr()
        assert captured.err == ""

    def test_initial_command_forwarded(self) -> None:
        """initial_command is set on the app instance before run_async()."""
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("PUP_TUI_DEPRECATED", None)
            with patch("code_puppy.tui.app.CodePuppyApp") as MockApp:
                mock_instance = MockApp.return_value
                mock_instance.run_async = AsyncMock()

                self._run(textual_interactive_mode(initial_command="/help"))

                assert mock_instance._initial_command == "/help"
                mock_instance.run_async.assert_awaited_once()
