"""Regression tests for Python bridge-worker mode (code_puppy-djs.3)."""

from __future__ import annotations

import argparse
import importlib
import json
import os
import subprocess
import sys
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path
from types import ModuleType
from typing import Any
from unittest.mock import Mock

import pytest


def _encode_bridge_frame(message: dict[str, Any]) -> bytes:
    """Encode one Content-Length framed JSON-RPC message."""
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8") + body


def _decode_bridge_frames(data: bytes) -> list[dict[str, Any]]:
    """Strictly decode Content-Length frames from bridge stdout."""
    messages: list[dict[str, Any]] = []
    offset = 0

    while offset < len(data):
        header_end = data.find(b"\r\n\r\n", offset)
        assert header_end != -1, f"unframed stdout bytes at offset {offset}: {data!r}"

        header = data[offset:header_end].decode("utf-8")
        assert header.lower().startswith("content-length:"), (
            f"non-protocol stdout before frame body: {header!r}"
        )

        content_length = int(header.split(":", 1)[1].strip())
        body_start = header_end + 4
        body_end = body_start + content_length
        assert body_end <= len(data), "truncated bridge stdout frame"

        body = data[body_start:body_end]
        messages.append(json.loads(body.decode("utf-8")))
        offset = body_end

    return messages


def _bridge_subprocess_context(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    """Return cwd/env for bridge-mode subprocess lifecycle tests."""
    repo_root = Path(__file__).resolve().parents[1]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(repo_root) + os.pathsep + env.get("PYTHONPATH", "")
    env["PUP_EX_HOME"] = str(tmp_path / "pup-home")
    return repo_root, env


@contextmanager
def _without_modules(module_names: tuple[str, ...]) -> Iterator[None]:
    """Temporarily remove modules from ``sys.modules`` and restore them later."""
    saved: dict[str, ModuleType] = {}
    missing = object()
    original: dict[str, ModuleType | object] = {}
    parent_attrs: dict[str, tuple[ModuleType, str, object]] = {}

    for name in module_names:
        original[name] = sys.modules.get(name, missing)
        module = sys.modules.pop(name, None)
        if module is not None:
            saved[name] = module

        if "." not in name:
            continue
        parent_name, attr_name = name.rsplit(".", 1)
        parent = sys.modules.get(parent_name)
        if parent is not None and hasattr(parent, attr_name):
            parent_attrs[name] = (parent, attr_name, getattr(parent, attr_name))
            delattr(parent, attr_name)

    try:
        yield
    finally:
        for name in module_names:
            sys.modules.pop(name, None)
            previous = original[name]
            if previous is not missing:
                sys.modules[name] = previous  # type: ignore[assignment]
        for parent, attr_name, value in parent_attrs.values():
            setattr(parent, attr_name, value)
        # Keep references alive until restoration is complete.
        saved.clear()


@asynccontextmanager
async def _patched_app_runner_dependencies(
    monkeypatch: pytest.MonkeyPatch,
) -> AsyncIterator[tuple[Mock, Mock]]:
    """Patch AppRunner's runtime dependencies so run() is unit-testable.

    The production method intentionally imports a lot of runtime infrastructure.
    These patches keep this test focused on bridge-mode dispatch invariants:
    no human renderers, startup/shutdown callbacks still fire, and bridge mode
    owns the main event-loop wait.
    """
    import code_puppy.keymap as keymap_module
    from code_puppy import callbacks, config, config_package, workflow_state

    startup = Mock()
    shutdown = Mock()

    async def on_startup() -> None:
        startup()

    async def on_shutdown() -> None:
        shutdown()

    monkeypatch.setattr(callbacks, "on_startup", on_startup)
    monkeypatch.setattr(callbacks, "on_shutdown", on_shutdown)
    monkeypatch.setattr(callbacks, "get_callbacks", lambda _phase: ())
    monkeypatch.setattr(
        config,
        "ensure_config_exists",
        Mock(
            side_effect=AssertionError("config onboarding must not run in bridge mode")
        ),
    )
    monkeypatch.setattr(config, "initialize_command_history_file", lambda: None)
    monkeypatch.setattr(config, "get_use_dbos", lambda: False)
    monkeypatch.setattr(
        config_package, "env_bool", lambda _name, default=False: default
    )
    monkeypatch.setattr(keymap_module, "validate_cancel_agent_key", lambda: None)
    monkeypatch.setattr(workflow_state, "register_callback_handlers", lambda: None)

    yield startup, shutdown


class TestBridgeModeSubprocessLifecycle:
    """End-to-end bridge worker lifecycle regressions."""

    def test_bridge_mode_exits_when_stdin_is_closed(self, tmp_path: Path) -> None:
        """Closed stdin must behave like shutdown, not infinite bridge purgatory."""
        repo_root, env = _bridge_subprocess_context(tmp_path)

        proc = subprocess.Popen(
            [sys.executable, "-m", "code_puppy", "--bridge-mode"],
            cwd=repo_root,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            stdout, stderr = proc.communicate(input=b"", timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate(timeout=2)
            pytest.fail(
                "bridge mode did not exit after stdin EOF\n"
                f"stdout={stdout!r}\nstderr={stderr.decode('utf-8', 'replace')}"
            )

        assert proc.returncode == 0, stderr.decode("utf-8", "replace")

        messages = _decode_bridge_frames(stdout)
        methods = [message.get("method") for message in messages]
        assert methods in (["bridge.ready"], ["bridge.ready", "bridge.closing"])

    def test_bridge_mode_exits_after_exit_request(self, tmp_path: Path) -> None:
        """An explicit bridge exit request must stop the AppRunner wait."""
        repo_root, env = _bridge_subprocess_context(tmp_path)
        exit_request = _encode_bridge_frame(
            {
                "jsonrpc": "2.0",
                "id": "exit-subprocess",
                "method": "exit",
                "params": {"reason": "test-exit"},
            }
        )

        proc = subprocess.Popen(
            [sys.executable, "-m", "code_puppy", "--bridge-mode"],
            cwd=repo_root,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            stdout, stderr = proc.communicate(input=exit_request, timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate(timeout=2)
            pytest.fail(
                "bridge mode did not exit after exit request\n"
                f"stdout={stdout!r}\nstderr={stderr.decode('utf-8', 'replace')}"
            )

        assert proc.returncode == 0, stderr.decode("utf-8", "replace")

        messages = _decode_bridge_frames(stdout)
        assert messages[0].get("method") == "bridge.ready"
        exit_responses = [
            message for message in messages if message.get("id") == "exit-subprocess"
        ]
        assert exit_responses
        assert exit_responses[0]["result"]["status"] == "exiting"
        assert exit_responses[0]["result"]["reason"] == "test-exit"

    def test_bridge_mode_exits_when_stdin_is_devnull(self, tmp_path: Path) -> None:
        """DEVNULL stdin must not hang on deferred read-pipe registration errors."""
        repo_root, env = _bridge_subprocess_context(tmp_path)

        proc = subprocess.Popen(
            [sys.executable, "-m", "code_puppy", "--bridge-mode"],
            cwd=repo_root,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            stdout, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate(timeout=2)
            pytest.fail(
                "bridge mode did not exit with DEVNULL stdin\n"
                f"stdout={stdout!r}\nstderr={stderr.decode('utf-8', 'replace')}"
            )

        stderr_text = stderr.decode("utf-8", "replace")
        assert proc.returncode == 0, stderr_text
        assert (
            "Exception in callback _UnixReadPipeTransport._add_reader"
            not in stderr_text
        )

        messages = _decode_bridge_frames(stdout)
        methods = [message.get("method") for message in messages]
        assert methods in (["bridge.ready"], ["bridge.ready", "bridge.closing"])


class TestCliRunnerBridgeMode:
    """Regression coverage for the cli_runner import-order race."""

    def test_main_entry_sets_bridge_env_before_config_or_bridge_import(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """``pup --bridge-mode`` sets CODE_PUPPY_BRIDGE before full imports.

        The elixir_bridge package freezes BRIDGE_ENABLED at import time. This
        test fails if cli_runner imports code_puppy.config (or the bridge) before
        main_entry() has a chance to inspect argv and set CODE_PUPPY_BRIDGE.
        """
        monkeypatch.delenv("CODE_PUPPY_BRIDGE", raising=False)
        monkeypatch.setattr(sys, "argv", ["pup", "--bridge-mode"])

        with _without_modules(
            (
                "code_puppy.cli_runner",
                "code_puppy.config",
                "code_puppy.plugins.elixir_bridge",
            )
        ):
            cli_runner = importlib.import_module("code_puppy.cli_runner")
            assert "code_puppy.config" not in sys.modules
            assert "code_puppy.plugins.elixir_bridge" not in sys.modules

            def fake_run_full() -> None:
                assert os.environ["CODE_PUPPY_BRIDGE"] == "1"
                assert "code_puppy.config" not in sys.modules

                bridge = importlib.import_module("code_puppy.plugins.elixir_bridge")
                assert bridge.BRIDGE_ENABLED is True

            monkeypatch.setattr(cli_runner, "_run_full", fake_run_full)

            cli_runner.main_entry()

    def test_main_entry_flag_overrides_existing_falsey_bridge_env(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """``pup --bridge-mode`` must win over existing CODE_PUPPY_BRIDGE=0."""
        monkeypatch.setenv("CODE_PUPPY_BRIDGE", "0")
        monkeypatch.setattr(sys, "argv", ["pup", "--bridge-mode"])

        with _without_modules(
            (
                "code_puppy.cli_runner",
                "code_puppy.config",
                "code_puppy.plugins.elixir_bridge",
            )
        ):
            cli_runner = importlib.import_module("code_puppy.cli_runner")

            def fake_run_full() -> None:
                assert os.environ["CODE_PUPPY_BRIDGE"] == "1"

            monkeypatch.setattr(cli_runner, "_run_full", fake_run_full)

            cli_runner.main_entry()

        assert os.environ["CODE_PUPPY_BRIDGE"] == "1"

    def test_main_entry_preserves_existing_bridge_env(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """``CODE_PUPPY_BRIDGE=1 pup`` reaches full runtime already enabled."""
        monkeypatch.setenv("CODE_PUPPY_BRIDGE", "1")
        monkeypatch.setattr(sys, "argv", ["pup"])

        with _without_modules(
            (
                "code_puppy.cli_runner",
                "code_puppy.config",
                "code_puppy.plugins.elixir_bridge",
            )
        ):
            cli_runner = importlib.import_module("code_puppy.cli_runner")

            def fake_run_full() -> None:
                assert os.environ["CODE_PUPPY_BRIDGE"] == "1"
                bridge = importlib.import_module("code_puppy.plugins.elixir_bridge")
                assert bridge.BRIDGE_ENABLED is True

            monkeypatch.setattr(cli_runner, "_run_full", fake_run_full)

            cli_runner.main_entry()

    def test_help_fast_path_does_not_set_bridge_env(
        self, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """The --help fast path remains side-effect-light."""
        monkeypatch.delenv("CODE_PUPPY_BRIDGE", raising=False)
        monkeypatch.setattr(sys, "argv", ["pup", "--help", "--bridge-mode"])

        import code_puppy.cli_runner as cli_runner

        cli_runner.main_entry()

        captured = capsys.readouterr()
        assert "Usage: pup" in captured.out
        assert "CODE_PUPPY_BRIDGE" not in os.environ


class TestAppRunnerBridgeMode:
    """Bridge-mode dispatch and stdout-cleanliness guards in AppRunner."""

    @pytest.mark.asyncio
    async def test_bridge_mode_skips_human_renderers_and_dispatches_bridge_wait(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Bridge mode must not start renderers, logo, signals, REPL, or TUI."""
        from code_puppy.app_runner import AppRunner

        monkeypatch.delenv("CODE_PUPPY_BRIDGE", raising=False)
        runner = AppRunner()
        args = argparse.Namespace(
            bridge_mode=True,
            prompt=None,
            command=[],
            model=None,
            agent=None,
        )

        bridge_waits = 0

        async def fake_run_bridge_mode() -> None:
            nonlocal bridge_waits
            bridge_waits += 1

        monkeypatch.setattr(runner, "parse_args", lambda: args)
        monkeypatch.setattr(
            runner,
            "setup_renderers",
            Mock(side_effect=AssertionError("renderers must stay off in bridge mode")),
        )
        monkeypatch.setattr(
            runner,
            "show_logo",
            Mock(side_effect=AssertionError("logo must stay off in bridge mode")),
        )
        monkeypatch.setattr(
            runner,
            "setup_signals",
            Mock(side_effect=AssertionError("signals must stay off in bridge mode")),
        )
        monkeypatch.setattr(runner, "load_api_keys", lambda: None)
        monkeypatch.setattr(runner, "configure_agent", lambda _args: None)
        monkeypatch.setattr(runner, "_run_bridge_mode", fake_run_bridge_mode)

        async with _patched_app_runner_dependencies(monkeypatch) as (
            startup,
            shutdown,
        ):
            await runner.run()

        assert os.environ["CODE_PUPPY_BRIDGE"] == "1"
        assert bridge_waits == 1
        startup.assert_called_once_with()
        shutdown.assert_called_once_with()

    @pytest.mark.asyncio
    async def test_run_bridge_mode_uses_public_bridge_shutdown_api(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The bridge wait delegates to the public plugin lifecycle API."""
        import code_puppy.plugins.elixir_bridge as bridge
        from code_puppy.app_runner import AppRunner

        bridge_waits = 0

        async def fake_await_shutdown() -> None:
            nonlocal bridge_waits
            bridge_waits += 1

        monkeypatch.setattr(bridge, "await_shutdown", fake_await_shutdown)

        await AppRunner()._run_bridge_mode()

        assert bridge_waits == 1

    @pytest.mark.asyncio
    async def test_run_bridge_mode_raises_when_bridge_shutdown_api_not_active(
        self, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Bridge mode must fail loudly if the bridge plugin did not activate."""
        import code_puppy.plugins.elixir_bridge as bridge
        from code_puppy.app_runner import AppRunner

        async def fake_await_shutdown() -> None:
            raise RuntimeError("bridge plugin not activated")

        monkeypatch.setattr(bridge, "await_shutdown", fake_await_shutdown)

        with pytest.raises(RuntimeError, match="bridge plugin not activated"):
            await AppRunner()._run_bridge_mode()

        captured = capsys.readouterr()
        assert "ERROR" in captured.err
        assert captured.out == ""
