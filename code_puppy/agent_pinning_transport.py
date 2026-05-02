"""
Python wrappers for Elixir agent_pinning RPC methods.

This module provides Python functions that call the Elixir agent_pinning.*
RPC methods via the JSON-RPC transport. These methods manage server-side
agent-to-model pinning state in the Elixir StdioService.

Note: This is DIFFERENT from code_puppy.agent_model_pinning.py which handles
JSON file-based pinning. This module interfaces with the Elixir runtime
pinning state that persists across the service lifecycle.

## Usage

```python
from code_puppy import agent_pinning_transport as pinning

# Get pinned model for an agent
result = pinning.get_pinned_model("turbo-executor")
# result = {"agent_name": "turbo-executor", "model": "claude-sonnet-4"}

# Pin an agent to a specific model
result = pinning.set_pinned_model("turbo-executor", "claude-sonnet-4")
# result = {"agent_name": "turbo-executor", "model": "claude-sonnet-4"}

# Clear a pin
result = pinning.clear_pinned_model("turbo-executor")
# result = {"agent_name": "turbo-executor", "cleared": True}

# List all pins
result = pinning.list_pinned_models()
# result = {"pins": [{"agent_name": "x", "model": "y"}], "count": 1}
```

## Environment Variables

Uses the same transport as elixir_transport_helpers - see that module for
configuration options.
"""

from typing import Any


def _get_transport() -> "ElixirTransport":  # type: ignore # noqa: F821
    """Get the shared transport singleton from elixir_transport_helpers."""
    from code_puppy.elixir_transport_helpers import get_transport

    return get_transport()


# =============================================================================
# Agent Pinning Operations
# =============================================================================


def get_pinned_model(agent_name: str) -> dict[str, Any]:
    """Get the pinned model for a specific agent.

    Returns the model name currently pinned to the agent, or None if
    no pin exists.

    Args:
        agent_name: Name of the agent to look up

    Returns:
        Dict with:
        - agent_name: The agent name that was queried
        - model: The pinned model name, or None if no pin exists

    Raises:
        ElixirTransportError: If the transport fails or returns an error

    Example:
        >>> result = get_pinned_model("turbo-executor")
        >>> print(result["model"]) # "claude-sonnet-4" or None
    """
    transport = _get_transport()
    return transport._send_request(
        "agent_pinning.get",
        {
            "agent_name": agent_name,
        },
    )


def set_pinned_model(agent_name: str, model_name: str) -> dict[str, Any]:
    """Pin an agent to a specific model.

    Sets or updates the pinned model for the given agent. This overrides
    any model selection that would normally happen based on context.

    Args:
        agent_name: Name of the agent to pin
        model_name: Name of the model to pin to

    Returns:
        Dict with:
        - agent_name: The agent that was pinned
        - model: The model name that was set

    Raises:
        ElixirTransportError: If the transport fails or returns an error

    Example:
        >>> result = set_pinned_model("turbo-executor", "claude-sonnet-4")
        >>> assert result["model"] == "claude-sonnet-4"
    """
    transport = _get_transport()
    return transport._send_request(
        "agent_pinning.set",
        {
            "agent_name": agent_name,
            "model": model_name,
        },
    )


def clear_pinned_model(agent_name: str) -> dict[str, Any]:
    """Clear the pinned model for an agent.

    Removes any existing model pin for the given agent, allowing normal
    model selection to resume.

    Args:
        agent_name: Name of the agent to unpin

    Returns:
        Dict with:
        - agent_name: The agent that was unpinned
        - cleared: True indicating the operation succeeded

    Raises:
        ElixirTransportError: If the transport fails or returns an error

    Example:
        >>> result = clear_pinned_model("turbo-executor")
        >>> assert result["cleared"] is True
    """
    transport = _get_transport()
    return transport._send_request(
        "agent_pinning.clear",
        {
            "agent_name": agent_name,
        },
    )


def list_pinned_models() -> dict[str, Any]:
    """List all agent-to-model pins.

    Returns a list of all currently pinned agents and their associated
    models.

    Returns:
        Dict with:
        - pins: List of pin dicts, each with "agent_name" and "model" keys
        - count: Total number of pins

    Raises:
        ElixirTransportError: If the transport fails or returns an error

    Example:
        >>> result = list_pinned_models()
        >>> for pin in result["pins"]:
        ... print(f"{pin['agent_name']} -> {pin['model']}")
    """
    transport = _get_transport()
    return transport._send_request("agent_pinning.list", {})
