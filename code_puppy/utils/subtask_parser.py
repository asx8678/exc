"""Parse structured subtask lists from LLM markdown output.

Ported from plandex's app/server/model/parse/subtasks.go. Recognizes
sections like:

    ### Tasks

    1. Implement foo
       - Does this
       - Does that
       Uses: foo.py, bar.py

    2. Add tests

and returns a list of Subtask dataclasses.

Also parses `### Remove Tasks` sections that list tasks to remove.
"""

import logging
import re
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)

_NUMBERED_ITEM_RE = re.compile(r"^\d+\.\s")


@dataclass(slots=True)
class Subtask:
    """A single parsed subtask from an LLM plan."""

    title: str
    description: str = ""
    uses_files: list[str] = field(default_factory=list)


def parse_subtasks(reply_content: str) -> list[Subtask]:
    """Extract numbered subtasks from an LLM response.

    Splits on ``### Tasks`` (or ``### Task`` as fallback) and walks
    subsequent lines matching ``^\\d+\\. <title>``. Description lines
    (bulleted or unbulleted) accumulate until the next numbered item.
    ``Uses: a.py, b.py`` lines populate the ``uses_files`` field.

    Args:
        reply_content: Full text of the LLM response.

    Returns:
        List of Subtask instances. Empty list if no Tasks section found.
    """
    if not reply_content:
        return []

    parts = reply_content.split("### Tasks", 1)
    if len(parts) < 2:
        parts = reply_content.split("### Task", 1)
        if len(parts) < 2:
            logger.debug("subtask_parser: no ### Tasks section found")
            return []

    body = parts[1]
    lines = body.split("\n")

    subtasks: list[Subtask] = []
    current: Subtask | None = None
    desc_lines: list[str] = []

    def _flush_current() -> None:
        nonlocal current, desc_lines
        if current is not None:
            current.description = "\n".join(desc_lines)
            subtasks.append(current)
            current = None
            desc_lines = []

    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue

        # New numbered item starts a new subtask
        if _NUMBERED_ITEM_RE.match(line):
            _flush_current()
            # "1. title" -> split on first ". " to get the title
            split = line.split(". ", 1)
            if len(split) == 2:
                current = Subtask(title=split[1].strip())
                desc_lines = []
            continue

        # "Uses:" line
        if line.startswith("Uses:"):
            if current is not None:
                uses_str = line[len("Uses:") :]
                for use in uses_str.split(","):
                    use = use.strip().strip("`").strip()
                    if use:
                        current.uses_files.append(use)
            continue

        # Otherwise it's a description line (strip leading bullet)
        if current is not None:
            cleaned = line.lstrip("-").strip()
            if cleaned:
                desc_lines.append(cleaned)

    _flush_current()
    logger.debug("subtask_parser: parsed %d subtasks", len(subtasks))
    return subtasks


def parse_remove_subtasks(reply_content: str) -> list[str]:
    """Extract the list of subtask titles to remove from ``### Remove Tasks``.

    Returns an empty list if no section found.
    """
    if not reply_content:
        return []

    parts = reply_content.split("### Remove Tasks", 1)
    if len(parts) < 2:
        return []

    lines = parts[1].split("\n")
    tasks_to_remove: list[str] = []
    saw_empty_line = False

    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            saw_empty_line = True
            continue
        if saw_empty_line and not line.startswith("-"):
            break
        if line.startswith("- "):
            title = line[2:].strip()
            if title:
                tasks_to_remove.append(title)

    return tasks_to_remove


def has_plan(reply_content: str, min_tasks: int = 2) -> bool:
    """Return True if the reply contains at least ``min_tasks`` parsed subtasks."""
    return len(parse_subtasks(reply_content)) >= min_tasks
