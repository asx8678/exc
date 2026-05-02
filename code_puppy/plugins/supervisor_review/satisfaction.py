"""Pluggable satisfaction checkers for supervisor review loop.

Three strategies are provided:

1. StructuredSatisfactionChecker — expects supervisor to emit JSON with a
   verdict field. Most reliable if the supervisor agent is prompted for it.
2. KeywordSatisfactionChecker — Orion-style keyword heuristic. Brittle but
   works as a zero-config fallback. Ported from Orion
   supervisor/orchestrator.py:179-187.
3. LLMJudgeSatisfactionChecker — uses a second LLM call to judge the
   supervisor output. Expensive but most reliable. Full async implementation
   with sync fallback.
"""

import logging
from collections.abc import Callable
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from typing import Awaitable

from code_puppy.plugins.supervisor_review.models import SatisfactionResult

logger = logging.getLogger(__name__)

try:
    from code_puppy.utils.llm_parsing import extract_json_from_text
except ImportError:
    extract_json_from_text = None  # type: ignore[assignment]


__all__ = [
    "SatisfactionChecker",
    "StructuredSatisfactionChecker",
    "KeywordSatisfactionChecker",
    "LLMJudgeSatisfactionChecker",
    "get_satisfaction_checker",
]


class SatisfactionChecker(Protocol):
    """Protocol for pluggable satisfaction checkers."""

    def is_satisfied(self, supervisor_output: str) -> SatisfactionResult:
        """Return whether the supervisor output indicates the work is complete."""
        ...


# ---------------------------------------------------------------------------
# Structured (JSON) checker
# ---------------------------------------------------------------------------


_APPROVED_VERDICTS = frozenset(
    {
        "approved",
        "accept",
        "accepted",
        "complete",
        "completed",
        "done",
        "satisfied",
        "pass",
        "passed",
        "ok",
        "success",
        "successful",
    }
)

_REJECTED_VERDICTS = frozenset(
    {
        "rejected",
        "reject",
        "failed",
        "fail",
        "incomplete",
        "needs_work",
        "needs-work",
        "revise",
        "retry",
    }
)


class StructuredSatisfactionChecker:
    """Expects supervisor to emit JSON containing a verdict field.

    Accepted shapes:
        {"verdict": "approved"}
        {"verdict": "approved", "confidence": 0.9, "reason": "all tests pass"}
        {"satisfied": true, "reason": "..."}
        {"aligned": true, "issues": []}  (Orion-compatible)

    If no structured verdict is found, returns unsatisfied with low confidence.
    """

    def is_satisfied(self, supervisor_output: str) -> SatisfactionResult:
        if not supervisor_output:
            return SatisfactionResult(
                satisfied=False, confidence=0.0, reason="empty supervisor output"
            )

        if extract_json_from_text is None:
            return SatisfactionResult(
                satisfied=False,
                confidence=0.0,
                reason="llm_parsing.extract_json_from_text unavailable",
            )

        parsed = extract_json_from_text(supervisor_output)
        if parsed is None or not isinstance(parsed, dict):
            return SatisfactionResult(
                satisfied=False,
                confidence=0.1,
                reason="no structured JSON verdict found",
            )

        # Try multiple schemas: "verdict" string, "satisfied" bool, "aligned" bool
        # (orion-compatible)
        if "satisfied" in parsed and isinstance(parsed["satisfied"], bool):
            sat = parsed["satisfied"]
            default_conf = 0.9 if sat else 0.6
            confidence = float(parsed.get("confidence", default_conf))
            reason = str(parsed.get("reason", "structured 'satisfied' field"))
            return SatisfactionResult(
                satisfied=sat, confidence=confidence, reason=reason
            )

        if "aligned" in parsed and isinstance(parsed["aligned"], bool):
            sat = parsed["aligned"]
            confidence = float(parsed.get("confidence", 0.9))
            reason = str(
                parsed.get("reason", parsed.get("notes", "orion-style aligned verdict"))
            )
            return SatisfactionResult(
                satisfied=sat, confidence=confidence, reason=reason
            )

        verdict_raw = parsed.get("verdict")
        if isinstance(verdict_raw, str):
            verdict = verdict_raw.strip().lower().replace(" ", "_").replace("-", "_")
            if verdict in _APPROVED_VERDICTS:
                confidence = float(parsed.get("confidence", 0.9))
                return SatisfactionResult(
                    satisfied=True,
                    confidence=confidence,
                    reason=str(parsed.get("reason", f"verdict={verdict_raw}")),
                )
            if verdict in _REJECTED_VERDICTS:
                confidence = float(parsed.get("confidence", 0.9))
                return SatisfactionResult(
                    satisfied=False,
                    confidence=confidence,
                    reason=str(parsed.get("reason", f"verdict={verdict_raw}")),
                )

        return SatisfactionResult(
            satisfied=False,
            confidence=0.2,
            reason=f"JSON present but no recognized verdict: {list(parsed.keys())}",
        )


