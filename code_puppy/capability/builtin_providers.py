"""Built-in capability definitions and providers.

These define the standard capabilities that Code Puppy supports out of
the box.  Plugins can register additional :class:`~types.Provider`
instances for any of these capabilities by calling
:func:`~registry.register_provider`.

Standard capabilities defined here
------------------------------------
* ``"models"``   – AI model configurations
* ``"rules"``    – Agent behaviour rules
* ``"mcps"``     – Model Context Protocol server configurations

Example – adding a custom models provider from a plugin::

    from code_puppy.capability import register_provider
    from code_puppy.capability.types import LoadContext, LoadResult

    class MyModelsProvider:
        id = "my_plugin_models"
        display_name = "My Plugin Models"
        description = "Models supplied by my plugin"
        priority = 50

        def load(self, ctx: LoadContext) -> LoadResult:
            return LoadResult(items=[{"name": "my-custom-gpt", "type": "openai"}])

    register_provider("models", MyModelsProvider())
"""

import json
import logging
from pathlib import Path

from .registry import define_capability, register_provider
from .types import LoadContext, LoadResult

_logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Standard capabilities
# ---------------------------------------------------------------------------

models_capability = define_capability(
    id="models",
    display_name="Models",
    description="AI model configurations",
    key_fn=lambda m: m.get("name") if isinstance(m, dict) else None,
)

rules_capability = define_capability(
    id="rules",
    display_name="Rules",
    description="Agent behaviour rules",
    key_fn=lambda r: r.get("name") if isinstance(r, dict) else None,
)

mcps_capability = define_capability(
    id="mcps",
    display_name="MCP Servers",
    description="Model Context Protocol server configurations",
    key_fn=lambda m: m.get("name") if isinstance(m, dict) else None,
)

__all__ = [
    "models_capability",
    "rules_capability",
    "mcps_capability",
]


# ---------------------------------------------------------------------------
# Built-in providers (load from standard JSON config files)
# ---------------------------------------------------------------------------


class _JsonFileModelsProvider:
    """Loads model configs from models.json (bundled) and extra_models.json (user)."""

    id = "json_file_models"
    display_name = "JSON File Models"
    description = "Models loaded from models.json and extra_models.json"
    priority = 50  # Default tier — plugins can override at higher priority

    def load(self, ctx: LoadContext) -> LoadResult:
        items: list = []
        warnings: list[str] = []

        # Bundled models.json
        bundled = Path(__file__).resolve().parent.parent / "models.json"
        items.extend(self._load_file(bundled, warnings))

        # User extra_models.json
        try:
            from code_puppy.config import EXTRA_MODELS_FILE

            extra = Path(EXTRA_MODELS_FILE)
            items.extend(self._load_file(extra, warnings))
        except Exception:
            pass

        return LoadResult(items=items, warnings=warnings)

    @staticmethod
    def _load_file(path: Path, warnings: list[str]) -> list:
        if not path.is_file():
            return []
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return [
                    {"name": k, **v} for k, v in data.items() if isinstance(v, dict)
                ]
            return []
        except Exception as exc:
            warnings.append(f"Failed to load {path}: {exc}")
            return []


class _RulesProvider:
    """Loads agent behaviour rules from .code_puppy/rules/ directories."""

    id = "file_rules"
    display_name = "File Rules"
    description = "Rules loaded from .code_puppy/rules/ directories"
    priority = 50

    def load(self, ctx: LoadContext) -> LoadResult:
        items: list = []
        for directory in [
            Path(ctx.home) / ".code_puppy" / "rules",
            Path(ctx.cwd) / ".code_puppy" / "rules",
        ]:
            if not directory.is_dir():
                continue
            for md_file in sorted(directory.glob("*.md")):
                try:
                    items.append(
                        {
                            "name": md_file.stem,
                            "path": str(md_file),
                            "content": md_file.read_text(encoding="utf-8"),
                        }
                    )
                except OSError:
                    pass
        return LoadResult(items=items)


class _McpServersProvider:
    """Loads MCP server configs from mcp_servers.json files."""

    id = "json_file_mcps"
    display_name = "JSON File MCP Servers"
    description = "MCP servers loaded from mcp_servers.json"
    priority = 50

    def load(self, ctx: LoadContext) -> LoadResult:
        items: list = []
        warnings: list[str] = []
        for config_dir in [
            Path(ctx.home) / ".code_puppy",
            Path(ctx.cwd) / ".code_puppy",
        ]:
            mcp_file = config_dir / "mcp_servers.json"
            if not mcp_file.is_file():
                continue
            try:
                data = json.loads(mcp_file.read_text(encoding="utf-8"))
                servers = data if isinstance(data, list) else data.get("servers", [])
                for srv in servers:
                    if isinstance(srv, dict):
                        items.append(srv)
            except Exception as exc:
                warnings.append(f"Failed to load {mcp_file}: {exc}")

        return LoadResult(items=items, warnings=warnings)


# Register the built-in providers
try:
    register_provider("models", _JsonFileModelsProvider())
    register_provider("rules", _RulesProvider())
    register_provider("mcps", _McpServersProvider())
    _logger.debug("Registered built-in capability providers")
except Exception as exc:
    _logger.warning("Failed to register built-in providers: %s", exc)
