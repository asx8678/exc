"""Agent prompt utilities mixin.

This module provides the AgentPromptMixin class which encapsulates
platform information gathering and system prompt assembly.

Extraction seam from BaseAgent - provides:
- Identity generation (get_identity, get_identity_prompt)
- Platform context gathering (get_platform_info)
- Full prompt assembly (get_full_system_prompt)
"""

import os
import platform as _platform
from abc import abstractmethod
from datetime import datetime
from pathlib import Path

from code_puppy import callbacks


class AgentPromptMixin:
    """Mixin providing platform info and prompt assembly utilities.

    This mixin encapsulates the concerns of:
    - Generating agent identity strings
    - Gathering runtime platform context (OS, shell, date, cwd, git status)
    - Assembling the complete system prompt with all context

    Expected to be mixed into classes that provide:
    - self.name: str (agent identifier, via @property @abstractmethod)
    - self.id: str (unique instance id, set in __init__)
    - self.get_system_prompt() -> str: base system prompt (via @abstractmethod)

    All methods are pure functions with no side effects.
    """

    # Protocol requirement - actual implementation provided by mixing class
    @property
    @abstractmethod
    def name(self) -> str:
        """Unique identifier for the agent."""
        ...

    # Note: self.id is expected to be set by the mixing class __init__
    # We don't define it here to avoid conflicts with attribute assignment

    @abstractmethod
    def get_system_prompt(self) -> str:
        """Get the base system prompt for this agent."""
        ...

    def get_identity(self) -> str:
        """Get a unique identity for this agent instance.

        Returns:
            A string like 'python-programmer-a3f2b1' combining name + short UUID.
        """
        return f"{self.name}-{self.id[:6]}"

    def get_identity_prompt(self) -> str:
        """Get the identity prompt suffix to embed in system prompts.

        Returns:
            A string instructing the agent about its identity for task ownership.
        """
        return (
            f"\n\nYour ID is `{self.get_identity()}`. "
            "Use this for any tasks which require identifying yourself "
            "such as claiming task ownership or coordination with other agents."
        )

    def get_platform_info(self) -> str:
        """Return runtime platform context for the system prompt.

        Includes OS, shell, date, language locale, git repo detection,
        and current working directory.  Inspired by aider's
        base_coder.get_platform_info().
        """
        lines: list[str] = []

        # OS / architecture
        try:
            lines.append(f"- Platform: {_platform.platform()}")
        except Exception:
            lines.append("- Platform: unknown")

        # Shell
        shell_var = "COMSPEC" if os.name == "nt" else "SHELL"
        shell_val = os.environ.get(shell_var, "unknown")
        lines.append(f"- Shell: {shell_var}={shell_val}")

        # Current date
        dt = datetime.now().astimezone().strftime("%Y-%m-%d")
        lines.append(f"- Current date: {dt}")

        # Working directory
        lines.append(f"- Working directory: {os.getcwd()}")

        # Git repo detection
        if Path(".git").is_dir():
            lines.append("- The user is working inside a git repository")

        return "\n".join(lines) + "\n"

    def get_full_system_prompt(self) -> str:
        """Get the complete system prompt with platform info and identity.

        Assembles: base prompt + plugin additions + platform context + agent identity.
        Platform info gives the model awareness of OS, shell, date, and
        environment so it can generate appropriate commands and advice.
        Plugin additions allow customization via load_prompt callbacks.

        Returns:
            The full system prompt including platform and identity information.
        """
        prompt = self.get_system_prompt()

        # Add plugin prompt additions (e.g., from prompt_store, file_mentions)
        prompt_additions = callbacks.on_load_prompt()
        if prompt_additions:
            filtered = [p for p in prompt_additions if p is not None]
            if filtered:
                prompt += "\n\n# Custom Instructions\n" + "\n".join(filtered)

        prompt += "\n\n# Environment\n" + self.get_platform_info()
        prompt += self.get_identity_prompt()
        return prompt
