"""Tests for Elixir bridge Content-Length framed stdin reads."""

from __future__ import annotations

import asyncio
import io
import json
from typing import Any

import pytest

from code_puppy.plugins.elixir_bridge import register_callbacks as bridge_callbacks
from code_puppy.plugins.elixir_bridge.bridge_controller import BridgeController


class _FakeReadTransport:
    """Tiny read transport for StreamReaderProtocol tests."""

    def close(self) -> None:
        return None

    def get_extra_info(self, name: str, default: Any = None) -> Any:
        return default

    def is_closing(self) -> bool:
        return False

    def pause_reading(self) -> None:
        return None

    def resume_reading(self) -> None:
        return None


class _FakeStdout:
    """Stdout double with a binary buffer for framed response capture."""

    def __init__(self) -> None:
        self.buffer = io.BytesIO()

    def flush(self) -> None:
        return None

    def write(self, text: str) -> int:
        return len(text)


def _frame(message: dict[str, Any]) -> bytes:
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8")
    return header + body


def _decode_frames(data: bytes) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    offset = 0

    while offset < len(data):
        header_end = data.index(b"\r\n\r\n", offset)
        header = data[offset:header_end].decode("utf-8")
        assert header.lower().startswith("content-length:")

        content_length = int(header.split(":", 1)[1].strip())
        body_start = header_end + 4
        body_end = body_start + content_length
        body = data[body_start:body_end]

        assert len(body) == content_length
        messages.append(json.loads(body.decode("utf-8")))
        offset = body_end

    return messages


@pytest.mark.asyncio
async def test_read_framed_message_awaits_streamreader_until_full_body() -> None:
    """The reader must await StreamReader reads instead of handling coroutines."""
    reader = asyncio.StreamReader()
    request = {
        "jsonrpc": "2.0",
        "id": "ping-async-read",
        "method": "ping",
        "params": {"note": "split-body"},
    }
    frame = _frame(request)
    header_end = frame.index(b"\r\n\r\n") + 4
    partial_frame = frame[: header_end + 5]

    read_task = asyncio.create_task(bridge_callbacks._read_framed_message(reader))
    await asyncio.sleep(0)
    assert not read_task.done()

    reader.feed_data(partial_frame)
    await asyncio.sleep(0)
    assert not read_task.done()

    reader.feed_data(frame[len(partial_frame) :])

    assert await asyncio.wait_for(read_task, timeout=1) == request


@pytest.mark.asyncio
async def test_read_framed_message_logs_truncated_body(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    logs: list[tuple[str, str]] = []

    def capture_log(message: str, level: str = "info") -> None:
        logs.append((level, message))

    monkeypatch.setattr(bridge_callbacks, "_log_bridge", capture_log)

    reader = asyncio.StreamReader()
    body = b'{"jsonrpc":"2.0","id":"truncated"}'
    reader.feed_data(b"Content-Length: 99\r\n\r\n" + body)
    reader.feed_eof()

    assert await bridge_callbacks._read_framed_message(reader) is None
    assert any(
        level == "error" and "Incomplete read" in message and "expected 99" in message
        for level, message in logs
    )


@pytest.mark.asyncio
async def test_stdin_reader_loop_smoke_ping_and_exit_content_length(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Smoke the stdin loop with real Content-Length input and output frames."""
    controller = BridgeController()
    stdout = _FakeStdout()
    transport = _FakeReadTransport()
    input_frames = b"".join(
        [
            _frame({"jsonrpc": "2.0", "id": "ping-1", "method": "ping"}),
            _frame(
                {
                    "jsonrpc": "2.0",
                    "id": "exit-1",
                    "method": "exit",
                    "params": {"reason": "test-done"},
                }
            ),
        ]
    )

    async def fake_connect_read_pipe(protocol_factory: Any, pipe: Any) -> Any:
        protocol = protocol_factory()
        protocol.connection_made(transport)
        protocol.data_received(input_frames)
        protocol.eof_received()
        return transport, protocol

    loop = asyncio.get_running_loop()
    monkeypatch.setattr(bridge_callbacks, "BRIDGE_ENABLED", True)
    monkeypatch.setattr(bridge_callbacks, "_bridge_controller", controller)
    monkeypatch.setattr(bridge_callbacks, "_log_bridge", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(bridge_callbacks.sys, "stdout", stdout)
    monkeypatch.setattr(loop, "connect_read_pipe", fake_connect_read_pipe)

    await asyncio.wait_for(bridge_callbacks._stdin_reader_loop(), timeout=1)

    responses = _decode_frames(stdout.buffer.getvalue())
    assert [response["id"] for response in responses] == ["ping-1", "exit-1"]
    assert responses[0]["result"]["pong"] is True
    assert responses[1]["result"]["status"] == "exiting"
    assert responses[1]["result"]["reason"] == "test-done"
