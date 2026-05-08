"""Tool schema inference from Python functions.

This module provides automatic schema generation from Python callables,
enabling tools to be registered directly from functions without
manual schema definition.
"""

import inspect
import types
import typing
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, get_type_hints

# JSON Schema types mapped from Python types
_TYPE_MAP: dict[type, str] = {
    str: "string",
    int: "integer",
    float: "number",
    bool: "boolean",
    list: "array",
    dict: "object",
    Any: "object",
}


def _get_json_type(py_type: type) -> str:
    """Convert Python type to JSON Schema type."""
    # Handle T | None -> T
    origin = typing.get_origin(py_type)
    args = typing.get_args(py_type)

    # Handle Optional types (T | None)
    if origin is typing.Union or origin is types.UnionType:
        # Filter out NoneType
        non_none = [arg for arg in args if arg is not type(None)]
        if len(non_none) == 1:
            py_type = non_none[0]
            origin = typing.get_origin(py_type)
            args = typing.get_args(py_type)

    # Handle list/array types
    if origin in (list, tuple, set):
        return "array"

    # Handle dict/object types
    if origin is dict:
        return "object"

    # Direct type mapping
    if py_type in _TYPE_MAP:
        return _TYPE_MAP[py_type]

    # Handle generic types
    if isinstance(py_type, type):
        if issubclass(py_type, str):
            return "string"
        if issubclass(py_type, bool):  # Check bool before int!
            return "boolean"
        if issubclass(py_type, int):
            return "integer"
        if issubclass(py_type, float):
            return "number"
        if issubclass(py_type, (list, tuple, set)):
            return "array"
        if issubclass(py_type, dict):
            return "object"

    return "object"  # Default fallback


def _get_item_schema(py_type: type) -> dict[str, Any] | None:
    """Get schema for array items from type like list[T]."""
    origin = typing.get_origin(py_type)
    args = typing.get_args(py_type)

    if origin in (list, tuple, set) and args:
        return {"type": _get_json_type(args[0])}

    return None


def _get_param_description(param: inspect.Parameter) -> str | None:
    """Extract description from Annotated type if present."""
    annotation = param.annotation

    # Check if annotation is Annotated[T, description]
    if typing.get_origin(annotation) is not typing.Annotated:
        return None

    args = typing.get_args(annotation)
    if len(args) >= 2:
        # Second argument is typically the description/metadata
        desc = args[1]
        if isinstance(desc, str):
            return desc

    return None


def _get_param_type(param: inspect.Parameter) -> type:
    """Extract the actual type from a parameter (handling Annotated)."""
    annotation = param.annotation

    # Unwrap Annotated to get the actual type
    if typing.get_origin(annotation) is typing.Annotated:
        args = typing.get_args(annotation)
        if args:
            return args[0]

    if annotation is inspect.Parameter.empty:
        return Any

    return annotation


@dataclass
class ToolParameter:
    """Description of a tool parameter."""

    name: str
    type: str
    description: str | None = None
    required: bool = True
    default: Any = None
    enum: list[Any] | None = None
    item_schema: dict[str, Any] | None = None

    def to_json_schema(self) -> dict[str, Any]:
        """Convert to JSON Schema property."""
        schema: dict[str, Any] = {"type": self.type}

        if self.description:
            schema["description"] = self.description

        if self.enum:
            schema["enum"] = self.enum

        if self.item_schema:
            schema["items"] = self.item_schema

        return schema


@dataclass
class ToolSchema:
    """Complete schema for a tool."""

    name: str
    description: str
    parameters: list[ToolParameter] = field(default_factory=list)
    required: list[str] = field(default_factory=list)

    def to_json_schema(self) -> dict[str, Any]:
        """Convert to full JSON Schema."""
        properties = {}
        for param in self.parameters:
            properties[param.name] = param.to_json_schema()

        return {
            "type": "object",
            "properties": properties,
            "required": self.required,
        }

    def to_tool_definition(self) -> dict[str, Any]:
        """Convert to tool definition format used by agent frameworks."""
        return {
            "name": self.name,
            "description": self.description,
            "parameters": self.to_json_schema(),
        }