# ---------------------------------------------------------------------------
# Keyword (Orion-style) checker
# ---------------------------------------------------------------------------


_KEYWORD_APPROVED = (
    "fully met",
    "fully satisfied",
    "fully aligned",
    "all requirements met",
    "approved",
    "lgtm",
    "looks good to me",
)

_KEYWORD_REJECTED = (
    "partially met",
    "not met",
    "needs work",
    "needs revision",
    "rejected",
    "not approved",
    "incomplete",
)


class KeywordSatisfactionChecker:
    """Port of Orion's keyword-based satisfaction check.

    Reference: orion-multistep-analysis supervisor/orchestrator.py:179-187.

    Brittle across models. Default-false on ambiguous output.
    """

    def is_satisfied(self, supervisor_output: str) -> SatisfactionResult:
        if not supervisor_output:
            return SatisfactionResult(
                satisfied=False, confidence=0.0, reason="empty supervisor output"
            )
        text = supervisor_output.lower()

        # Reject keywords take priority (Orion order)
        for keyword in _KEYWORD_REJECTED:
            if keyword in text:
                return SatisfactionResult(
                    satisfied=False,
                    confidence=0.7,
                    reason=f"found rejection keyword: {keyword!r}",
                )
        for keyword in _KEYWORD_APPROVED:
            if keyword in text:
                return SatisfactionResult(
                    satisfied=True,
                    confidence=0.7,
                    reason=f"found approval keyword: {keyword!r}",
                )

        return SatisfactionResult(
            satisfied=False,
            confidence=0.3,
            reason="no approval or rejection keywords found",
        )


# ---------------------------------------------------------------------------
# LLM judge checker
# ---------------------------------------------------------------------------

_JUDGE_PROMPT_TEMPLATE = """\
You are an impartial judge evaluating whether a code review supervisor \
considers a piece of work complete and satisfactory.

## Supervisor's review output

{supervisor_output}

## Your task

Based ONLY on the supervisor's output above, determine whether the supervisor \
considers the work COMPLETE and SATISFACTORY, or whether more iteration is needed.

Look for explicit approval signals (e.g. "approved", "looks good", "all requirements met") \
or rejection signals (e.g. "needs work", "issues found", "not complete").

Respond with ONLY a JSON object — no markdown fences, no extra text:
{{"satisfied": true or false, "confidence": 0.0 to 1.0, "reason": "brief explanation"}}
"""


def _parse_judge_response(judge_output: str) -> SatisfactionResult:
    """Parse the judge agent's response into a SatisfactionResult.

    Tries structured JSON parsing first, then falls back to keyword heuristic.
    """
    if not judge_output:
        return SatisfactionResult(
            satisfied=False,
            confidence=0.0,
            reason="empty judge response",
        )

    # Try structured parsing first
    if extract_json_from_text is not None:
        parsed = extract_json_from_text(judge_output)
        if isinstance(parsed, dict):
            if "satisfied" in parsed and isinstance(parsed["satisfied"], bool):
                return SatisfactionResult(
                    satisfied=parsed["satisfied"],
                    confidence=float(parsed.get("confidence", 0.8)),
                    reason=str(parsed.get("reason", "llm_judge verdict")),
                )

    # Fall back to keyword heuristic on the judge's response
    text = judge_output.lower()
    if any(
        kw in text
        for kw in ('satisfied": true', "complete", "approved", "satisfactory")
    ):
        return SatisfactionResult(
            satisfied=True,
            confidence=0.6,
            reason="llm_judge keyword heuristic: approval signals detected",
        )
    if any(
        kw in text
        for kw in ('satisfied": false', "incomplete", "rejected", "needs work")
    ):
        return SatisfactionResult(
            satisfied=False,
            confidence=0.6,
            reason="llm_judge keyword heuristic: rejection signals detected",
        )

    return SatisfactionResult(
        satisfied=False,
        confidence=0.3,
        reason="llm_judge: could not parse judge response",
    )


