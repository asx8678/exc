"""Scheduler tools for the Scheduler Agent.

These tools are stubbed — the Python scheduler has been migrated to the
Elixir Oban backend. Each tool returns a helpful message directing users
to the Elixir CLI or /scheduler command.

Removed in djs.2. See docs/triage/djs2-deletion-manifest.md
"""

_SCHEDULER_MIGRATED_MSG = (
    "⚠️ The Python scheduler has been migrated to the Elixir Oban backend. "
    "Use the `/scheduler` command or configure tasks via the Elixir CLI."
)


def register_scheduler_list_tasks(agent):
    """Register the scheduler_list_tasks tool (stubbed)."""

    def scheduler_list_tasks() -> str:
        """List all scheduled tasks with their status and daemon info."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_list_tasks)


def register_scheduler_create_task(agent):
    """Register the scheduler_create_task tool (stubbed)."""

    def scheduler_create_task(
        name: str = "unused",
        prompt: str = "unused",
        agent: str = "code-puppy",
        model: str = "",
        schedule_type: str = "interval",
        schedule_value: str = "1h",
        working_directory: str = ".",
    ) -> str:
        """Create a new scheduled task (stubbed — migrated to Elixir)."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_create_task)


def register_scheduler_delete_task(agent):
    """Register the scheduler_delete_task tool (stubbed)."""

    def scheduler_delete_task(
        task_id: str = "unused",
    ) -> str:
        """Delete a scheduled task by its ID (stubbed — migrated to Elixir)."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_delete_task)


def register_scheduler_toggle_task(agent):
    """Register the scheduler_toggle_task tool (stubbed)."""

    def scheduler_toggle_task(
        task_id: str = "unused",
    ) -> str:
        """Toggle a task's enabled/disabled state (stubbed — migrated to Elixir)."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_toggle_task)


def register_scheduler_daemon_status(agent):
    """Register the scheduler_daemon_status tool (stubbed)."""

    def scheduler_daemon_status() -> str:
        """Check if the scheduler daemon is running (stubbed — migrated to Elixir)."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_daemon_status)


def register_scheduler_start_daemon(agent):
    """Register the scheduler_start_daemon tool (stubbed)."""

    def scheduler_start_daemon() -> str:
        """Start the scheduler daemon in the background (stubbed — migrated to Elixir)."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_start_daemon)


def register_scheduler_stop_daemon(agent):
    """Register the scheduler_stop_daemon tool (stubbed)."""

    def scheduler_stop_daemon() -> str:
        """Stop the scheduler daemon (stubbed — migrated to Elixir)."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_stop_daemon)


def register_scheduler_run_task(agent):
    """Register the scheduler_run_task tool (stubbed)."""

    def scheduler_run_task(
        task_id: str = "unused",
    ) -> str:
        """Run a scheduled task immediately (stubbed — migrated to Elixir)."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_run_task)


def register_scheduler_view_log(agent):
    """Register the scheduler_view_log tool (stubbed)."""

    def scheduler_view_log(
        task_id: str = "unused",
        lines: int = 50,
    ) -> str:
        """View the log file for a scheduled task (stubbed — migrated to Elixir)."""
        return _SCHEDULER_MIGRATED_MSG

    agent.tool_plain(scheduler_view_log)
