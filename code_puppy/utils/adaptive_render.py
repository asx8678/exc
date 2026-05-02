"""Adaptive payload rendering utilities.

Pure utility functions ported from orion-multistep-analysis's frontend log
renderer (RunDetailPage.tsx:269-1024) that analyze arbitrary values or text
and determine how they should be rendered.

These helpers are the foundation for smart log/output rendering: given an
unknown payload (LLM tool result, raw log line, etc.), they can:

1. Convert Python-repr syntax to valid JSON (python_repr_to_json)
2. Detect embedded CSV/TSV/pipe tables inside free-form text (detect_delimited_table)
3. Classify the shape of a structured payload (classify_payload)
4. Extract column names from a list-of-dicts payload (collect_record_columns)
5. Normalize escaped whitespace literals (normalize_escaped_whitespace)

This module is PURE — it has NO dependency on Rich, Textual, or any renderer.
The rich_renderer integration lives in a separate file and is tracked under
See the adaptive rendering feature for context.
"""

import enum
import json
import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

__all__ = [
    "PayloadKind",
    "DelimitedTable",
    "python_repr_to_json",
    "detect_delimited_table",
    "classify_payload",
    "collect_record_columns",
    "normalize_escaped_whitespace",
]


# ---------------------------------------------------------------------------
# Enums and data classes
# ---------------------------------------------------------------------------


class PayloadKind(enum.Enum):
    """Classification of a payload's renderable shape."""

    EMPTY = "empty"
    SCALAR = "scalar"
    STRING = "string"
    KV_DICT = "kv_dict"
    RECORD_LIST = "record_list"
    MIXED_LIST = "mixed_list"
    NESTED = "nested"


@dataclass(frozen=True, slots=True)
class DelimitedTable:
    """A detected delimited table embedded in text."""

    delimiter: str
    header: list[str]
    rows: list[list[str]]
    start_line: int
    end_line: int


# ---------------------------------------------------------------------------
# 1. python_repr_to_json
# ---------------------------------------------------------------------------


_PY_NONE_RE = re.compile(r"(?<![\"'\w])None(?![\"'\w])")
_PY_TRUE_RE = re.compile(r"(?<![\"'\w])True(?![\"'\w])")
_PY_FALSE_RE = re.compile(r"(?<![\"'\w])False(?![\"'\w])")


def python_repr_to_json(text: str) -> str | None:
    """Convert a Python dict/list repr string to a valid JSON string.

    LLMs sometimes return tool output that looks like ``str(some_dict)`` rather
    than valid JSON (e.g. ``{'key': 'value', 'count': None}``). This helper
    attempts a best-effort conversion by replacing Python keywords and
    single-quoted strings, then validates with ``json.loads``.

    Args:
        text: Candidate Python-repr string.

    Returns:
        The converted JSON string if conversion succeeds and validates.
        Returns ``None`` otherwise.

    Examples:
        >>> python_repr_to_json("{'a': 1, 'b': None}")
        '{"a": 1, "b": null}'
    """
    if not isinstance(text, str):
        return None
    stripped = text.strip()
    if not stripped:
        return None
    if stripped[0] not in "{[(":
        return None

    # Already valid JSON? Return as-is.
    try:
        json.loads(stripped)
        return stripped
    except json.JSONDecodeError:
        pass

    converted = _PY_NONE_RE.sub("null", stripped)
    converted = _PY_TRUE_RE.sub("true", converted)
    converted = _PY_FALSE_RE.sub("false", converted)
    converted = _swap_single_quotes(converted)

    if converted.startswith("(") and converted.endswith(")"):
        converted = "[" + converted[1:-1] + "]"

    try:
        json.loads(converted)
        return converted
    except json.JSONDecodeError:
        return None


def _swap_single_quotes(text: str) -> str:
    """Replace single-quoted string tokens with double-quoted ones.

    Walks character by character, tracking quote state. Preserves escape
    sequences and escapes embedded double-quotes inside converted tokens.
    """
    out: list[str] = []
    i = 0
    n = len(text)
    in_double = False
    in_single = False
    while i < n:
        ch = text[i]
        if ch == "\\" and i + 1 < n:
            out.append(text[i : i + 2])
            i += 2
            continue
        if in_double:
            out.append(ch)
            if ch == '"':
                in_double = False
            i += 1
            continue
        if in_single:
            if ch == "'":
                out.append('"')
                in_single = False
            elif ch == '"':
                out.append('\\"')
            else:
                out.append(ch)
            i += 1
            continue
        if ch == '"':
            in_double = True
            out.append(ch)
        elif ch == "'":
            in_single = True
            out.append('"')
        else:
            out.append(ch)
        i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# 2. detect_delimited_table
# ---------------------------------------------------------------------------


_DELIMITER_CANDIDATES: tuple[str, ...] = ("\t", "|", ",", ";")


