import json
import logging
import os
import pathlib
import re
import threading
from collections.abc import Callable, Mapping
from types import MappingProxyType
from typing import Any

import httpx

# Light pydantic-ai imports needed at module scope for make_model_settings()
from pydantic_ai.models.anthropic import AnthropicModelSettings
from pydantic_ai.models.openai import (
    OpenAIChatModel as _OpenAIChatModel,
)
from pydantic_ai.models.openai import (
    OpenAIChatModelSettings,
    OpenAIResponsesModelSettings,
)
from pydantic_ai.settings import ModelSettings

# Import config module for deferred imports hoist pattern
# Using alias to maintain monkeypatch compatibility for tests
from code_puppy import config as _config_module
from code_puppy.messaging import emit_warning
from code_puppy.model_config import (
    _CUSTOM_MODEL_PROVIDERS,
    _MODEL_BUILDERS,
    register_model_builder,
)
from code_puppy.model_config import (
    load_plugin_providers as _load_plugin_model_providers,
)

from . import callbacks
from .config import EXTRA_MODELS_FILE, get_value, get_yolo_mode
from .http_utils import create_async_client, get_cert_bundle_path, get_http2
from .provider_identity import make_anthropic_provider, resolve_provider_identity

# Heavy SDK imports are deferred to builder functions to reduce startup time.
# See _build_anthropic(), _build_openai(), etc.

# Token calculation constants
_OUTPUT_TOKEN_RATIO = 0.15
_MIN_OUTPUT_TOKENS = 2048
_MAX_OUTPUT_TOKENS = 65536

logger = logging.getLogger(__name__)


def _is_chatgpt_oauth(model_config: dict[str, Any]) -> bool:
    """Return True if the model uses the ChatGPT Codex OAuth backend."""
    return model_config.get("type") == "chatgpt_oauth"


def _uses_responses_api(model_name: str, model_config: dict[str, Any]) -> bool:
    """Return True if the model targets the OpenAI Responses API.

    This covers:
    - chatgpt_oauth models (ChatGPT Codex backend)
    - OpenAI models with 'codex' in their name
    - Custom OpenAI models with 'codex' in their name
    """
    model_type = model_config.get("type")
    model_name_lower = model_name.lower()
    return (
        model_type == "chatgpt_oauth"
        or (model_type == "openai" and "codex" in model_name_lower)
        or (model_type == "custom_openai" and "codex" in model_name_lower)
    )


def resolve_max_output_tokens(
    model_name: str,
    model_config: dict[str, Any],
    requested: int | None = None,
) -> int:
    """Resolve the max output tokens for a model request.

    Priority order:
    1. Explicit requested value (if provided)
    2. Model-specific max_output_tokens from config
    3. Default calculation: max(_MIN_OUTPUT_TOKENS, min(context * 0.15, _MAX_OUTPUT_TOKENS))

    Always caps at provider limit if known.

    Args:
        model_name: Name of the model
        model_config: Model configuration dict
        requested: Explicitly requested output token limit

    Returns:
        Resolved max output tokens value
    """
    context_length = int(model_config.get("context_length", 128000))
    provider_limit = model_config.get("max_output_tokens")

    # Calculate default cap using module constants
    default_cap = max(
        _MIN_OUTPUT_TOKENS,
        min(int(context_length * _OUTPUT_TOKEN_RATIO), _MAX_OUTPUT_TOKENS),
    )

    # Use requested if provided, else default
    cap = requested if requested is not None else default_cap

    # Never exceed provider limit if known
    if provider_limit is not None:
        cap = min(cap, int(provider_limit))

    return max(1, cap)


def _to_mutable_nested(obj: Any) -> Any:
    """Return a mutable copy of nested model config structures.

    ModelFactory caches configuration as nested MappingProxyType values. Default
    settings are later merged and occasionally mutated (for example extra_body
    gets provider-specific fields), so copy nested mappings/lists before use.
    """
    if isinstance(obj, Mapping):
        return {key: _to_mutable_nested(value) for key, value in obj.items()}
    if isinstance(obj, list):
        return [_to_mutable_nested(item) for item in obj]
    if isinstance(obj, tuple):
        return tuple(_to_mutable_nested(item) for item in obj)
    return obj


def get_model_default_settings(model_config: Mapping[str, Any]) -> dict[str, Any]:
    """Read provider/model default settings from a model config.

    ``default_settings`` lets a model entry define request settings that cannot
    be conveniently expressed in puppy.cfg, such as nested OpenAI ``extra_body``
    payloads required by some OpenAI-compatible providers.

    User-configured per-model settings still win because callers merge them
    after these defaults.
    """
    default_settings = model_config.get("default_settings")
    if default_settings is None:
        return {}
    if not isinstance(default_settings, Mapping):
        emit_warning("Model 'default_settings' must be a JSON object; ignoring it.")
        return {}
    return _to_mutable_nested(default_settings)


# Pre-compiled regex pattern for environment variable substitution (e.g., ${VAR_NAME} or $VAR_NAME)
_ENV_VAR_RE = re.compile(r"\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*)")


