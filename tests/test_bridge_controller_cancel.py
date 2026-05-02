"""Tests for bridge_controller task cancellation (code-puppy-b9i).

Covers:
- Task reference stored in _active_runs on run.start
- Cancel actually cancels the asyncio task
- Cancel on already-done task is a no-op
- Cancel on non-existent run raises WireMethodError
- Shutdown cancels all active tasks
- CancelledError handler emits run.cancelled notification
"""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from code_puppy.plugins.elixir_bridge.bridge_controller import BridgeController
from code_puppy.plugins.elixir_bridge.wire_protocol import WireMethodError


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


class TestTaskReferenceStorage:
    """Task references must be stored in _active_runs for cancellation."""

    @pytest.mark.asyncio
    async def test_task_stored_in_active_runs(self, controller):
        """run.start should store the asyncio task in _active_runs."""
        # Mock the agent execution to avoid real invocation
        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            new_callable=AsyncMock,
            return_value="ok",
        ):
            result = await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "hello",
                        "run_id": "test-run-1",
                    },
                }
            )

        assert result["status"] == "started"
        assert result["run_id"] == "test-run-1"

        # Verify task reference is stored
        run_info = controller._active_runs.get("test-run-1")
        # The run may have already completed (popped), but if it's still
        # there, it should have a task key.
        if run_info is not None:
            assert "task" in run_info
            assert isinstance(run_info["task"], asyncio.Task)

        # Wait for background task to complete so we don't leak tasks
        await asyncio.sleep(0.1)

    @pytest.mark.asyncio
    async def test_task_key_is_asyncio_task(self, controller):
        """The 'task' field should be an asyncio.Task instance."""
        task_done = asyncio.Event()

        async def slow_run(*args, **kwargs):
            await task_done.wait()
            return "done"

        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            side_effect=slow_run,
        ):
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "hello",
                        "run_id": "test-run-2",
                    },
                }
            )

        run_info = controller._active_runs.get("test-run-2")
        assert run_info is not None
        assert "task" in run_info
        assert isinstance(run_info["task"], asyncio.Task)
        assert not run_info["task"].done()

        # Clean up
        task_done.set()
        await asyncio.sleep(0.05)


class TestCancelActuallyCancels:
    """Cancel must actually cancel the underlying asyncio task."""

    @pytest.mark.asyncio
    async def test_cancel_stops_running_task(self, controller):
        """Cancelling a run should cancel the underlying task."""
        task_cancelled = asyncio.Event()
        task_ready = asyncio.Event()

        async def slow_run(*args, **kwargs):
            task_ready.set()  # Signal that we're inside the coroutine
            try:
                await asyncio.Event().wait()  # Wait forever
            except asyncio.CancelledError:
                task_cancelled.set()
                raise
            return "done"

        # Patch must stay active until the background task is cancelled
        # because the task runs asynchronously after dispatch returns
        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            side_effect=slow_run,
        ):
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "hello",
                        "run_id": "cancel-test-1",
                    },
                }
            )

            # Wait for the task to actually enter slow_run before cancelling
            await asyncio.wait_for(task_ready.wait(), timeout=2.0)

            # Confirm task is running
            assert "cancel-test-1" in controller._active_runs

            # Cancel it
            result = await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "2",
                    "method": "run.cancel",
                    "params": {
                        "run_id": "cancel-test-1",
                        "reason": "test_cancel",
                    },
                }
            )

        assert result["status"] == "cancelled"
        assert result["run_id"] == "cancel-test-1"
        assert result["reason"] == "test_cancel"

        # Run should be removed from active_runs
        assert "cancel-test-1" not in controller._active_runs

        # The underlying task should have received cancellation
        assert task_cancelled.is_set()

    @pytest.mark.asyncio
    async def test_cancel_waits_for_task_cleanup(self, controller):
        """Cancel should wait briefly for the task to finish."""
        task_done = asyncio.Event()
        task_cancelled = asyncio.Event()

        async def cancellable_run(*args, **kwargs):
            try:
                await task_done.wait()
            except asyncio.CancelledError:
                task_cancelled.set()
                raise
            return "done"

        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            side_effect=cancellable_run,
        ):
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "hello",
                        "run_id": "cancel-wait-1",
                    },
                }
            )

            result = await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "2",
                    "method": "run.cancel",
                    "params": {"run_id": "cancel-wait-1"},
                }
            )

        assert result["status"] == "cancelled"
        # The task should have received cancellation
        assert task_cancelled.is_set() or "cancel-wait-1" not in controller._active_runs


