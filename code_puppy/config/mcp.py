"""MCP (Model Context Protocol) server configuration.

Manages loading and caching of MCP server definitions from
``mcp_servers.json``. Mirrors part of the Elixir ``Config`` facade.

ADR-003: MCP config file path is resolved via ``_path_mcp_servers_file()``
which respects pup-ex isolation.
"""

from __future__ import annotations

import json
import pathlib

from code_puppy.config.paths import _path_mcp_servers_file

__all__ = [
    "load_mcp_server_configs",
]


# MCP config cache with mtime invalidation
_MCP_CONFIG_CACHE: dict | None = None
_MCP_CONFIG_MTIME: float = 0.0


def load_mcp_server_configs() -> dict:
    """Load MCP server configurations from ``mcp_servers.json``.

    Returns a dict mapping names to their URL or config dict.
    Cached with mtime invalidation to avoid repeated disk reads.
    """
    global _MCP_CONFIG_CACHE, _MCP_CONFIG_MTIME

    from code_puppy.messaging.message_queue import emit_error

    try:
        config_path = pathlib.Path(_path_mcp_servers_file())
        mtime = config_path.stat().st_mtime if config_path.exists() else 0

        if _MCP_CONFIG_CACHE is not None and mtime == _MCP_CONFIG_MTIME:
            return _MCP_CONFIG_CACHE

        if not config_path.exists():
            _MCP_CONFIG_CACHE = {}
            _MCP_CONFIG_MTIME = mtime
            return _MCP_CONFIG_CACHE

        with open(config_path, "r", encoding="utf-8") as f:
            conf = json.loads(f.read())
            _MCP_CONFIG_CACHE = conf.get("mcp_servers", {})
            _MCP_CONFIG_MTIME = mtime
            return _MCP_CONFIG_CACHE
    except Exception as e:
        emit_error(f"Failed to load MCP servers - {str(e)}")
        return {}