# Anthropic beta header required for 1M context window support.
CONTEXT_1M_BETA = "context-1m-2025-08-07"


def _build_anthropic_beta_header(
    model_config: dict, *, interleaved_thinking: bool = False
) -> str | None:
    """Build the anthropic-beta header value for an Anthropic model.

    Combines beta flags based on model capabilities:
    - interleaved-thinking-2025-05-14 (when interleaved_thinking is enabled)
    - context-1m-2025-08-07 (when context_length >= 1_000_000)

    Returns None if no beta flags are needed.
    """
    parts: list[str] = []
    if interleaved_thinking:
        parts.append("interleaved-thinking-2025-05-14")
    if model_config.get("context_length", 0) >= 1_000_000:
        parts.append(CONTEXT_1M_BETA)
    return ",".join(parts) if parts else None


def get_api_key(env_var_name: str) -> str | None:
    """Get an API key from config first, then fall back to environment variable.

    Supports shell command resolution: if the config value starts with ``!``,
    the rest is executed as a shell command and stdout is used as the value.
    This enables integration with credential managers like 1Password CLI,
    AWS SSM, HashiCorp Vault, etc.

    Examples::

        # In puppy.cfg or via /set:
        /set openai_api_key=!op read "OpenAI API Key"
        /set anthropic_api_key=ANTHROPIC_API_KEY
        /set custom_key=sk-abc123...

    Args:
        env_var_name: The name of the environment variable (e.g., "OPENAI_API_KEY")

    Returns:
        The API key value, or None if not found in either config or environment.
    """
    # First check config (case-insensitive key lookup)
    config_value = get_value(env_var_name.lower())
    if config_value:
        # Support shell command resolution for config values
        # e.g., "!op read 'OpenAI API Key'" executes and uses stdout
        try:
            from code_puppy.utils.config_resolve import resolve_config_value_sync

            resolved = resolve_config_value_sync(config_value)
            if resolved:
                return resolved
        except ImportError:
            # config_resolve not available — use raw config value
            return config_value

    # Fall back to environment variable
    return os.environ.get(env_var_name)


