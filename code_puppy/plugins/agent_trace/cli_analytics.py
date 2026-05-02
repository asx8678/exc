"""Agent Trace V2 — CLI Analytics Renderer.

Renders analytics data (budget, comparison, outliers) in the terminal.
Beautiful bar charts, tables, and formatted output.
"""

from __future__ import annotations

from typing import TextIO

from code_puppy.plugins.agent_trace.analytics import (
    Outlier,
    OutlierReport,
    RunComparison,
    TokenBudget,
)
from code_puppy.plugins.agent_trace.cli_renderer import Box, Colors

# ═══════════════════════════════════════════════════════════════════════════════
# Bar Chart Rendering
# ═══════════════════════════════════════════════════════════════════════════════


def _bar(value: float, max_value: float, width: int = 25) -> str:
    """Render a horizontal bar."""
    if max_value == 0:
        return "░" * width

    fill = int(value / max_value * width)
    empty = width - fill
    return "█" * fill + "░" * empty


def _colored_bar(
    value: float, max_value: float, width: int = 25, color: str = ""
) -> str:
    """Render a colored horizontal bar."""
    bar = _bar(value, max_value, width)
    if color:
        return f"{color}{bar}{Colors.RESET}"
    return bar


# ═══════════════════════════════════════════════════════════════════════════════
# Token Budget Rendering
# ═══════════════════════════════════════════════════════════════════════════════


def render_token_budget(
    budget: TokenBudget,
    width: int = 60,
    output: TextIO | None = None,
) -> str:
    """Render token budget as a CLI bar chart.

    Example output:
    ```
    Token Flow ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      System prompt    ████░░░░░░░░░░░░░░░░░░░░░  320 (12%)
      History context  ██████████░░░░░░░░░░░░░░░  892 (34%)
      Tool results     ████████░░░░░░░░░░░░░░░░░  654 (25%)
      Model output     ███████░░░░░░░░░░░░░░░░░░  512 (20%)
      Reasoning        ███░░░░░░░░░░░░░░░░░░░░░░  234 (9%)
      ─────────────────────────────────────────────────────
      Total: 2,612 tokens (~$0.0078)
    ```
    """
    lines = []

    # Header
    header = " Token Flow "
    pad_width = width - len(header) - 2
    lines.append(f"{Colors.BOLD}{header}{Colors.RESET}{'━' * pad_width}")

    # Get breakdown
    breakdown = budget.breakdown()
    if not breakdown:
        lines.append(f"  {Colors.DIM}No token data available{Colors.RESET}")
    else:
        max_tokens = max(count for _, count, _ in breakdown)
        max_name_len = max(len(name) for name, _, _ in breakdown)

        # Color mapping for categories
        category_colors = {
            "System prompt": Colors.BLUE,
            "History context": Colors.YELLOW,
            "Retrieved context": Colors.CYAN,
            "Tool results": Colors.MAGENTA,
            "Tool args": Colors.MAGENTA,
            "Model output": Colors.GREEN,
            "Reasoning": Colors.WHITE,
            "Delegate prompt": Colors.BLUE,
            "Delegate response": Colors.GREEN,
        }

        for name, count, pct in breakdown:
            color = category_colors.get(name, Colors.WHITE)
            bar = _colored_bar(count, max_tokens, width=25, color=color)
            lines.append(f"  {name:<{max_name_len}}  {bar}  {count:,} ({pct:.0f}%)")

    # Separator
    lines.append(f"  {'─' * (width - 4)}")

    # Total
    total = budget.total()
    total_line = f"  Total: {total:,} tokens"

    # Add cost if available
    if budget.estimated_cost_usd:
        total_line += f" (~${budget.estimated_cost_usd:.4f})"

    # Add accounting state
    if budget.reconciled:
        total_line += f" {Colors.CYAN}[reconciled]{Colors.RESET}"
    elif budget.exact_total > budget.estimated_total:
        total_line += f" {Colors.GREEN}[exact]{Colors.RESET}"
    elif budget.estimated_total > 0:
        total_line += f" {Colors.YELLOW}[estimated]{Colors.RESET}"

    lines.append(total_line)

    result = "\n".join(lines)

    if output:
        output.write(result + "\n")
        output.flush()

    return result


# ═══════════════════════════════════════════════════════════════════════════════
# Run Comparison Rendering
# ═══════════════════════════════════════════════════════════════════════════════


def _format_delta(current: float, delta_pct: float) -> str:
    """Format a value with delta percentage."""
    if delta_pct > 0:
        return f"{current:,.0f} {Colors.RED}(+{delta_pct:.0f}%){Colors.RESET}"
    elif delta_pct < 0:
        return f"{current:,.0f} {Colors.GREEN}({delta_pct:.0f}%){Colors.RESET}"
    else:
        return f"{current:,.0f} (0%)"


def _format_count_delta(current: int, delta: int) -> str:
    """Format a count with delta."""
    if delta > 0:
        return f"{current} {Colors.RED}(+{delta}){Colors.RESET}"
    elif delta < 0:
        return f"{current} {Colors.GREEN}({delta}){Colors.RESET}"
    else:
        return f"{current} (0)"


