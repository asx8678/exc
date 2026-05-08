"""Textual TUI framework for Code Puppy.

This package provides the unified full-screen terminal UI built on Textual.
All menu screens, the chat interface, and the input system live here.
"""

from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.completion_overlay import CompletionOverlay
from code_puppy.tui.widgets.searchable_list import SearchableList
from code_puppy.tui.widgets.split_panel import SplitPanel

__all__ = ["CompletionOverlay", "MenuScreen", "SearchableList", "SplitPanel"]