def make_model_settings(
    model_name: str, max_tokens: int | None = None
) -> ModelSettings:
    """Create appropriate ModelSettings for a given model.

    Uses pydantic-ai normalized settings classes throughout:
    - ``OpenAIResponsesModelSettings`` for models targeting the OpenAI Responses
      API (including the ChatGPT Codex OAuth backend).
    - ``OpenAIChatModelSettings`` for models using the Chat Completions API.
    - ``AnthropicModelSettings`` for Anthropic/Claude models.
    - ``ModelSettings`` as the generic fallback.

    GPT-5 specific handling:
    - ``openai_reasoning_effort`` is always set.
    - ``openai_reasoning_summary`` and ``openai_text_verbosity`` are gated via
      ``model_supports_setting()`` so only models that actually support them
      receive the fields.
    - For Chat Completions GPT-5 models, verbosity is injected through
      ``extra_body`` (preserving any existing entries) and also gated via
      ``model_supports_setting()``.
    - ``max_tokens`` is resolved locally for budgeting but **not** sent for
      ``chatgpt_oauth`` models (the Codex backend ignores it anyway).

    Args:
        model_name: The name of the model to create settings for.
        max_tokens: Optional max tokens limit. If None, automatically calculated
            as: max(2048, min(15% of context_length, 65536))

    Returns:
        Appropriate ModelSettings subclass instance for the model.
    """
    # Calculate max_tokens using centralized resolver
    try:
        models_config = ModelFactory.load_config()
        model_config = models_config.get(model_name, {})
    except Exception:
        # Fallback if config loading fails (e.g., in CI environments)
        model_config = {}

    model_settings_dict: dict = get_model_default_settings(model_config)
    max_tokens = resolve_max_output_tokens(
        model_name, model_config, requested=max_tokens
    )
    model_settings_dict["max_tokens"] = max_tokens
    effective_settings = _config_module.get_effective_model_settings(model_name)
    model_settings_dict.update(effective_settings)

    # Disable parallel tool calls when yolo_mode is off (sequential so user can review each call)
    if not get_yolo_mode():
        model_settings_dict["parallel_tool_calls"] = False

    # Default to clear_thinking=False for GLM-4.7 and GLM-5 models (preserved thinking)
    if "glm-4.7" in model_name.lower() or "glm-5" in model_name.lower():
        clear_thinking = effective_settings.get("clear_thinking", False)
        model_settings_dict["thinking"] = {
            "type": "enabled",
            "clear_thinking": clear_thinking,
        }

    model_settings: ModelSettings = ModelSettings(**model_settings_dict)

    if "gpt-5" in model_name:
        model_settings_dict["openai_reasoning_effort"] = (
            _config_module.get_openai_reasoning_effort()
        )

        is_codex_oauth = _is_chatgpt_oauth(model_config)
        uses_responses = _uses_responses_api(model_name, model_config)

        if is_codex_oauth:
            # chatgpt_oauth (Codex backend) ignores max_tokens in the API,
            # but we keep the resolved value for internal budgeting.
            model_settings_dict.pop("max_tokens", None)

        if uses_responses:
            if _config_module.model_supports_setting(model_name, "summary"):
                model_settings_dict["openai_reasoning_summary"] = (
                    _config_module.get_openai_reasoning_summary()
                )
            if _config_module.model_supports_setting(model_name, "verbosity"):
                model_settings_dict["openai_text_verbosity"] = (
                    _config_module.get_openai_verbosity()
                )
            model_settings = OpenAIResponsesModelSettings(**model_settings_dict)
        else:
            # Chat Completions path: inject verbosity through extra_body.
            # Gate via model_supports_setting and preserve existing entries.
            if _config_module.model_supports_setting(model_name, "verbosity"):
                verbosity = _config_module.get_openai_verbosity()
                extra_body = model_settings_dict.get("extra_body") or {}
                extra_body["verbosity"] = verbosity
                model_settings_dict["extra_body"] = extra_body
            model_settings = OpenAIChatModelSettings(**model_settings_dict)
    elif model_name.startswith("claude-") or model_name.startswith("anthropic-"):
        # Handle Anthropic extended thinking settings
        # Remove top_p as Anthropic doesn't support it with extended thinking
        model_settings_dict.pop("top_p", None)

        # Determine extended_thinking mode BEFORE setting temperature,
        # because thinking mode dictates the allowed temperature value.
        from code_puppy.model_utils import get_default_extended_thinking

        default_thinking = get_default_extended_thinking(model_name)
        extended_thinking = effective_settings.get(
            "extended_thinking", default_thinking
        )
        # Backwards compat: handle legacy boolean values
        if extended_thinking is True:
            extended_thinking = "enabled"
        elif extended_thinking is False:
            extended_thinking = "off"

        # Claude extended thinking requires temperature=1.0 (API restriction).
        # When thinking is active, any non-1.0 temperature must be coerced.
        if extended_thinking in ("enabled", "adaptive"):
            user_temp = model_settings_dict.get("temperature")
            if user_temp is not None and user_temp != 1.0:
                emit_warning(
                    f"Extended thinking is '{extended_thinking}' for model "
                    f"'{model_name}'; overriding temperature from "
                    f"{user_temp} to 1.0 (API requirement)."
                )
            model_settings_dict["temperature"] = 1.0
        elif model_settings_dict.get("temperature") is None:
            # No thinking active — default to 1.0 only when not explicitly set
            model_settings_dict["temperature"] = 1.0

        budget_tokens = effective_settings.get("budget_tokens", 10000)
        if extended_thinking in ("enabled", "adaptive"):
            model_settings_dict["anthropic_thinking"] = {
                "type": extended_thinking,
            }
            # Only send budget_tokens for classic "enabled" mode
            if extended_thinking == "enabled" and budget_tokens:
                model_settings_dict["anthropic_thinking"]["budget_tokens"] = (
                    budget_tokens
                )

        # Opus 4-6 models support the `effort` setting via output_config.
        # pydantic-ai doesn't have a native field for output_config yet,
        # so we inject it through extra_body which gets merged into the
        # HTTP request body.
        if _config_module.model_supports_setting(model_name, "effort"):
            effort = effective_settings.get("effort", "high")
            if "anthropic_thinking" in model_settings_dict:
                extra_body = model_settings_dict.get("extra_body") or {}
                extra_body["output_config"] = {"effort": effort}
                model_settings_dict["extra_body"] = extra_body

        model_settings = AnthropicModelSettings(**model_settings_dict)

    # Handle Gemini thinking models (Gemini-3)
    # Check if model supports thinking settings and apply defaults
    if _config_module.model_supports_setting(model_name, "thinking_level"):
        # Apply defaults if not explicitly set by user
        # Default: thinking_enabled=True, thinking_level="low"
        if "thinking_enabled" not in model_settings_dict:
            model_settings_dict["thinking_enabled"] = True
        if "thinking_level" not in model_settings_dict:
            model_settings_dict["thinking_level"] = "low"
        # Recreate settings with Gemini thinking config
        model_settings = ModelSettings(**model_settings_dict)

    return model_settings


class ZaiChatModel(_OpenAIChatModel):
    def _process_response(self, response):
        response.object = "chat.completion"
        return super()._process_response(response)


# ─── Lazy cached ZaiCerebrasProvider class (see MEM-MF-H1) ────────────────
_ZAI_CEREBRAS_PROVIDER_CLASS: type | None = None


def _get_zai_cerebras_provider_class() -> type:
    """Return the cached ZaiCerebrasProvider class, creating it once on first call.

    This avoids leaking types across rebuilds when the class would otherwise be
    defined inline inside _build_cerebras() on every call.
    """
    global _ZAI_CEREBRAS_PROVIDER_CLASS
    if _ZAI_CEREBRAS_PROVIDER_CLASS is None:
        from pydantic_ai.profiles import ModelProfile
        from pydantic_ai.profiles.qwen import qwen_model_profile
        from pydantic_ai.providers.cerebras import CerebrasProvider

        class _ZaiCerebrasProviderImpl(CerebrasProvider):
            def model_profile(self, mn: str) -> ModelProfile | None:
                profile = super().model_profile(mn)
                if mn.startswith("zai"):
                    profile = profile.update(qwen_model_profile("qwen-3-coder"))
                return profile

        _ZAI_CEREBRAS_PROVIDER_CLASS = _ZaiCerebrasProviderImpl
    return _ZAI_CEREBRAS_PROVIDER_CLASS


