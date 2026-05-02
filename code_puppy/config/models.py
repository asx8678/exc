"""Model configuration accessors.

Mirrors ``CodePuppyControl.Config.Models`` in the Elixir runtime.

Manages the globally selected model, per-model settings (temperature,
top_p, seed), agent-to-model pinning, and OpenAI-specific reasoning
parameters.

Config keys in puppy.cfg:

- ``model`` — global model name
- ``temperature`` — global temperature override (0.0–2.0)
- ``model_settings_<sanitized>_<setting>`` — per-model setting
- ``agent_model_<agent_name>`` — agent-to-model pinning
- ``openai_reasoning_effort`` — minimal/low/medium/high/xhigh
- ``openai_reasoning_summary`` — auto/concise/detailed
- ``openai_verbosity`` — low/medium/high
"""

from __future__ import annotations

# Import runtime_state for session model caching
from code_puppy import runtime_state
from code_puppy.config.loader import (
    _SANITIZE_MODEL_NAME_RE,
    DEFAULT_SECTION,
    _get_config,
    _invalidate_config,
    _path_config_file,
    _registered_cache,
    _state,
    get_value,
    set_config_value,
)
from code_puppy.config_paths import assert_write_allowed as _assert_write_allowed

__all__ = [
    "set_model_name",
    "get_global_model_name",
    "model_supports_setting",
    "clear_model_cache",
    "reset_session_model",
    "get_openai_reasoning_effort",
    "set_openai_reasoning_effort",
    "get_openai_reasoning_summary",
    "set_openai_reasoning_summary",
    "get_openai_verbosity",
    "set_openai_verbosity",
    "get_temperature",
    "set_temperature",
    "get_effective_temperature",
    "get_effective_model_settings",
    "get_model_setting",
    "set_model_setting",
    "get_all_model_settings",
    "clear_model_settings",
    "get_agent_pinned_model",
    "set_agent_pinned_model",
    "clear_agent_pinned_model",
    "get_agents_pinned_to_model",
    "get_all_agent_pinned_models",
    "get_model_context_length",
]


# ---------------------------------------------------------------------------
# Model resolution helpers
# ---------------------------------------------------------------------------


def _default_model_from_models_json() -> str:
    """Load the default model name from models.json.

    Returns the first model in models.json as the default.
    Falls back to ``gpt-5`` if the file cannot be read.
    """
    if _state.default_model_cache is not None:
        return _state.default_model_cache

    try:
        from code_puppy.model_factory import ModelFactory

        models_config = ModelFactory.load_config()
        if models_config:
            first_key = next(iter(models_config))
            _state.default_model_cache = first_key
            return first_key
        _state.default_model_cache = "gpt-5"
        return "gpt-5"
    except Exception:
        _state.default_model_cache = "gpt-5"
        return "gpt-5"


def _default_vision_model_from_models_json() -> str:
    """Select a default vision-capable model from models.json with caching."""
    if _state.default_vision_model_cache is not None:
        return _state.default_vision_model_cache

    try:
        from code_puppy.model_factory import ModelFactory

        models_config = ModelFactory.load_config()
        if models_config:
            for name, config in models_config.items():
                if config.get("supports_vision"):
                    _state.default_vision_model_cache = name
                    return name

            preferred_candidates = (
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
                "claude-4-0-sonnet",
                "gemini-2.5-flash-preview-05-20",
            )
            for candidate in preferred_candidates:
                if candidate in models_config:
                    _state.default_vision_model_cache = candidate
                    return candidate

            _state.default_vision_model_cache = _default_model_from_models_json()
            return _state.default_vision_model_cache

        _state.default_vision_model_cache = "gpt-4.1"
        return "gpt-4.1"
    except Exception:
        _state.default_vision_model_cache = "gpt-4.1"
        return "gpt-4.1"


def _validate_model_exists(model_name: str) -> bool:
    """Check if a model exists in models.json with caching."""
    if model_name in _state.model_validation_cache:
        return _state.model_validation_cache[model_name]

    try:
        from code_puppy.model_factory import ModelFactory

        models_config = ModelFactory.load_config()
        exists = model_name in models_config
        _state.model_validation_cache[model_name] = exists
        return exists
    except Exception:
        _state.model_validation_cache[model_name] = True
        return True


