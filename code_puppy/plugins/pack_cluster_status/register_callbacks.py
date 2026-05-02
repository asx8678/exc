"""
/pack-cluster — show distributed pack cluster status.

Delegates to the Elixir ClusterStatus module via the bridge.
"""

import logging

from code_puppy.callbacks import register_callback

logger = logging.getLogger(__name__)

_COMMAND_NAMES = {"pack-cluster", "cluster-status"}


def _handle_command(command: str, name: str):
    """Handle /pack-cluster slash command."""
    if name not in _COMMAND_NAMES:
        return None

    try:
        from code_puppy.plugins.elixir_bridge import call_method, is_connected

        if not is_connected():
            return (
                "Pack cluster status requires the Elixir bridge.\n"
                "Run with `enable_elixir_control=true` in puppy.cfg."
            )

        result = call_method("pack.cluster_status.snapshot", {})

        if result is None:
            return (
                "Distributed packs are not enabled.\n"
                "Set `packs.distributed.enabled = true` in puppy.cfg."
            )

        # Format the result
        return _format_status(result)

    except ImportError:
        return "Elixir bridge not available."
    except Exception as e:
        logger.error("pack-cluster: error getting status", exc_info=True)
        return f"Error getting cluster status: {e}"


def _format_status(status: dict) -> str:
    """Format cluster status dict from Elixir as readable string."""
    lines = []
    lines.append("═══ Pack Cluster Status ═══")
    lines.append("")

    enabled = status.get("enabled", False)
    tls = status.get("tls_enabled", False)
    local = status.get("local_node", "unknown")
    dispatch = status.get("dispatch_style", "async")

    lines.append(f"  Enabled:      {'✓' if enabled else '✗'}")
    lines.append(f"  TLS:          {'✓ (encrypted)' if tls else '✗ (plaintext)'}")
    lines.append(f"  Local Node:   {local}")
    lines.append(f"  Dispatch:     {dispatch}")
    lines.append("")

    connected = status.get("connected_workers", [])
    disconnected = status.get("disconnected_workers", [])

    lines.append(
        f"  Workers: {len(connected)} connected, {len(disconnected)} disconnected"
    )
    lines.append(f"  Active:  {status.get('total_active_dispatches', 0)} dispatches")
    lines.append(f"  Slots:   {status.get('total_available_slots', 0)} available")
    lines.append("")

    for w in connected:
        node = w.get("node", "?")
        active = w.get("active_dispatches", 0)
        max_c = w.get("max_concurrent", "?")
        total = w.get("total_dispatches", 0)
        done = w.get("total_completions", 0)
        failed = w.get("total_failures", 0)
        lines.append(f"  🟢 {node}")
        lines.append(
            f"     Slots: {active}/{max_c}  |  "
            f"Dispatched: {total}  Done: {done}  Failed: {failed}"
        )

    for w in disconnected:
        node = w.get("node", "?")
        status_val = w.get("status", "disconnected")
        icon = "🟡" if status_val == "shutting_down" else "🔴"
        lines.append(f"  {icon} {node} ({status_val})")

    if not connected and not disconnected:
        lines.append("  No workers configured.")
        lines.append(
            "  Add workers in puppy.cfg: [packs.distributed] workers = node@host"
        )

    lines.append("")
    lines.append("═══════════════════════════")

    return "\n".join(lines)


def _handle_help():
    """Return help entry for /pack-cluster."""
    return [("/pack-cluster", "Show distributed pack cluster status")]


register_callback("custom_command", _handle_command)
register_callback("custom_command_help", _handle_help)