def _resolve_env_var(match, key=None):
    """Helper to resolve environment variable from regex match.

    Args:
        match: The regex match object containing the env var name in group 1 or group 2
        key: Optional header key for warning messages

    Returns:
        The resolved value or empty string if not found
    """
    env_var_name = match.group(1) or match.group(2)
    resolved_value = get_api_key(env_var_name)
    if resolved_value is None:
        if key:
            emit_warning(
                f"'{env_var_name}' is not set (check config or environment) for custom endpoint header '{key}'. Proceeding with empty value."
            )
        else:
            emit_warning(
                f"'{env_var_name}' is not set (check config or environment). Proceeding with empty value."
            )
        return ""
    return resolved_value


def get_custom_config(model_config):
    custom_config = model_config.get("custom_endpoint", {})
    if not custom_config:
        raise ValueError("Custom model requires 'custom_endpoint' configuration")

    url = custom_config.get("url")
    if not url:
        raise ValueError("Custom endpoint requires 'url' field")

    headers = {}
    for key, value in custom_config.get("headers", {}).items():
        # Use pre-compiled regex for efficient environment variable substitution
        value = _ENV_VAR_RE.sub(lambda m: _resolve_env_var(m, key), value)
        headers[key] = value
    api_key = None
    if "api_key" in custom_config:
        # Use pre-compiled regex for API key substitution (supports both ${VAR} and $VAR formats)
        api_key = _ENV_VAR_RE.sub(
            lambda m: _resolve_env_var(m) or "",
            custom_config["api_key"],
        )
    if "ca_certs_path" in custom_config:
        verify = custom_config["ca_certs_path"]
    else:
        verify = None
    return url, headers, verify, api_key


# ---------------------------------------------------------------------------
# Built-in model builder functions
# Each function has the signature:
# builder(model_name: str, model_config: dict, config: dict) -> Any
# ---------------------------------------------------------------------------


def _require_api_key(env_var: str, model_config: dict) -> str | None:
    """Get an API key, emitting a warning and returning None if not found.

    This DRYs up the repeated pattern across 10+ model builder functions.
    """
    key = get_api_key(env_var)
    if not key:
        emit_warning(
            f"{env_var} is not set (check config or environment); "
            f"skipping model '{model_config.get('name')}'."
        )
    return key


def _build_openai(model_name: str, model_config: dict, config: dict) -> Any:
    from pydantic_ai.models.openai import OpenAIChatModel, OpenAIResponsesModel
    from pydantic_ai.providers.openai import OpenAIProvider

    api_key = _require_api_key("OPENAI_API_KEY", model_config)
    if not api_key:
        return None
    provider = OpenAIProvider(api_key=api_key)
    if "codex" in model_name:
        model = OpenAIResponsesModel(model_name=model_config["name"], provider=provider)
    else:
        model = OpenAIChatModel(model_name=model_config["name"], provider=provider)
    model.provider = provider
    return model


def _build_anthropic(model_name: str, model_config: dict, config: dict) -> Any:
    from anthropic import AsyncAnthropic
    from pydantic_ai.models.anthropic import AnthropicModel
    from pydantic_ai.providers.anthropic import AnthropicProvider

    from code_puppy.claude_cache_client import (
        ClaudeCacheAsyncClient,
        patch_anthropic_client_messages,
    )

    api_key = _require_api_key("ANTHROPIC_API_KEY", model_config)
    if not api_key:
        return None

    verify = get_cert_bundle_path()
    http2_enabled = get_http2()

    client = ClaudeCacheAsyncClient(verify=verify, timeout=180, http2=http2_enabled)

    effective_settings = _config_module.get_effective_model_settings(model_name)
    interleaved_thinking = effective_settings.get("interleaved_thinking", False)

    beta_header = _build_anthropic_beta_header(
        model_config, interleaved_thinking=interleaved_thinking
    )
    default_headers = {}
    if beta_header:
        default_headers["anthropic-beta"] = beta_header

    anthropic_client = AsyncAnthropic(
        api_key=api_key,
        http_client=client,
        default_headers=default_headers if default_headers else None,
    )

    patch_anthropic_client_messages(anthropic_client)

    provider = AnthropicProvider(anthropic_client=anthropic_client)
    return AnthropicModel(model_name=model_config["name"], provider=provider)