class LLMJudgeSatisfactionChecker:
    """Uses a second LLM call to judge supervisor satisfaction.

    Provides two evaluation paths:

    - ``is_satisfied_async`` (preferred): invokes a judge agent via
      ``invoke_agent_headless`` and parses the structured response.
      Used automatically by the orchestrator's async loop.
    - ``is_satisfied`` (sync fallback): delegates to
      ``StructuredSatisfactionChecker`` with slightly degraded confidence
      for callers that cannot run async code.

    Args:
        judge_agent: Name of the agent to use as the judge (default: "shepherd").
        invoke_agent_fn: Optional async callable for dependency injection.
            Signature: ``(agent_name, prompt, session_id=None) -> str``.
            If None, ``invoke_agent_headless`` is imported lazily.
    """

    def __init__(
        self,
        judge_agent: str = "shepherd",
        invoke_agent_fn: "Callable[..., Awaitable[str]] | None" = None,
    ) -> None:
        self.judge_agent = judge_agent
        self._invoke_agent_fn = invoke_agent_fn
        self._fallback = StructuredSatisfactionChecker()

    def is_satisfied(self, supervisor_output: str) -> SatisfactionResult:
        """Sync fallback — delegates to StructuredSatisfactionChecker.

        The LLM judge requires an async context to invoke a sub-agent.
        When called synchronously, this method delegates to the structured
        checker with slightly degraded confidence so callers get a usable
        result without the full LLM judge capability.
        """
        result = self._fallback.is_satisfied(supervisor_output)
        return SatisfactionResult(
            satisfied=result.satisfied,
            confidence=max(0.0, result.confidence - 0.1),
            reason=f"[llm_judge sync fallback] {result.reason}",
        )

    async def is_satisfied_async(self, supervisor_output: str) -> SatisfactionResult:
        """Async LLM judge — invokes a judge agent for satisfaction evaluation.

        Sends the supervisor output to a judge agent with a structured prompt
        requesting a JSON verdict. Falls back to the structured checker if
        the judge invocation fails for any reason.

        Args:
            supervisor_output: The supervisor agent's review text.

        Returns:
            SatisfactionResult with the judge's verdict.
        """
        if not supervisor_output:
            return SatisfactionResult(
                satisfied=False, confidence=0.0, reason="empty supervisor output"
            )

        # Resolve the invoke function
        invoke = self._invoke_agent_fn
        if invoke is None:
            try:
                from code_puppy.tools.agent_tools import invoke_agent_headless

                invoke = invoke_agent_headless
            except ImportError:
                logger.warning(
                    "LLMJudgeSatisfactionChecker: invoke_agent_headless unavailable; "
                    "falling back to structured checker"
                )
                return self.is_satisfied(supervisor_output)

        # Build the judge prompt
        prompt = _JUDGE_PROMPT_TEMPLATE.format(
            supervisor_output=supervisor_output.strip()
        )

        # Invoke the judge agent
        try:
            judge_response = await invoke(
                agent_name=self.judge_agent,
                prompt=prompt,
            )
        except Exception as exc:
            logger.warning(
                "LLMJudgeSatisfactionChecker: judge agent %r failed: %s; "
                "falling back to structured checker",
                self.judge_agent,
                exc,
            )
            return self.is_satisfied(supervisor_output)

        return _parse_judge_response(str(judge_response) if judge_response else "")


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------


def get_satisfaction_checker(mode: str) -> SatisfactionChecker:
    """Return the satisfaction checker for the given mode."""
    if mode == "structured":
        return StructuredSatisfactionChecker()
    if mode == "keyword":
        return KeywordSatisfactionChecker()
    if mode == "llm_judge":
        return LLMJudgeSatisfactionChecker()
    raise ValueError(
        f"Unknown satisfaction mode: {mode!r}. "
        f"Expected one of 'structured', 'keyword', 'llm_judge'."
    )
