"""Centralized model type configuration and builder registry.

This module provides a single source of truth for model type handling,
consolidating model builder registration and type resolution that was
previously spread across model_factory.py, routing strategies, and plugins.

Part of the model configuration centralization effort (issues #965, #966, #967).
"""

import logging
from collections.abc import Callable
from typing import Any

logger = logging.getLogger(__name__)

# Registry for model builder functions: model_type -> builder callable
# Signature: builder(model_name: str, model_config: dict, config: dict) -> Any
_MODEL_BUILDERS: dict[str, Callable] = {}

# Registry for custom model provider classes from plugins
_CUSTOM_MODEL_PROVIDERS: dict[str, type] = {}

# Track whether plugin providers have been loaded
_providers_loaded = False


def register_model_builder(type_name: str, builder: Callable) -> None:
    """Register a builder function for a model type.

    The builder must have the signature:
        builder(model_name: str, model_config: dict, config: dict) -> Any

    Built-in model types are registered at module load. Plugins can call this
    function to add or override builders for additional model types.

    Args:
        type_name: The model type string (e.g. "openai", "anthropic").
        builder: Callable that constructs and returns the model instance.
    """
    _MODEL_BUILDERS[type_name] = builder


def register_custom_provider(type_name: str, provider_class: type) -> None:
    """Register a custom model provider class for a model type.

    Custom providers are checked before the builder registry and allow plugins
    to provide their own model implementation classes.

    Args:
        type_name: The model type string (e.g. "claude_code", "antigravity").
        provider_class: Provider class that accepts (model_name, model_config, config).
    """
    _CUSTOM_MODEL_PROVIDERS[type_name] = provider_class


def get_model_builder(model_type: str) -> Callable | None:
    """Get the builder function for a model type.

    Args:
        model_type: The model type string.

    Returns:
        The builder callable, or None if not found.
    """
    return _MODEL_BUILDERS.get(model_type)


def get_custom_provider(model_type: str) -> type | None:
    """Get the custom provider class for a model type.

    Args:
        model_type: The model type string.

    Returns:
        The provider class, or None if not found.
    """
    return _CUSTOM_MODEL_PROVIDERS.get(model_type)


def get_all_model_types() -> set[str]:
    """Get all registered model types (both builders and custom providers).

    Returns:
        Set of all registered model type strings.
    """
    return set(_MODEL_BUILDERS.keys()) | set(_CUSTOM_MODEL_PROVIDERS.keys())


def is_model_type_supported(model_type: str) -> bool:
    """Check if a model type is supported (has a builder or custom provider).

    Args:
        model_type: The model type string.

    Returns:
        True if the model type has a registered handler.
    """
    return model_type in _MODEL_BUILDERS or model_type in _CUSTOM_MODEL_PROVIDERS


def load_plugin_providers() -> None:
    """Load custom model providers from plugins.

    This is called lazily on first use to avoid import-time side effects.
    Safe to call multiple times - only loads once.
    """
    global _providers_loaded
    if _providers_loaded:
        return
    _providers_loaded = True

    try:
        from code_puppy.callbacks import on_register_model_providers

        results = on_register_model_providers()
        for result in results:
            if isinstance(result, dict):
                _CUSTOM_MODEL_PROVIDERS.update(result)
    except Exception as e:
        logger.warning("Failed to load plugin model providers: %s", e)


def resolve_model_type(model_config: dict[str, Any]) -> str | None:
    """Extract and validate the model type from a model configuration.

    Args:
        model_config: The model configuration dictionary.

    Returns:
        The model type string, or None if not specified.
    """
    return model_config.get("type")


def get_model_type_description(model_type: str) -> str:
    """Get a human-readable description for a model type.

    Args:
        model_type: The model type string.

    Returns:
        Description string for the model type.
    """
    descriptions = {
        "openai": "OpenAI GPT models",
        "anthropic": "Anthropic Claude models",
        "gemini": "Google Gemini models",
        "cerebras": "Cerebras models",
        "custom_openai": "Custom OpenAI-compatible endpoint",
        "custom_anthropic": "Custom Anthropic-compatible endpoint",
        "custom_gemini": "Custom Gemini-compatible endpoint",
        "azure_openai": "Azure OpenAI Service",
        "openrouter": "OpenRouter multi-provider gateway",
        "round_robin": "Round-robin model rotation",
        "zai_coding": "ZAI Coding models",
        "zai_api": "ZAI API models",
        "gemini_oauth": "Gemini with OAuth authentication",
    }
    return descriptions.get(model_type, f"Custom model type: {model_type}")


# Re-export for backward compatibility
# This allows existing code to import from model_config instead of model_factory
def get_model_builders() -> dict[str, Any]:
    """Return a copy of the model builders dictionary."""
    return dict(_MODEL_BUILDERS)


def get_custom_model_providers() -> dict[str, Any]:
    """Return a copy of the custom model providers dictionary."""
    return dict(_CUSTOM_MODEL_PROVIDERS)