def _build_custom_anthropic(model_name: str, model_config: dict, config: dict) -> Any:
    from anthropic import AsyncAnthropic
    from pydantic_ai.models.anthropic import AnthropicModel

    from code_puppy.claude_cache_client import (
        ClaudeCacheAsyncClient,
        patch_anthropic_client_messages,
    )

    url, headers, verify, api_key = get_custom_config(model_config)
    if not api_key:
        emit_warning(
            f"API key is not set for custom Anthropic endpoint; skipping model '{model_config.get('name')}'."
        )
        return None

    if verify is None:
        verify = get_cert_bundle_path()

    http2_enabled = get_http2()

    client = ClaudeCacheAsyncClient(
        headers=headers, verify=verify, timeout=180, http2=http2_enabled
    )

    effective_settings = _config_module.get_effective_model_settings(model_name)
    interleaved_thinking = effective_settings.get("interleaved_thinking", False)

    beta_header = _build_anthropic_beta_header(
        model_config, interleaved_thinking=interleaved_thinking
    )
    default_headers: dict = {}
    if beta_header:
        default_headers["anthropic-beta"] = beta_header

    anthropic_client = AsyncAnthropic(
        base_url=url,
        http_client=client,
        api_key=api_key,
        default_headers=default_headers if default_headers else None,
    )

    patch_anthropic_client_messages(anthropic_client)

    provider_name = resolve_provider_identity(model_name, model_config)
    provider = make_anthropic_provider(provider_name, anthropic_client=anthropic_client)
    return AnthropicModel(model_name=model_config["name"], provider=provider)


# NOTE: 'claude_code' model type is now handled by the claude_code_oauth plugin
# via the register_model_type callback. See plugins/claude_code_oauth/register_callbacks.py


def _build_azure_openai(model_name: str, model_config: dict, config: dict) -> Any:
    from openai import AsyncAzureOpenAI
    from pydantic_ai.models.openai import OpenAIChatModel
    from pydantic_ai.providers.openai import OpenAIProvider

    azure_endpoint_config = model_config.get("azure_endpoint")
    if not azure_endpoint_config:
        raise ValueError(
            "Azure OpenAI model type requires 'azure_endpoint' in its configuration."
        )
    azure_endpoint = azure_endpoint_config
    if azure_endpoint_config.startswith("$"):
        azure_endpoint = get_api_key(azure_endpoint_config[1:])
    if not azure_endpoint:
        emit_warning(
            f"Azure OpenAI endpoint '{azure_endpoint_config[1:] if azure_endpoint_config.startswith('$') else azure_endpoint_config}' not found (check config or environment); skipping model '{model_config.get('name')}'."
        )
        return None

    api_version_config = model_config.get("api_version")
    if not api_version_config:
        raise ValueError(
            "Azure OpenAI model type requires 'api_version' in its configuration."
        )
    api_version = api_version_config
    if api_version_config.startswith("$"):
        api_version = get_api_key(api_version_config[1:])
    if not api_version:
        emit_warning(
            f"Azure OpenAI API version '{api_version_config[1:] if api_version_config.startswith('$') else api_version_config}' not found (check config or environment); skipping model '{model_config.get('name')}'."
        )
        return None

    api_key_config = model_config.get("api_key")
    if not api_key_config:
        raise ValueError(
            "Azure OpenAI model type requires 'api_key' in its configuration."
        )
    api_key = api_key_config
    if api_key_config.startswith("$"):
        api_key = get_api_key(api_key_config[1:])
    if not api_key:
        emit_warning(
            f"Azure OpenAI API key '{api_key_config[1:] if api_key_config.startswith('$') else api_key_config}' not found (check config or environment); skipping model '{model_config.get('name')}'."
        )
        return None

    azure_max_retries = model_config.get("max_retries", 2)

    azure_client = AsyncAzureOpenAI(
        azure_endpoint=azure_endpoint,
        api_version=api_version,
        api_key=api_key,
        max_retries=azure_max_retries,
    )
    provider = OpenAIProvider(openai_client=azure_client)
    model = OpenAIChatModel(model_name=model_config["name"], provider=provider)
    model.provider = provider
    return model


def _build_custom_openai(model_name: str, model_config: dict, config: dict) -> Any:
    from pydantic_ai.models.openai import OpenAIChatModel, OpenAIResponsesModel
    from pydantic_ai.providers.openai import OpenAIProvider

    url, headers, verify, api_key = get_custom_config(model_config)
    client = create_async_client(headers=headers, verify=verify)
    provider_args: dict = {"base_url": url}
    if isinstance(client, httpx.AsyncClient):
        provider_args["http_client"] = client
    if api_key:
        provider_args["api_key"] = api_key
    provider = OpenAIProvider(**provider_args)
    if model_name == "chatgpt-gpt-5-codex":
        model = OpenAIResponsesModel(model_config["name"], provider=provider)
    else:
        model = OpenAIChatModel(model_name=model_config["name"], provider=provider)
    model.provider = provider
    return model


def _build_zai_coding(model_name: str, model_config: dict, config: dict) -> Any:
    from pydantic_ai.providers.openai import OpenAIProvider

    api_key = _require_api_key("ZAI_API_KEY", model_config)
    if not api_key:
        return None
    provider = OpenAIProvider(
        api_key=api_key, base_url="https://api.z.ai/api/coding/paas/v4"
    )
    zai_model = ZaiChatModel(model_name=model_config["name"], provider=provider)
    zai_model.provider = provider
    return zai_model