def infer_schema_from_function(
    func: Callable,
    name: str | None = None,
    description: str | None = None,
) -> ToolSchema:
    """Infer tool schema from a Python function.

    Args:
        func: The function to analyze
        name: Optional tool name (defaults to function name)
        description: Optional description (defaults to docstring)

    Returns:
        ToolSchema with inferred parameters

    Example:
        def read_file(path: str, encoding: str = "utf-8") -> str:
            '''Read a file from disk.'''
            ...

        schema = infer_schema_from_function(read_file)
        # Creates schema with path (required string) and
        # encoding (optional string with default "utf-8")
    """
    # Get function name
    tool_name = name or func.__name__

    # Get description from docstring if not provided
    tool_description = description
    if tool_description is None and func.__doc__:
        # Clean up docstring - take first paragraph
        doc = func.__doc__.strip().split("\n\n")[0].strip()
        tool_description = doc

    if tool_description is None:
        tool_description = f"Execute {tool_name}"

    # Get signature and type hints
    sig = inspect.signature(func)

    try:
        type_hints = get_type_hints(func)
    except NameError, TypeError:
        # Handle cases where type hints can't be resolved
        type_hints = {}

    parameters: list[ToolParameter] = []
    required: list[str] = []

    for param_name, param in sig.parameters.items():
        # Skip self/cls for methods
        if param_name in ("self", "cls"):
            continue

        # Get type
        py_type = type_hints.get(param_name, param.annotation)
        if py_type is inspect.Parameter.empty:
            py_type = Any

        # Get description from Annotated if present
        param_desc = _get_param_description(param)

        # Get actual type (unwrap Annotated)
        actual_type = _get_param_type(param)
        json_type = _get_json_type(actual_type)

        # Check if required
        is_required = param.default is inspect.Parameter.empty
        default_value = None if is_required else param.default

        # Get item schema for arrays
        item_schema = _get_item_schema(actual_type)

        tool_param = ToolParameter(
            name=param_name,
            type=json_type,
            description=param_desc,
            required=is_required,
            default=default_value,
            item_schema=item_schema,
        )

        parameters.append(tool_param)

        if is_required:
            required.append(param_name)

    return ToolSchema(
        name=tool_name,
        description=tool_description,
        parameters=parameters,
        required=required,
    )


def register_tool_from_function(
    agent: Any,
    func: Callable,
    name: str | None = None,
    description: str | None = None,
) -> Any:
    """Register a tool from a Python function with inferred schema.

    This is a convenience function that infers the schema and registers
    the tool with an agent that supports tool registration.

    Args:
        agent: The agent to register the tool with
        func: The function to register as a tool
        name: Optional tool name
        description: Optional tool description

    Returns:
        The result of the agent's tool registration

    Example:
        from pydantic_ai import Agent

        agent = Agent("openai:gpt-4")

        @register_tool_from_function(agent)
        def calculate_sum(a: int, b: int) -> int:
            '''Add two numbers together.'''
            return a + b
    """
    schema = infer_schema_from_function(func, name, description)

    # Try different registration methods based on agent type
    if hasattr(agent, "tool"):
        # pydantic-ai style
        return agent.tool(func)
    elif hasattr(agent, "register_tool"):
        # Generic register_tool method
        return agent.register_tool(
            name=schema.name,
            func=func,
            description=schema.description,
            parameters=schema.to_json_schema(),
        )
    else:
        raise ValueError(
            f"Agent type {type(agent).__name__} does not support tool registration. "
            "Agent must have 'tool' or 'register_tool' method."
        )


def tool(
    name: str | None = None,
    description: str | None = None,
):
    """Decorator to mark a function as a tool with inferred schema.

    This decorator doesn't register the tool immediately - it attaches
    the schema for later registration.

    Example:
        @tool()
        def read_file(path: str, encoding: str = "utf-8") -> str:
            '''Read a file from disk.'''
            ...

        # Later: agent.register_tool(read_file)
    """

    def decorator(func: Callable) -> Callable:
        # Attach schema to function
        func._tool_schema = infer_schema_from_function(func, name, description)
        func._is_tool = True
        return func

    return decorator


def get_tool_schema(func: Callable) -> ToolSchema | None:
    """Get the attached tool schema from a function.

    Args:
        func: Function that may have @tool decorator

    Returns:
        ToolSchema if function was decorated, None otherwise
    """
    return getattr(func, "_tool_schema", None)


def is_tool_function(func: Callable) -> bool:
    """Check if a function was decorated with @tool.

    Args:
        func: Function to check

    Returns:
        True if function is a registered tool
    """
    return getattr(func, "_is_tool", False)