def detect_delimited_table(
    text: str,
    *,
    min_rows: int = 3,
    min_cols: int = 2,
) -> DelimitedTable | None:
    """Detect a CSV/TSV/pipe-delimited table embedded in free-form text.

    Scans line by line looking for a consecutive block of lines with a stable
    column count. The longest qualifying block wins.

    Args:
        text: The text to scan.
        min_rows: Minimum consecutive lines (including header) required.
        min_cols: Minimum column count required.

    Returns:
        A ``DelimitedTable`` if one is found, else ``None``.
    """
    if not isinstance(text, str) or not text.strip():
        return None

    lines = text.splitlines()
    if len(lines) < min_rows:
        return None

    best: DelimitedTable | None = None
    best_score = 0

    for delim in _DELIMITER_CANDIDATES:
        col_counts: list[int] = []
        for ln in lines:
            if delim in ln:
                stripped = ln.strip()
                if delim == "|":
                    stripped = stripped.strip("|")
                col_counts.append(len(stripped.split(delim)))
            else:
                col_counts.append(0)

        i = 0
        while i < len(col_counts):
            if col_counts[i] < min_cols:
                i += 1
                continue
            target = col_counts[i]
            j = i + 1
            while j < len(col_counts) and col_counts[j] == target:
                j += 1
            run_len = j - i
            if run_len >= min_rows and run_len > best_score:
                header_line = lines[i]
                if delim == "|":
                    header_line = header_line.strip().strip("|")
                header = [cell.strip() for cell in header_line.split(delim)]
                rows: list[list[str]] = []
                for k in range(i + 1, j):
                    row_line = lines[k]
                    if delim == "|":
                        row_line = row_line.strip().strip("|")
                    rows.append([cell.strip() for cell in row_line.split(delim)])
                best = DelimitedTable(
                    delimiter=delim,
                    header=header,
                    rows=rows,
                    start_line=i,
                    end_line=j - 1,
                )
                best_score = run_len
            i = j

    return best


# ---------------------------------------------------------------------------
# 3. classify_payload
# ---------------------------------------------------------------------------


def _is_scalar_or_str(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, bool):
        return True
    if isinstance(value, (int, float)):
        return True
    if isinstance(value, str):
        return True
    return False


def classify_payload(value: Any) -> PayloadKind:
    """Classify a payload's renderable shape.

    Returns one of the ``PayloadKind`` enum values. Callers use this to route
    to an appropriate renderer (table, KV panel, pretty-print, plain text).

    Examples:
        >>> classify_payload(None)
        <PayloadKind.EMPTY: 'empty'>
        >>> classify_payload("hello")
        <PayloadKind.STRING: 'string'>
        >>> classify_payload({"a": 1, "b": "x"})
        <PayloadKind.KV_DICT: 'kv_dict'>
    """
    if value is None:
        return PayloadKind.EMPTY
    if isinstance(value, bool):
        return PayloadKind.SCALAR
    if isinstance(value, (int, float)):
        return PayloadKind.SCALAR
    if isinstance(value, str):
        return PayloadKind.EMPTY if not value else PayloadKind.STRING
    if isinstance(value, dict):
        if not value:
            return PayloadKind.EMPTY
        if all(_is_scalar_or_str(v) for v in value.values()):
            return PayloadKind.KV_DICT
        return PayloadKind.NESTED
    if isinstance(value, (list, tuple)):
        if not value:
            return PayloadKind.EMPTY
        if all(isinstance(item, dict) for item in value):
            return PayloadKind.RECORD_LIST
        return PayloadKind.MIXED_LIST
    return PayloadKind.SCALAR


# ---------------------------------------------------------------------------
# 4. collect_record_columns
# ---------------------------------------------------------------------------


def collect_record_columns(rows: Sequence[dict[str, Any]]) -> list[str]:
    """Collect column names from a list of dicts in first-seen order.

    Performs a union of keys across rows, preserving the order each key was
    first encountered. Useful for rendering heterogeneous record lists.

    Examples:
        >>> collect_record_columns([{"a": 1, "b": 2}, {"b": 3, "c": 4}])
        ['a', 'b', 'c']
    """
    columns: list[str] = []
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        for key in row.keys():
            if key not in seen:
                seen.add(key)
                columns.append(key)
    return columns


# ---------------------------------------------------------------------------
# 5. normalize_escaped_whitespace
# ---------------------------------------------------------------------------


def normalize_escaped_whitespace(text: str) -> str:
    r"""Replace literal ``\n`` and ``\t`` with real whitespace.

    Some tool outputs arrive with literal backslash-n or backslash-t (for
    example when a JSON string is double-encoded). This helper un-escapes
    them for display.

    Examples:
        >>> normalize_escaped_whitespace("a\nb")
        'a\nb'
    """
    if not isinstance(text, str):
        return text
    return text.replace("\\n", "\n").replace("\\t", "\t")