def render_comparison(
    comparison: RunComparison,
    width: int = 60,
    output: TextIO | None = None,
) -> str:
    """Render run comparison as a table.

    Example output:
    ```
    Comparing: trace-abc123 vs trace-def456
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                          baseline     current      Δ
      Duration            2.3s         4.1s         +78%
      Total tokens        1,892        3,456        +83%
      Model calls         3            7            +133%
      Tool calls          2            5            +150%
      ─────────────────────────────────────────────────────
      ⚠️ Significant regression detected
    ```
    """
    lines = []
    b = comparison.baseline
    c = comparison.current

    # Header
    lines.append(f"{Colors.BOLD}Comparing:{Colors.RESET} {b.trace_id} vs {c.trace_id}")
    lines.append("━" * width)

    # Column headers
    lines.append(f"  {'Metric':<20} {'Baseline':>12} {'Current':>12} {'Δ':>12}")
    lines.append(f"  {'-' * 20} {'-' * 12} {'-' * 12} {'-' * 12}")

    # Duration
    b_dur = f"{b.duration_ms / 1000:.1f}s" if b.duration_ms else "N/A"
    c_dur = f"{c.duration_ms / 1000:.1f}s" if c.duration_ms else "N/A"
    delta_dur = (
        f"+{comparison.duration_delta_pct:.0f}%"
        if comparison.duration_delta_pct > 0
        else f"{comparison.duration_delta_pct:.0f}%"
    )
    delta_color = (
        Colors.RED
        if comparison.duration_delta_pct > 20
        else Colors.GREEN
        if comparison.duration_delta_pct < -10
        else ""
    )
    lines.append(
        f"  {'Duration':<20} {b_dur:>12} {c_dur:>12} {delta_color}{delta_dur:>12}{Colors.RESET}"
    )

    # Tokens
    delta_tok = (
        f"+{comparison.tokens_delta_pct:.0f}%"
        if comparison.tokens_delta_pct > 0
        else f"{comparison.tokens_delta_pct:.0f}%"
    )
    tok_color = (
        Colors.RED
        if comparison.tokens_delta_pct > 20
        else Colors.GREEN
        if comparison.tokens_delta_pct < -10
        else ""
    )
    lines.append(
        f"  {'Total tokens':<20} {b.total_tokens:>12,} {c.total_tokens:>12,} {tok_color}{delta_tok:>12}{Colors.RESET}"
    )

    # Model calls
    delta_mc = (
        f"+{comparison.model_calls_delta}"
        if comparison.model_calls_delta > 0
        else str(comparison.model_calls_delta)
    )
    mc_color = Colors.RED if comparison.model_calls_delta > 1 else ""
    lines.append(
        f"  {'Model calls':<20} {b.model_calls:>12} {c.model_calls:>12} {mc_color}{delta_mc:>12}{Colors.RESET}"
    )

    # Tool calls
    delta_tc = (
        f"+{comparison.tool_calls_delta}"
        if comparison.tool_calls_delta > 0
        else str(comparison.tool_calls_delta)
    )
    tc_color = Colors.RED if comparison.tool_calls_delta > 2 else ""
    lines.append(
        f"  {'Tool calls':<20} {b.tool_calls:>12} {c.tool_calls:>12} {tc_color}{delta_tc:>12}{Colors.RESET}"
    )

    # Failed spans
    if b.failed_spans > 0 or c.failed_spans > 0:
        delta_f = c.failed_spans - b.failed_spans
        delta_fs = f"+{delta_f}" if delta_f > 0 else str(delta_f)
        f_color = Colors.RED if delta_f > 0 else Colors.GREEN if delta_f < 0 else ""
        lines.append(
            f"  {'Failed spans':<20} {b.failed_spans:>12} {c.failed_spans:>12} {f_color}{delta_fs:>12}{Colors.RESET}"
        )

    # Separator
    lines.append(f"  {'─' * (width - 4)}")

    # Regression warning
    if comparison.is_regression:
        lines.append(f"  {Colors.RED}⚠️  Regression detected:{Colors.RESET}")
        for reason in comparison.regression_reasons:
            lines.append(f"      • {reason}")
    else:
        lines.append(f"  {Colors.GREEN}✓ No significant regression{Colors.RESET}")

    result = "\n".join(lines)

    if output:
        output.write(result + "\n")
        output.flush()

    return result


# ═══════════════════════════════════════════════════════════════════════════════
# Outlier Report Rendering
# ═══════════════════════════════════════════════════════════════════════════════


def _severity_color(severity: str) -> str:
    """Get color for severity level."""
    if severity == "critical":
        return Colors.RED
    elif severity == "warning":
        return Colors.YELLOW
    else:
        return Colors.DIM


def render_outlier(outlier: Outlier) -> str:
    """Render a single outlier."""
    color = _severity_color(outlier.severity)
    return f"  {outlier.icon} {color}{outlier.message}{Colors.RESET}"