def _build_zai_api(model_name: str, model_config: dict, config: dict) -> Any:
    from pydantic_ai.providers.openai import OpenAIProvider

    api_key = _require_api_key("ZAI_API_KEY", model_config)
    if not api_key:
        return None
    provider = OpenAIProvider(api_key=api_key, base_url="https://api.z.ai/api/paas/v4/")
    zai_model = ZaiChatModel(model_name=model_config["name"], provider=provider)
    zai_model.provider = provider
    return zai_model


def _build_cerebras(model_name: str, model_config: dict, config: dict) -> Any:
    from pydantic_ai.models.openai import OpenAIChatModel

    # Use the cached provider class to avoid leaking types across rebuilds
    ZaiCerebrasProvider = _get_zai_cerebras_provider_class()

    url, headers, verify, api_key = get_custom_config(model_config)
    if not api_key:
        emit_warning(
            f"API key is not set for Cerebras endpoint; skipping model '{model_config.get('name')}'."
        )
        return None
    # Add Cerebras 3rd party integration header
    headers["X-Cerebras-3rd-Party-Integration"] = "code-puppy"
    # Pass "cerebras" so RetryingAsyncClient knows to ignore Cerebras's
    # absurdly aggressive Retry-After headers (they send 60s!)
    client = create_async_client(headers=headers, verify=verify, model_name="cerebras")
    provider = ZaiCerebrasProvider(api_key=api_key, http_client=client)
    model = OpenAIChatModel(model_name=model_config["name"], provider=provider)
    model.provider = provider
    return model


def _build_openrouter(model_name: str, model_config: dict, config: dict) -> Any:
    from pydantic_ai.models.openai import OpenAIChatModel
    from pydantic_ai.providers.openrouter import OpenRouterProvider

    api_key_config = model_config.get("api_key")
    api_key = None

    if api_key_config:
        if api_key_config.startswith("$"):
            env_var_name = api_key_config[1:]
            api_key = get_api_key(env_var_name)
            if api_key is None:
                emit_warning(
                    f"OpenRouter API key '{env_var_name}' not found (check config or environment); skipping model '{model_config.get('name')}'."
                )
                return None
        else:
            api_key = api_key_config
    else:
        api_key = get_api_key("OPENROUTER_API_KEY")
        if api_key is None:
            emit_warning(
                f"OPENROUTER_API_KEY is not set (check config or environment); skipping OpenRouter model '{model_config.get('name')}'."
            )
            return None

    provider = OpenRouterProvider(api_key=api_key)
    model = OpenAIChatModel(model_name=model_config["name"], provider=provider)
    model.provider = provider
    return model


def _build_round_robin(model_name: str, model_config: dict, config: dict) -> Any:
    from code_puppy.round_robin_model import RoundRobinModel

    model_names = model_config.get("models")
    if not model_names or not isinstance(model_names, list):
        raise ValueError(
            f"Round-robin model '{model_name}' requires a 'models' list in its configuration."
        )

    rotate_every = model_config.get("rotate_every", 1)

    models = [ModelFactory.get_model(name, config) for name in model_names]
    return RoundRobinModel(*models, rotate_every=rotate_every)


# ---------------------------------------------------------------------------
# Register all built-in builders at module load
# ---------------------------------------------------------------------------
_BUILTIN_MODEL_BUILDERS: dict[str, Callable] = {
    "openai": _build_openai,
    "anthropic": _build_anthropic,
    "custom_anthropic": _build_custom_anthropic,
    "azure_openai": _build_azure_openai,
    "custom_openai": _build_custom_openai,
    "zai_coding": _build_zai_coding,
    "zai_api": _build_zai_api,
    "cerebras": _build_cerebras,
    "openrouter": _build_openrouter,
    "round_robin": _build_round_robin,
}

for _type_name, _builder in _BUILTIN_MODEL_BUILDERS.items():
    register_model_builder(_type_name, _builder)


# ---------------------------------------------------------------------------
# Quota / availability exception helpers
# ---------------------------------------------------------------------------

# HTTP status codes that indicate exhausted quota (terminal failure).
_TERMINAL_STATUS_CODES: frozenset[int] = frozenset({402, 429})

# Keywords that hint at capacity / quota exhaustion in exception messages.
_TERMINAL_KEYWORDS: tuple[str, ...] = (
    "quota",
    "rate limit",
    "ratelimit",
    "resource_exhausted",
    "resourceexhausted",
    "too many requests",
    "capacity",
    "insufficient_quota",
)


def _get_status_code_from_exc(exc: BaseException) -> int | None:
    """Extract HTTP status code from exception or its nested response.

    Checks exc.status_code, exc.status, then exc.response.status_code,
    exc.response.status. Returns the first valid integer found, or None.
    """
    # Direct attributes on exception (httpx, requests, pydantic-ai, openai ...)
    code = getattr(exc, "status_code", None)
    if isinstance(code, int):
        return code

    code = getattr(exc, "status", None)
    if isinstance(code, int):
        return code

    # Some SDKs nest the response: exc.response.status_code
    response_obj = getattr(exc, "response", None)
    if response_obj is not None:
        code = getattr(response_obj, "status_code", None)
        if isinstance(code, int):
            return code

        code = getattr(response_obj, "status", None)
        if isinstance(code, int):
            return code

    return None