def clear_model_cache() -> None:
    """Clear the model validation cache. Call this when models.json changes."""
    _state.model_validation_cache.clear()
    _state.default_model_cache = None
    _state.default_vision_model_cache = None
    if _state.supported_settings_cache is not None:
        _state.supported_settings_cache.cache_clear()
        _state.supported_settings_cache = None


def reset_session_model() -> None:
    """Reset the session-local model cache."""
    runtime_state.reset_session_model()


def _get_supported_settings_cache():
    """Return the LRU cache function for supported settings."""
    from code_puppy.utils.thread_safe_cache import thread_safe_lru_cache

    if _state.supported_settings_cache is None:

        @thread_safe_lru_cache(maxsize=128)
        def _cached_supported_settings(model_name: str) -> frozenset:
            from code_puppy.model_factory import ModelFactory

            models_config = ModelFactory.load_config()
            model_config = models_config.get(model_name, {})
            supported_settings = model_config.get("supported_settings")
            if supported_settings is None:
                if "claude" in model_name.lower():
                    return frozenset(
                        {"temperature", "top_p", "thinking", "clear_thinking"}
                    )
                return frozenset({"temperature", "top_p", "seed"})
            return frozenset(supported_settings)

        _state.supported_settings_cache = _cached_supported_settings
    return _state.supported_settings_cache


# ---------------------------------------------------------------------------
# Global model name
# ---------------------------------------------------------------------------


def get_global_model_name() -> str:
    """Return a valid model name for Code Puppy to use.

    Uses session-local caching so that model changes in other terminals
    don't affect this running instance.
    """
    cached_model = runtime_state.get_session_model()
    if cached_model is not None:
        return cached_model

    stored_model = get_value("model")
    if stored_model:
        if _validate_model_exists(stored_model):
            runtime_state.set_session_model(stored_model)
            return stored_model

    default_model = _default_model_from_models_json()
    runtime_state.set_session_model(default_model)
    return default_model


def set_model_name(model: str) -> None:
    """Sets the model name in both the session cache and persistent config file."""
    runtime_state.set_session_model(model)

    config = _get_config()
    if DEFAULT_SECTION not in config:
        config[DEFAULT_SECTION] = {}
    config[DEFAULT_SECTION]["model"] = model or ""

    config_file = _path_config_file()
    _assert_write_allowed(config_file, "set_model_name")
    with open(str(config_file), "w", encoding="utf-8") as f:
        config.write(f)
    _invalidate_config()
    clear_model_cache()


def model_supports_setting(model_name: str, setting: str) -> bool:
    """Check if a model supports a particular setting."""
    if setting == "clear_thinking" and (
        "glm-4.7" in model_name.lower() or "glm-5" in model_name.lower()
    ):
        return True

    try:
        cache_func = _get_supported_settings_cache()
        supported_settings = cache_func(model_name)
        return setting in supported_settings
    except Exception:
        return True


# ---------------------------------------------------------------------------
# Context length
# ---------------------------------------------------------------------------


def _get_model_context_length(model_name: str) -> int:
    """Return context length for a model (cached)."""
    if model_name in _state.model_context_length_cache:
        return _state.model_context_length_cache[model_name]

    _KNOWN_CONTEXT_LENGTHS = {
        "claude-3": 200000,
        "claude-3-5": 200000,
        "claude-4": 200000,
        "gpt-4-turbo": 128000,
        "gpt-4o": 128000,
        "gpt-5": 128000,
        "gemini-1.5": 1000000,
        "gemini-2": 1000000,
    }
    for prefix, length in _KNOWN_CONTEXT_LENGTHS.items():
        if model_name.startswith(prefix):
            _state.model_context_length_cache[model_name] = length
            return length

    _state.model_context_length_cache[model_name] = 128000
    return 128000


def get_model_context_length(model_name: str | None = None) -> int:
    """Return model context length (uses active model if not specified)."""
    if model_name is None:
        model_name = get_global_model_name()
    return _get_model_context_length(model_name)


# ---------------------------------------------------------------------------
# OpenAI settings
# ---------------------------------------------------------------------------