def render_outlier_report(
    report: OutlierReport,
    width: int = 60,
    output: TextIO | None = None,
) -> str:
    """Render outlier report.

    Example output:
    ```
    Outlier Analysis ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      🔄 Tool 'grep' called 5 times (warning)
      📈 History context is 67% of input (warning)
      ⏱️ 'code-puppy' took 4523ms (3.2x avg) (info)
      ─────────────────────────────────────────────────────
      2 warnings, 1 info
    ```
    """
    lines = []

    # Header
    header = " Outlier Analysis "
    pad_width = width - len(header) - 2

    if report.has_critical:
        header_color = Colors.RED
    elif report.has_warnings:
        header_color = Colors.YELLOW
    else:
        header_color = Colors.GREEN

    lines.append(f"{header_color}{Colors.BOLD}{header}{Colors.RESET}{'━' * pad_width}")

    if not report.outliers:
        lines.append(f"  {Colors.GREEN}✓ No outliers detected{Colors.RESET}")
    else:
        # Group by severity
        critical = report.by_severity("critical")
        warnings = report.by_severity("warning")
        info = report.by_severity("info")

        for outlier in critical + warnings + info:
            lines.append(render_outlier(outlier))

        # Summary
        lines.append(f"  {'─' * (width - 4)}")

        summary_parts = []
        if critical:
            summary_parts.append(f"{Colors.RED}{len(critical)} critical{Colors.RESET}")
        if warnings:
            summary_parts.append(
                f"{Colors.YELLOW}{len(warnings)} warnings{Colors.RESET}"
            )
        if info:
            summary_parts.append(f"{Colors.DIM}{len(info)} info{Colors.RESET}")

        lines.append(f"  {', '.join(summary_parts)}")

    result = "\n".join(lines)

    if output:
        output.write(result + "\n")
        output.flush()

    return result


# ═══════════════════════════════════════════════════════════════════════════════
# Combined Summary Rendering
# ═══════════════════════════════════════════════════════════════════════════════


def render_trace_summary(
    budget: TokenBudget,
    outliers: OutlierReport,
    width: int = 60,
    output: TextIO | None = None,
) -> str:
    """Render combined summary with budget and outliers.

    Shown automatically at end of agent run.
    """
    lines = []

    # Box top
    lines.append(f"{Box.TL}{'─' * (width - 2)}{Box.TR}")

    # Title
    title = " Trace Summary "
    padding = width - len(title) - 4
    lines.append(f"{Box.V} {Colors.BOLD}{title}{Colors.RESET}{' ' * padding} {Box.V}")

    # Budget section (compact)
    total = budget.total()
    if total > 0:
        lines.append(
            f"{Box.V}  Tokens: {total:,} total{' ' * (width - 25 - len(str(total)))}{Box.V}"
        )

        # Top 3 categories
        breakdown = budget.breakdown()[:3]
        for name, count, pct in breakdown:
            bar = _bar(count, total, width=15)
            line = f"    {name}: {bar} {pct:.0f}%"
            padding = width - len(line) - 2
            lines.append(f"{Box.V}{line}{' ' * padding}{Box.V}")

    # Outliers section (compact)
    if outliers.outliers:
        lines.append(f"{Box.V}  {'─' * (width - 4)}{Box.V}")

        # Show top 2 outliers
        for outlier in outliers.outliers[:2]:
            icon = outlier.icon
            msg = outlier.message[: width - 10]
            color = _severity_color(outlier.severity)
            line = f"  {icon} {color}{msg}{Colors.RESET}"
            # Approximate padding (ANSI codes make length tricky)
            lines.append(f"{Box.V}{line}{Box.V}")

        if len(outliers.outliers) > 2:
            more = len(outliers.outliers) - 2
            lines.append(f"{Box.V}    +{more} more...{' ' * (width - 15)}{Box.V}")

    # Box bottom
    lines.append(f"{Box.BL}{'─' * (width - 2)}{Box.BR}")

    result = "\n".join(lines)

    if output:
        output.write(result + "\n")
        output.flush()

    return result


# ═══════════════════════════════════════════════════════════════════════════════
# Inline Summary (compact single-line)
# ═══════════════════════════════════════════════════════════════════════════════


def render_inline_summary(budget: TokenBudget, outliers: OutlierReport) -> str:
    """Render a compact single-line summary for inline display."""
    parts = []

    # Token count
    total = budget.total()
    if total > 0:
        if budget.reconciled:
            parts.append(f"{Colors.CYAN}✓{total:,} tok{Colors.RESET}")
        else:
            parts.append(f"{Colors.YELLOW}~{total:,} tok{Colors.RESET}")

    # Outliers
    if outliers.has_critical:
        parts.append(
            f"{Colors.RED}⚠ {len(outliers.by_severity('critical'))} critical{Colors.RESET}"
        )
    elif outliers.has_warnings:
        parts.append(
            f"{Colors.YELLOW}⚠ {len(outliers.by_severity('warning'))} warn{Colors.RESET}"
        )

    if parts:
        return (
            f"{Colors.DIM}[{Colors.RESET}{' '.join(parts)}{Colors.DIM}]{Colors.RESET}"
        )
    return ""