def is_quota_exception(exc: BaseException) -> bool:
    """Return True when *exc* looks like a terminal quota / rate-limit error.

    Inspects:
    * ``response.status_code`` / ``status_code`` attributes on the exception.
    * The stringified exception message for well-known quota keywords.

    This avoids hard dependencies on any specific SDK exception hierarchy and
    therefore works across OpenAI, Anthropic, Gemini, and custom providers.
    """
    # Check for status code on exception or nested response
    code = _get_status_code_from_exc(exc)
    if code is not None and code in _TERMINAL_STATUS_CODES:
        return True

    # Keyword scan on the string representation (covers gRPC ResourceExhausted etc.)
    msg = str(exc).lower()
    return any(kw in msg for kw in _TERMINAL_KEYWORDS)


# --- Model config caching (eliminates repeated disk reads) ---
_model_config_cache: MappingProxyType | None = None
_model_config_mtimes: dict[str, float] = {}
_model_config_lock = threading.Lock()


def _freeze_nested(obj: Any) -> Any:
    """Recursively convert nested dicts to MappingProxyType for immutability.

    Ensures that deeply nested structures in the cache cannot be modified,
    providing true nested immutability for the model configuration cache.
    """
    if isinstance(obj, dict):
        # Recursively freeze all values, then wrap in MappingProxyType
        frozen_dict = {k: _freeze_nested(v) for k, v in obj.items()}
        return MappingProxyType(frozen_dict)
    elif isinstance(obj, list):
        # Recursively freeze all items in lists
        return [_freeze_nested(item) for item in obj]
    elif isinstance(obj, tuple):
        # Recursively freeze all items in tuples
        return tuple(_freeze_nested(item) for item in obj)
    else:
        # Primitive type - return as-is
        return obj


def invalidate_model_config_cache() -> None:
    """Force next ModelFactory.load_config() call to re-read from disk."""
    global _model_config_cache
    with _model_config_lock:
        _model_config_cache = None


def _call_elixir_model_registry(method: str, params: dict | None = None) -> dict | None:
    """Call a model_registry method on the Elixir control plane.

    Tries to use the Elixir bridge if available. Returns the result dict
    on success, or None if bridge is unavailable or call fails.

    Args:
        method: Method name (e.g., "get_config", "list_models")
        params: Optional parameters dict

    Returns:
        Response result dict from Elixir, or None if unavailable/error
    """
    try:
        from code_puppy.plugins.elixir_bridge import call_method, is_connected

        if not is_connected():
            return None

        # Call the model_registry method via the bridge
        full_method = f"model_registry.{method}"
        result = call_method(full_method, params or {}, timeout=5.0)
        return result
    except Exception:
        # Bridge unavailable or call failed - return None to trigger fallback
        return None