@_registered_cache
def get_openai_reasoning_effort() -> str:
    """Return the configured OpenAI reasoning effort."""
    allowed_values = {"minimal", "low", "medium", "high", "xhigh"}
    configured = (get_value("openai_reasoning_effort") or "medium").strip().lower()
    if configured not in allowed_values:
        return "medium"
    return configured


def set_openai_reasoning_effort(value: str) -> None:
    """Persist the OpenAI reasoning effort."""
    allowed_values = {"minimal", "low", "medium", "high", "xhigh"}
    normalized = value.strip().lower()
    if normalized not in allowed_values:
        from code_puppy.messaging import emit_error

        emit_error(
            f"Invalid reasoning effort '{value}'. "
            f"Allowed: {', '.join(sorted(allowed_values))}"
        )
        return
    set_config_value("openai_reasoning_effort", normalized)


@_registered_cache
def get_openai_reasoning_summary() -> str:
    """Return the configured OpenAI reasoning summary mode."""
    allowed_values = {"auto", "concise", "detailed"}
    configured = (get_value("openai_reasoning_summary") or "auto").strip().lower()
    if configured not in allowed_values:
        return "auto"
    return configured


def set_openai_reasoning_summary(value: str) -> None:
    """Persist the OpenAI reasoning summary mode."""
    allowed_values = {"auto", "concise", "detailed"}
    normalized = value.strip().lower()
    if normalized not in allowed_values:
        from code_puppy.messaging import emit_error

        emit_error(
            f"Invalid reasoning summary '{value}'. "
            f"Allowed: {', '.join(sorted(allowed_values))}"
        )
        return
    set_config_value("openai_reasoning_summary", normalized)


@_registered_cache
def get_openai_verbosity() -> str:
    """Return the configured OpenAI verbosity."""
    allowed_values = {"low", "medium", "high"}
    configured = (get_value("openai_verbosity") or "medium").strip().lower()
    if configured not in allowed_values:
        return "medium"
    return configured


def set_openai_verbosity(value: str) -> None:
    """Persist the OpenAI verbosity."""
    allowed_values = {"low", "medium", "high"}
    normalized = value.strip().lower()
    if normalized not in allowed_values:
        from code_puppy.messaging import emit_error

        emit_error(
            f"Invalid verbosity '{value}'. Allowed: {', '.join(sorted(allowed_values))}"
        )
        return
    set_config_value("openai_verbosity", normalized)


# ---------------------------------------------------------------------------
# Temperature
# ---------------------------------------------------------------------------


@_registered_cache
def get_temperature() -> float | None:
    """Return the global temperature (0.0–2.0) or None if not configured."""
    val = get_value("temperature")
    if val is None or val.strip() == "":
        return None
    try:
        result = float(val)
        return max(0.0, min(2.0, result))
    except ValueError, TypeError:
        return None


def set_temperature(value: float | None) -> None:
    """Set the global temperature. Pass None to clear."""
    if value is None:
        from code_puppy.config.loader import reset_value

        reset_value("temperature")
    else:
        clamped = max(0.0, min(2.0, value))
        set_config_value("temperature", str(clamped))


# ---------------------------------------------------------------------------
# Per-model settings
# ---------------------------------------------------------------------------


def _sanitize_model_name_for_key(model_name: str) -> str:
    """Sanitize a model name for use as a config key prefix."""
    return _SANITIZE_MODEL_NAME_RE.sub("_", model_name).lower()


def get_model_setting(model_name: str, setting: str) -> float | bool | str | None:
    """Get a specific setting for a model. Returns None if not set."""
    # Check cache first (fixes CFG-H1)
    cache_key = f"{model_name}:{setting}"
    cached = _state.model_settings_cache.get(cache_key)
    if cached is not None:
        return cached

    key = f"model_settings_{_sanitize_model_name_for_key(model_name)}_{setting}"
    val = get_value(key)
    if val is None or val.strip() == "":
        return None

    result = _parse_setting_value(val)
    _state.model_settings_cache[cache_key] = result
    return result


