"""Split compound shell commands into independent sub-commands.

Splits on ``&&``, ``||``, and ``;`` operators while respecting shell
quoting (single- and double-quoted strings are never split inside).
Does **not** split on ``|`` (pipe) — a pipeline is treated as a single
command.

Extracted from ``code_puppy.plugins.shell_safety`` so that core modules
(e.g. ``policy_engine.py``) can use it without importing from plugins.
"""


def split_compound_command(command: str) -> list[str]:
    """Split a compound shell command into individual sub-commands.

    Uses character-by-character scanning with quote-state tracking,
    following the same quoting rules as :mod:`shlex`.

    Args:
        command: Shell command string to split.

    Returns:
        A list of stripped sub-command strings.  If no compound operators
        are found outside of quotes the list contains only the original
        command (stripped).

    Examples::

        >>> split_compound_command("git add . && git commit -m 'msg'")
        ["git add .", "git commit -m 'msg'"]
        >>> split_compound_command("echo 'hello && world'")
        ["echo 'hello && world'"]
        >>> split_compound_command("cat foo | grep bar")
        ["cat foo | grep bar"]
    """
    parts: list[str] = []
    current: list[str] = []
    i = 0
    in_single_quote = False
    in_double_quote = False

    while i < len(command):
        c = command[i]

        if in_single_quote:
            if c == "'":
                in_single_quote = False
            current.append(c)

        elif in_double_quote:
            if c == "\\" and i + 1 < len(command):
                current.append(c)
                current.append(command[i + 1])
                i += 2
                continue
            if c == '"':
                in_double_quote = False
            current.append(c)

        else:
            if c == "'":
                in_single_quote = True
                current.append(c)
            elif c == '"':
                in_double_quote = True
                current.append(c)
            elif c in ("&", "|") and i + 1 < len(command) and command[i + 1] == c:
                part = "".join(current).strip()
                if part:
                    parts.append(part)
                current = []
                i += 2
                continue
            elif c == ";":
                part = "".join(current).strip()
                if part:
                    parts.append(part)
                current = []
            else:
                current.append(c)

        i += 1

    last = "".join(current).strip()
    if last:
        parts.append(last)

    return parts if parts else [command.strip()]
