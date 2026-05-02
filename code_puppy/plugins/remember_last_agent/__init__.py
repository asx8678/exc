"""Remember Last Agent plugin — persists the last selected agent across restarts.

This plugin saves the last agent selected by the user and restores it
on the next startup (if no session-specific agent is already set).
"""

from .storage import clear_last_agent, get_last_agent, set_last_agent

__all__ = ["get_last_agent", "set_last_agent", "clear_last_agent"]