def set_model_setting(model_name: str, setting: str, value: float | None) -> None:
    """Set a specific setting for a model. Pass None to clear."""
    key = f"model_settings_{_sanitize_model_name_for_key(model_name)}_{setting}"
    if value is None:
        set_config_value(key, "")
    else:
        if isinstance(value, float):
            value = round(value, 2)
        set_config_value(key, str(value))
    # Invalidate per-model settings cache
    cache_key = f"{model_name}:{setting}"
    _state.model_settings_cache.pop(cache_key, None)


def get_all_model_settings(model_name: str) -> dict:
    """Get all settings for a model as a dict."""
    prefix = f"model_settings_{_sanitize_model_name_for_key(model_name)}_"
    config = _get_config()

    if DEFAULT_SECTION not in config:
        return {}

    result = {}
    for k, v in config.items(DEFAULT_SECTION):
        if k.startswith(prefix) and v:
            setting = k[len(prefix) :]
            result[setting] = _parse_setting_value(v)
    return result


def clear_model_settings(model_name: str) -> None:
    """Clear all settings for a model."""
    prefix = f"model_settings_{_sanitize_model_name_for_key(model_name)}_"
    config = _get_config()
    keys_to_clear = (
        [k for k in config[DEFAULT_SECTION] if k.startswith(prefix)]
        if DEFAULT_SECTION in config
        else []
    )

    for key in keys_to_clear:
        set_config_value(key, "")

    # Clear cache entries
    keys_to_remove = [
        k for k in _state.model_settings_cache if k.startswith(f"{model_name}:")
    ]
    for k in keys_to_remove:
        del _state.model_settings_cache[k]


def get_effective_model_settings(model_name: str | None = None) -> dict:
    """Get the effective settings for a model (merges global + per-model)."""
    if model_name is None:
        model_name = get_global_model_name()

    result = {}
    temp = get_temperature()
    if temp is not None:
        result["temperature"] = temp

    per_model = get_all_model_settings(model_name)
    result.update(per_model)
    return result


def get_effective_temperature(model_name: str | None = None) -> float | None:
    """Return the effective temperature for a model (per-model > global)."""
    if model_name is None:
        model_name = get_global_model_name()
    per_model = get_model_setting(model_name, "temperature")
    if per_model is not None:
        return per_model
    return get_temperature()


def get_effective_top_p(model_name: str | None = None) -> float | None:
    """Return the effective top_p for a model."""
    if model_name is None:
        model_name = get_global_model_name()
    return get_model_setting(model_name, "top_p")


def get_effective_seed(model_name: str | None = None) -> int | None:
    """Return the effective seed for a model."""
    if model_name is None:
        model_name = get_global_model_name()
    val = get_model_setting(model_name, "seed")
    if val is not None and isinstance(val, (int, float)):
        return int(val)
    return None


# ---------------------------------------------------------------------------
# Agent-model pinning
# ---------------------------------------------------------------------------


def get_agent_pinned_model(agent_name: str) -> str | None:
    """Get the pinned model for a specific agent."""
    return get_value(f"agent_model_{agent_name}")


def set_agent_pinned_model(agent_name: str, model_name: str) -> None:
    """Set the pinned model for a specific agent."""
    set_config_value(f"agent_model_{agent_name}", model_name)


def clear_agent_pinned_model(agent_name: str) -> None:
    """Clear the pinned model for a specific agent."""
    set_config_value(f"agent_model_{agent_name}", "")


def get_all_agent_pinned_models() -> dict[str, str]:
    """Get all agent-to-model pinnings from config."""
    config = _get_config()
    if DEFAULT_SECTION not in config:
        return {}
    return {
        key[len("agent_model_") :]: value
        for key, value in config.items(DEFAULT_SECTION)
        if key.startswith("agent_model_") and value
    }


def get_agents_pinned_to_model(model_name: str) -> list[str]:
    """Get all agents pinned to a specific model."""
    all_pinnings = get_all_agent_pinned_models()
    return [agent for agent, model in all_pinnings.items() if model == model_name]


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


def _parse_setting_value(val: str) -> float | bool | str:
    """Parse a config setting value string to the appropriate type."""
    if val.lower() in ("true", "false"):
        return val.lower() == "true"
    try:
        return int(val)
    except ValueError:
        pass
    try:
        return float(val)
    except ValueError:
        return val