class ModelFactory:
    """A factory for creating and managing different AI models."""

    @staticmethod
    def load_config() -> dict[str, Any]:
        global _model_config_cache, _model_config_mtimes
        # Check if any source file has changed since last cache
        # Use module-level _config_module imports so that monkeypatch in tests can override them

        source_files = [
            pathlib.Path(__file__).parent / "models.json",
            pathlib.Path(EXTRA_MODELS_FILE),
            pathlib.Path(_config_module.CHATGPT_MODELS_FILE),
            pathlib.Path(_config_module.CLAUDE_MODELS_FILE),
        ]

        # Build current mtimes for existing files
        current_mtimes: dict[str, float] = {}
        for p in source_files:
            try:
                current_mtimes[str(p)] = p.stat().st_mtime
            except OSError:
                pass  # File doesn't exist

        # Check cache with lock - fast path for cache hits
        with _model_config_lock:
            if (
                _model_config_cache is not None
                and current_mtimes == _model_config_mtimes
            ):
                return _model_config_cache

        load_model_config_callbacks = callbacks.get_callbacks("load_model_config")
        if len(load_model_config_callbacks) > 0:
            if len(load_model_config_callbacks) > 1:
                logging.getLogger(__name__).warning(
                    "Multiple load_model_config callbacks registered, using the first"
                )
            config = callbacks.on_load_model_config()[0]
        else:
            # Try Elixir bridge first for model configuration
            bridge_result = _call_elixir_model_registry("get_all_configs")
            if bridge_result and "configs" in bridge_result:
                config = bridge_result["configs"]
                logging.getLogger(__name__).debug(
                    "Loaded model config from Elixir bridge (%d models)", len(config)
                )
            else:
                # Always load from the bundled models.json so upstream
                # updates propagate automatically. User additions belong
                # in extra_models.json (overlay loaded below).
                bundled_models = pathlib.Path(__file__).parent / "models.json"
                with open(bundled_models, "r") as f:
                    config = json.load(f)

        # Build list of extra model sources
        extra_sources: list[tuple[pathlib.Path, str, bool]] = [
            (pathlib.Path(EXTRA_MODELS_FILE), "extra models", False),
            (
                pathlib.Path(_config_module.CHATGPT_MODELS_FILE),
                "ChatGPT OAuth models",
                False,
            ),
            (
                pathlib.Path(_config_module.CLAUDE_MODELS_FILE),
                "Claude Code OAuth models",
                True,
            ),
        ]

        for source_path, label, use_filtered in extra_sources:
            if not source_path.exists():
                continue
            try:
                # Use filtered loading for Claude Code OAuth models to show only latest versions
                if use_filtered:
                    try:
                        from code_puppy.plugins.claude_code_oauth.utils import (
                            load_claude_models_filtered,
                        )

                        extra_config = load_claude_models_filtered()
                    except ImportError:
                        # Plugin not available, fall back to standard JSON loading
                        logging.getLogger(__name__).debug(
                            f"claude_code_oauth plugin not available, loading {label} as plain JSON"
                        )
                        with open(source_path, "r") as f:
                            extra_config = json.load(f)
                else:
                    with open(source_path, "r") as f:
                        extra_config = json.load(f)
                config.update(extra_config)
            except json.JSONDecodeError as exc:
                logging.getLogger(__name__).warning(
                    f"Failed to load {label} config from {source_path}: Invalid JSON - {exc}"
                )
            except Exception as exc:
                logging.getLogger(__name__).warning(
                    f"Failed to load {label} config from {source_path}: {exc}"
                )

        # Let plugins add/override models via load_models_config hook
        try:
            from code_puppy.callbacks import on_load_models_config

            results = on_load_models_config()
            for result in results:
                if isinstance(result, dict):
                    config.update(result)  # Plugin models override built-in
        except Exception as exc:
            logging.getLogger(__name__).debug(
                f"Failed to load plugin models config: {exc}"
            )

        # Populate cache with nested immutability
        frozen = _freeze_nested(config)
        with _model_config_lock:
            _model_config_cache = frozen
            _model_config_mtimes.clear()
            _model_config_mtimes.update(current_mtimes)
        return frozen

    @staticmethod
    def get_config_from_bridge(model_name: str) -> dict[str, Any] | None:
        """Get model config from Elixir bridge.

        Tries to resolve model configuration via the Elixir bridge.
        Returns None if bridge is unavailable or model not found.

        Args:
            model_name: Name of the model to look up

        Returns:
            Model config dict, or None if not available
        """
        result = _call_elixir_model_registry("get_config", {"model_name": model_name})
        if result and result.get("config"):
            return result["config"]
        return None

    @staticmethod
    def get_model(model_name: str, config: dict[str, Any]) -> Any:
        """Returns a configured model instance based on the provided name and config.

        Raises ValueError if the model cannot be initialized (e.g. missing API
        keys, bad configuration, or unsupported model type). Callers such as
        ``_load_model_with_fallback`` already catch ``ValueError`` and attempt
        a fallback, so raising here enables automatic recovery.
        """
        model_config = config.get(model_name)

        # Try Elixir bridge if config not found locally
        if not model_config:
            model_config = ModelFactory.get_config_from_bridge(model_name)

        if not model_config:
            raise ValueError(f"Model '{model_name}' not found in configuration.")

        model_type = model_config.get("type")

        def _check_result(result: Any, source: str) -> Any:
            """Raise if a builder / provider returned None."""
            if result is None:
                raise ValueError(
                    f"Model '{model_name}' (type='{model_type}') could not be "
                    f"initialized by {source}. Check that required API keys and "
                    f"configuration are set."
                )
            return result

        # Ensure plugin model providers are loaded (lazy initialization)
        _load_plugin_model_providers()

        # Check for plugin-registered model provider classes first
        if model_type in _CUSTOM_MODEL_PROVIDERS:
            provider_class = _CUSTOM_MODEL_PROVIDERS[model_type]
            try:
                result = provider_class(
                    model_name=model_name, model_config=model_config, config=config
                )
                return _check_result(result, f"custom provider '{model_type}'")
            except ValueError:
                raise  # Re-raise ValueError from _check_result
            except Exception as e:
                raise ValueError(
                    f"Model '{model_name}': custom provider '{model_type}' failed: {e}"
                ) from e

        # Look up the builder in the registry
        builder = _MODEL_BUILDERS.get(model_type)
        if builder is not None:
            result = builder(model_name, model_config, config)
            return _check_result(result, f"builder '{model_type}'")

        # Fall back to plugin-registered model type handlers
        registered_handlers = callbacks.on_register_model_types()
        for handler_info in registered_handlers:
            handlers = (
                handler_info
                if isinstance(handler_info, list)
                else [handler_info]
                if handler_info
                else []
            )
            for handler_entry in handlers:
                if not isinstance(handler_entry, dict):
                    continue
                if handler_entry.get("type") == model_type:
                    handler = handler_entry.get("handler")
                    if callable(handler):
                        try:
                            result = handler(model_name, model_config, config)
                            return _check_result(
                                result, f"plugin handler '{model_type}'"
                            )
                        except ValueError:
                            raise  # Re-raise ValueError from _check_result
                        except Exception as e:
                            raise ValueError(
                                f"Model '{model_name}': plugin handler "
                                f"'{model_type}' failed: {e}"
                            ) from e

        raise ValueError(f"Unsupported model type: {model_type}")
