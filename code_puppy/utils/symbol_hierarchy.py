"""Symbol hierarchy utilities — Shared logic for building parent-child relationships.

This module provides standalone functions for building symbol hierarchies
that work with both SymbolInfo dataclass objects and plain dictionaries.
"""

from typing import Any


def build_symbol_hierarchy[T](symbols: list[T]) -> list[T]:
    """Build parent-child hierarchy from a flat symbol list.

    Supports both SymbolInfo dataclass objects and plain dictionaries.
    Uses position ranges to determine nesting.

    Args:
        symbols: Flat list of symbols (SymbolInfo or dict)

    Returns:
        Hierarchical list with parent-child relationships established
    """
    if not symbols:
        return []

    # Sort by start position, longer ranges first for proper nesting
    def sort_key(s):
        start_line = _get_attr(s, "start_line", 0)
        start_col = _get_attr(s, "start_col", 0)
        size = _get_size(s)
        return (start_line, start_col, -size)

    sorted_symbols = sorted(symbols, key=sort_key)

    root_items: list[T] = []
    stack: list[T] = []

    for symbol in sorted_symbols:
        # Find parent by checking containment
        while stack:
            parent = stack[-1]
            if is_symbol_contained(symbol, parent):
                _set_parent(symbol, _get_attr(parent, "name", None))
                _add_child(parent, symbol)
                break
            else:
                stack.pop()
        else:
            # No parent found, add to root
            root_items.append(symbol)

        # Push this symbol to stack
        stack.append(symbol)

    return root_items


def is_symbol_contained[T](child: T, parent: T) -> bool:
    """Check if child symbol is contained within parent symbol.

    Works with both SymbolInfo objects and dictionaries.

    Args:
        child: Child symbol (SymbolInfo or dict)
        parent: Parent symbol (SymbolInfo or dict)

    Returns:
        True if child is contained in parent
    """
    child_start = _get_attr(child, "start_line", 0)
    child_end = _get_attr(child, "end_line", 0)
    parent_start = _get_attr(parent, "start_line", 0)
    parent_end = _get_attr(parent, "end_line", 0)

    # Strict containment: child starts after parent starts and ends before parent ends
    if child_start > parent_start and child_end <= parent_end:
        return True
    # Same start but child ends before parent
    if child_start == parent_start and child_end < parent_end:
        return True
    return False


def _get_attr(obj: Any, name: str, default: Any = None) -> Any:
    """Get attribute from object or dict."""
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def _get_size(obj: Any) -> int:
    """Get size in lines from object or dict."""
    start = _get_attr(obj, "start_line", 0)
    end = _get_attr(obj, "end_line", 0)
    return end - start + 1


def _set_parent(obj: Any, parent: Any) -> None:
    """Set parent on object or dict."""
    if isinstance(obj, dict):
        obj["parent"] = parent
    else:
        obj.parent = parent


def _add_child(parent: Any, child: Any) -> None:
    """Add child to parent's children list."""
    if isinstance(parent, dict):
        parent["children"].append(child)
    else:
        parent.children.append(child)
