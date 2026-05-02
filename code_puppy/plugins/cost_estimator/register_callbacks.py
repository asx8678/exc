"""Cost Estimator plugin — token counting and cost estimation.

Registers:
- ``/cost`` command to show session cost summary
- ``/estimate <text>`` command to estimate tokens/cost for text
- ``pre_tool_call`` hook for dry-run interception (when enabled)
- ``shutdown`` hook for session summary

Inspired by Agentless ``--mock`` flag and token counting pattern.
"""

import logging
import os
from typing import Any

from code_puppy.callbacks import register_callback

logger = logging.getLogger(__name__)

# Dry-run mode: set PUP_DRY_RUN=1 to intercept LLM calls
_DRY_RUN = os.environ.get("PUP_DRY_RUN", "").strip() in ("1", "true", "yes")


def _get_ledger_provider_totals() -> dict[str, Any]:
    """Try to get provider-reported token totals from the token ledger.

    Best-effort: returns empty dict if ledger is unavailable or has
    no provider data. Never raises — falls back gracefully.

    Returns:
        Dict with optional 'total_provider_input' and 'total_provider_output' keys,
        or empty dict if no provider data is available.
    """
    try:
        from code_puppy.agents.agent_manager import get_current_agent

        agent = get_current_agent()
        if agent is None:
            return {}
        # Access the ledger via the agent's runtime state
        if not hasattr(agent, "_state"):
            return {}
        ledger = agent._state.get_token_ledger()
        result: dict[str, Any] = {}
        provider_input = ledger.total_provider_input
        if provider_input is not None:
            result["total_provider_input"] = provider_input
        provider_output = ledger.total_provider_output
        if provider_output is not None:
            result["total_provider_output"] = provider_output
        return result
    except Exception:
        # Fall back to heuristic — this is best-effort
        return {}


def _handle_cost_command(command: str, name: str) -> str | None:
    """Handle /cost and /estimate slash commands."""
    if name == "cost":
        from .estimator import get_session_summary

        summary = get_session_summary()
        if not summary["models"]:
            return "No token usage tracked in this session yet."

        lines = ["📊 **Session Cost Summary**\n"]
        for m in summary["models"]:
            lines.append(
                f"  - **{m['model']}**: {m['total_tokens']:,} tokens "
                f"(~${m['estimated_cost_usd']:.4f})"
            )
        lines.append(
            f"\n  **Total estimated cost**: ${summary['total_estimated_cost_usd']:.4f} USD"
        )

        # TODO(token-audit-5.1): Show per-model provider actuals when available
        # Try to augment with provider-reported counts from the token ledger
        provider_totals = _get_ledger_provider_totals()
        if provider_totals:
            lines.append("")
            lines.append("  **Provider-reported usage**:")
            total_in = provider_totals.get("total_provider_input")
            total_out = provider_totals.get("total_provider_output")
            if total_in is not None:
                lines.append(f"    - Input tokens: {total_in:,}")
            if total_out is not None:
                lines.append(f"    - Output tokens: {total_out:,}")

        lines.append("\n  ⚠️ _estimate — actual provider usage may differ_")
        return "\n".join(lines)

    if name == "estimate":
        parts = command.strip().split(maxsplit=1)
        if len(parts) < 2 or not parts[1].strip():
            return "Usage: /estimate <text or prompt to estimate>"

        from .estimator import estimate_cost

        text = parts[1].strip()

        # Try to get provider counts from the ledger for the current model
        provider_totals = _get_ledger_provider_totals()
        provider_in = provider_totals.get("total_provider_input")
        provider_out = provider_totals.get("total_provider_output")

        est = estimate_cost(
            text,
            provider_input_tokens=provider_in,
            provider_output_tokens=provider_out,
        )
        result_lines = [
            "📊 **Token Estimate**",
            f"  - Input tokens: ~{est.input_tokens:,} ({est.method})",
        ]
        if est.provider_input_tokens is not None:
            result_lines.append(
                f"  - Provider-reported input: {est.provider_input_tokens:,}"
            )
        result_lines.append(f"  - Expected output: ~{est.output_tokens:,} tokens")
        if est.provider_output_tokens is not None:
            result_lines.append(
                f"  - Provider-reported output: {est.provider_output_tokens:,}"
            )
        result_lines.extend(
            [
                f"  - Estimated cost: ~${est.estimated_cost_usd:.4f} USD",
                f"  - Model: {est.model}",
                "",
                "⚠️ _estimate — actual provider usage may differ_",
            ]
        )
        return "\n".join(result_lines)

    return None


def _cost_help() -> list[tuple[str, str]]:
    """Provide help entries for cost commands."""
    return [
        ("/cost", "Show accumulated token usage and estimated costs for this session"),
        ("/estimate <text>", "Estimate token count and cost for given text"),
    ]


def _on_pre_tool_call(
    tool_name: str,
    tool_args: dict,
    context=None,
) -> None:
    """Track token usage on tool calls.

    Always tracks token estimates for /cost reporting.
    In dry-run mode (PUP_DRY_RUN=1), additionally logs estimates.
    """
    if tool_name in ("invoke_agent",):
        prompt = tool_args.get("prompt", "") or tool_args.get("message", "")
        if prompt:
            from .estimator import count_tokens, track_session_tokens

            model = tool_args.get("model", "gpt-4o")
            tokens = count_tokens(str(prompt), model=model)
            track_session_tokens(model, tokens)

            if _DRY_RUN:
                logger.info(
                    "cost_estimator: %s → ~%d tokens (%s)",
                    tool_name,
                    tokens,
                    model,
                )

    return None


def _on_shutdown() -> None:
    """Print session cost summary on shutdown if anything was tracked."""
    from .estimator import get_session_summary

    summary = get_session_summary()
    if summary["models"]:
        total = summary["total_estimated_cost_usd"]
        logger.info(
            "Session cost estimate: ~$%.4f USD (estimate — actual provider usage may differ)",
            total,
        )


# Register callbacks at module scope
register_callback("custom_command", _handle_cost_command)
register_callback("custom_command_help", _cost_help)
register_callback("pre_tool_call", _on_pre_tool_call)
register_callback("shutdown", _on_shutdown)
