"""Helper utilities for the ask_user_question tool.

Provides conveniences like auto-collapsing single-choice prompts so
callers don't have to hand-roll the "skip if only one option" pattern.
"""

from collections.abc import Callable
from typing import Sequence


def select_with_smart_defaults[T](
    items: Sequence[T],
    *,
    display_fn: Callable[[T], str] | None = None,
    question_header: str = "Select",
    prompt_text: str | None = None,
) -> T | None:
    """Return a single choice from ``items``, auto-collapsing trivial cases.

    Behavior:
    - If ``items`` is empty, returns None.
    - If ``items`` has exactly one element, returns it immediately (no prompt).
    - Otherwise, invokes the interactive ask_user_question flow with the
      items rendered via ``display_fn`` (or ``str()`` by default).

    Args:
        items: The candidate items.
        display_fn: Function to render each item as a label string.
        question_header: Header shown to the user in multi-choice mode.
        prompt_text: Optional clarifying text shown above the options.

    Returns:
        The selected item, or None if items was empty or the user cancelled.
    """
    n = len(items)
    if n == 0:
        return None
    if n == 1:
        return items[0]

    render = display_fn if display_fn is not None else str
    labels = [render(item) for item in items]

    # Lazy-import to avoid circular imports with ask_user_question subsystem
    from code_puppy.tools.ask_user_question import (
        Question,
        QuestionOption,
        ask_user_question,
    )

    question = Question(
        question=prompt_text or "Select an option",
        header=question_header,
        options=[QuestionOption(label=label) for label in labels],
        multi_select=False,
    )
    result = ask_user_question([question])

    if not result.success:
        return None

    answer = result.get_answer(question_header)
    if answer is None or not answer.selected_options:
        return None

    selected_label = answer.selected_options[0]
    for label, item in zip(labels, items):
        if label == selected_label:
            return item
    return None