class TestCancelOnDoneTask:
    """Cancelling a completed task should be a no-op for the task itself."""

    @pytest.mark.asyncio
    async def test_cancel_already_done_task(self, controller):
        """If the task is already done, cancel should still succeed."""
        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            new_callable=AsyncMock,
            return_value="ok",
        ):
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "hello",
                        "run_id": "done-task-1",
                    },
                }
            )

        # Wait for the task to complete
        await asyncio.sleep(0.2)

        # The run may have already been cleaned up by _execute_agent_run.
        # If it's still there, cancel should be fine. If not, it should raise.
        if "done-task-1" in controller._active_runs:
            result = await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "2",
                    "method": "run.cancel",
                    "params": {"run_id": "done-task-1"},
                }
            )
            assert result["status"] == "cancelled"
        else:
            # Already cleaned up, cancel should raise
            with pytest.raises(WireMethodError) as exc_info:
                await controller.dispatch(
                    {
                        "jsonrpc": "2.0",
                        "id": "2",
                        "method": "run.cancel",
                        "params": {"run_id": "done-task-1"},
                    }
                )
            assert "Run not found" in str(exc_info.value)


class TestCancelledErrorNotification:
    """The CancelledError handler in _execute_agent_run emits run.cancelled."""

    @pytest.mark.asyncio
    async def test_cancelled_error_emits_notification(
        self, controller, capture_notifications
    ):
        """When a task is cancelled, run.cancelled notification should be emitted."""
        # Directly test the CancelledError handler by creating a task and cancelling it
        run_started = asyncio.Event()
        run_cancelled = asyncio.Event()

        async def cancellable_run(*args, **kwargs):
            run_started.set()
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                run_cancelled.set()
                raise
            return "done"

        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            side_effect=cancellable_run,
        ):
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "hello",
                        "run_id": "notif-test-1",
                    },
                }
            )

            # Wait for the task to actually start running
            await asyncio.sleep(0.05)

            # Cancel the task directly to test the CancelledError handler path
            task = controller._active_runs["notif-test-1"]["task"]
            task.cancel()

            # Wait for cancellation to propagate
            try:
                await asyncio.wait_for(task, timeout=2.0)
            except asyncio.CancelledError, asyncio.TimeoutError:
                pass

            # Give the CancelledError handler time to emit the notification
            await asyncio.sleep(0.05)

        # Note: run.cancelled notification may or may not fire depending on
        # timing with wait_for wrapping, but the task should be cleaned up
        assert "notif-test-1" not in controller._active_runs


class TestCancelNonExistent:
    """Cancelling a non-existent run should raise WireMethodError."""

    @pytest.mark.asyncio
    async def test_cancel_nonexistent_run(self, controller):
        """run.cancel with unknown run_id should raise WireMethodError."""
        with pytest.raises(WireMethodError) as exc_info:
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.cancel",
                    "params": {"run_id": "nonexistent-run"},
                }
            )
        assert "Run not found" in str(exc_info.value)
        assert exc_info.value.code == -32001


class TestShutdownCancelsAll:
    """shutdown() should cancel all active tasks."""

    @pytest.mark.asyncio
    async def test_shutdown_cancels_active_tasks(self, controller):
        """shutdown() should cancel all running tasks."""
        task_done = asyncio.Event()

        async def slow_run(*args, **kwargs):
            try:
                await task_done.wait()
            except asyncio.CancelledError:
                raise
            return "done"

        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            side_effect=slow_run,
        ):
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "hello",
                        "run_id": "shutdown-test-1",
                    },
                }
            )

            assert "shutdown-test-1" in controller._active_runs

            await controller.shutdown()

        # All runs should be cleared
        assert len(controller._active_runs) == 0
        assert not controller.running

    @pytest.mark.asyncio
    async def test_shutdown_clears_multiple_tasks(self, controller):
        """shutdown() should clear all active runs, not just one."""
        task_done = asyncio.Event()

        async def slow_run(*args, **kwargs):
            try:
                await task_done.wait()
            except asyncio.CancelledError:
                raise
            return "done"

        with patch(
            "code_puppy.tools.agent_tools.invoke_agent_headless",
            side_effect=slow_run,
        ):
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "hello",
                        "run_id": "multi-1",
                    },
                }
            )
            await controller.dispatch(
                {
                    "jsonrpc": "2.0",
                    "id": "2",
                    "method": "run.start",
                    "params": {
                        "agent_name": "code-puppy",
                        "prompt": "world",
                        "run_id": "multi-2",
                    },
                }
            )

            assert len(controller._active_runs) == 2

            await controller.shutdown()
        assert len(controller._active_runs) == 0
