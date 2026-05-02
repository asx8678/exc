"""Plugin registration for supervisor_review.

Registers the `supervisor_review_loop` tool so any agent that wants
quality-gated multi-agent review can call it. Adopted from
orion-multistep-analysis supervisor/orchestrator.py:582-742.
"""

import logging
from typing import Any

from pydantic_ai import RunContext

from code_puppy.callbacks import register_callback

logger = logging.getLogger(__name__)


def register_supervisor_review_tool(agent: Any) -> None:
    """Attach the supervisor_review_loop tool to an agent."""
    # Import inside the function to avoid import-time side effects and
    # to match the lazy-loading pattern used by other plugins.
    from code_puppy.plugins.supervisor_review.models import ReviewLoopConfig
    from code_puppy.plugins.supervisor_review.orchestrator import (
        run_supervisor_review_loop,
    )

    @agent.tool
    async def supervisor_review_loop(
        context: RunContext,
        worker_agents: list[str],
        supervisor_agent: str,
        task_prompt: str,
        max_iterations: int = 3,
        satisfaction_mode: str = "structured",
        session_prefix: str | None = None,
    ) -> dict:
        """Run an iterative multi-agent supervisor-review loop.

        Adopted from orion-multistep-analysis. Runs a sequence of worker
        agents on the task, then asks a supervisor agent to review the
        combined output. If the supervisor is not satisfied, the worker
        agents are re-invoked with accumulated feedback. The loop terminates
        when the supervisor is satisfied or `max_iterations` is hit.

        Args:
            worker_agents: Ordered list of agent names to run in sequence
                per iteration. E.g. ["code-puppy", "terrier"].
            supervisor_agent: Name of the agent that reviews worker output
                and issues a verdict. E.g. "shepherd".
            task_prompt: The initial task description. On iterations after
                the first, accumulated supervisor feedback is appended to
                this prompt under a "Previous supervisor feedback" header.
            max_iterations: Hard cap on review cycles (default 3, matching
                Orion's MAX_SUPERVISOR_REVIEW_LOOPS).
            satisfaction_mode: How to determine if the supervisor is
                satisfied. One of:
                - "structured" (default): expect a JSON verdict
                - "keyword": keyword heuristic (brittle, Orion-compatible)
                - "llm_judge": use a second LLM call (stubbed)
            session_prefix: Optional prefix for per-iteration session IDs
                so each agent call gets its own isolated session.

        Returns:
            A dict containing:
                - success (bool): True if the supervisor was satisfied
                - iterations_run (int): Number of iterations actually run
                - max_iterations (int): The configured cap
                - final_worker_outputs (dict): Last iteration's worker outputs
                - final_supervisor_output (str): Last supervisor response
                - feedback_history (list): Per-iteration feedback
                - iterations (list): Full per-iteration snapshots
                - error (str | None): Error message if an agent failed
                - artifacts_dir (str | None): Path to written transcripts

        Example:
            result = await supervisor_review_loop(
                worker_agents=["code-puppy"],
                supervisor_agent="shepherd",
                task_prompt="Write a function to validate email addresses",
                max_iterations=3,
                satisfaction_mode="structured",
            )
            if result["success"]:
                print(f"Done in {result['iterations_run']} iterations")
            else:
                print(f"Failed: {result['error']}")
        """
        try:
            config = ReviewLoopConfig(
                worker_agents=worker_agents,
                supervisor_agent=supervisor_agent,
                task_prompt=task_prompt,
                max_iterations=max_iterations,
                satisfaction_mode=satisfaction_mode,
                session_prefix=session_prefix,
            )
        except ValueError as exc:
            return {
                "success": False,
                "error": f"invalid config: {exc}",
                "iterations_run": 0,
                "max_iterations": max_iterations,
                "iterations": [],
                "final_worker_outputs": {},
                "final_supervisor_output": "",
                "feedback_history": [],
                "artifacts_dir": None,
            }

        try:
            result = await run_supervisor_review_loop(config)
        except Exception as exc:
            logger.exception("supervisor_review_loop failed unexpectedly")
            return {
                "success": False,
                "error": f"loop crashed: {exc}",
                "iterations_run": 0,
                "max_iterations": max_iterations,
                "iterations": [],
                "final_worker_outputs": {},
                "final_supervisor_output": "",
                "feedback_history": [],
                "artifacts_dir": None,
            }

        return result.to_dict()


def _register_tools() -> list[dict[str, Any]]:
    """Callback for the 'register_tools' hook."""
    return [
        {
            "name": "supervisor_review_loop",
            "register_func": register_supervisor_review_tool,
        }
    ]


register_callback("register_tools", _register_tools)

logger.info("Supervisor Review plugin loaded")
