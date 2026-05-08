"""LLM output parsing utilities.

Robust JSON extraction from LLM text outputs that may include markdown fences,
prose explanations, or multiple JSON candidates.

This module is particularly useful when working with LLM APIs that return
JSON embedded in natural language text or markdown code blocks.

Migration candidates (code_puppy/ files that could use this utility):
- code_puppy/chatgpt_codex_client.py:287 - SSE event data parsing with
  json.loads(data_str) inside try/except JSONDecodeError
- code_puppy/utils/stream_parser.py:186 - lenient JSONL parsing that could
  benefit from fenced JSON extraction before falling back to line parsing
"""

import json
import re
from typing import Any


def _ensure_dict_list(value: Any) -> list[dict]:
    """Normalize a value into a list of dicts.

    - dict → [dict]
    - list → filter to dicts and strings; strings become {"summary": s}
    - str (non-empty) → [{"summary": s}]
    - anything else → []

    Args:
        value: The value to normalize.

    Returns:
        A list of dicts, never None.
    """
    if isinstance(value, dict):
        return [dict(value)]
    if isinstance(value, str):
        stripped = value.strip()
        if stripped:
            return [{"summary": stripped}]
        return []
    if isinstance(value, list):
        result: list[dict] = []
        for item in value:
            if isinstance(item, dict):
                result.append(dict(item))
            elif isinstance(item, str):
                stripped = item.strip()
                if stripped:
                    result.append({"summary": stripped})
            # Non-dict, non-str items are filtered out
        return result
    return []


def coerce_llm_dict(
    payload: Any,
    *,
    aliases: dict[str, list[str]] | None = None,
    list_keys: set[str] | None = None,
    string_to_key: str = "summary",
    default: dict | None = None,
) -> dict:
    """Tolerantly coerce an LLM-produced value into a canonical dict.

    LLMs often return responses in inconsistent shapes: sometimes a JSON object
    with the expected keys, sometimes a list, sometimes a bare string, sometimes
    None. This helper normalizes all of those into a predictable dict while
    handling key aliases (e.g. sources/findings/evidence all mapping to "sources").

    Args:
        payload: The raw value returned by the LLM. May be None, str, list, dict,
            or anything else (unknown types become {}).
        aliases: Optional mapping of canonical_key -> list_of_alternate_names.
            When the input is a dict, the first non-empty value found among the
            alternate names is copied to the canonical key. The canonical key
            itself is tried first.
        list_keys: Optional set of canonical keys whose values should be
            normalized to a list of dicts. Strings become {"summary": str},
            dicts pass through, lists of mixed types are filtered.
        string_to_key: When the input is a bare string, it is wrapped as
            {string_to_key: value}. Defaults to "summary".
        default: Fallback returned when the input yields nothing useful.
            Defaults to an empty dict.

    Returns:
        A dict (never None, never raises). Empty dict if the input carries no
        usable information.

    Examples:
        >>> coerce_llm_dict(None)
        {}
        >>> coerce_llm_dict("hello world")
        {'summary': 'hello world'}
        >>> coerce_llm_dict(["a", "b"])
        {'items': [{'summary': 'a'}, {'summary': 'b'}]}
        >>> coerce_llm_dict(
        ...     {"findings": [{"title": "t"}]},
        ...     aliases={"sources": ["findings", "evidence", "references"]},
        ...     list_keys={"sources"},
        ... )
        {'sources': [{'title': 't'}]}
    """
    # Handle None
    if payload is None:
        return default.copy() if default else {}

    # Handle string
    if isinstance(payload, str):
        stripped = payload.strip()
        if not stripped:
            return default.copy() if default else {}
        return {string_to_key: stripped}

    # Handle list
    if isinstance(payload, list):
        return {"items": _ensure_dict_list(payload)}

    # Handle dict
    if isinstance(payload, dict):
        if aliases is None:
            # No aliases, just return a shallow copy
            return dict(payload)

        result: dict[str, Any] = {}
        list_keys_set = list_keys or set()

        for canonical, alts in aliases.items():
            # Try canonical first, then each alt in order
            found_value: Any = None
            if canonical in payload:
                found_value = payload[canonical]
            else:
                for alt in alts:
                    if alt in payload:
                        found_value = payload[alt]
                        break

            if found_value is not None:
                # Normalize if this key is in list_keys
                if canonical in list_keys_set:
                    result[canonical] = _ensure_dict_list(found_value)
                else:
                    result[canonical] = found_value

        # Copy over any extra keys not covered by aliases
        alias_targets = set(aliases.keys())
        for alt_list in aliases.values():
            alias_targets.update(alt_list)

        for key, value in payload.items():
            if key not in alias_targets:
                result[key] = value

        # If result is empty but payload was non-empty, return payload copy as fallback
        if not result and payload:
            return dict(payload)

        return result

    # Unknown type - return default or empty dict
    return default.copy() if default else {}


# Regex to strip markdown code fences (```json or just ```)
_CODE_FENCE_RE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)

# Regex to find JSON-like substrings (objects or arrays)
_JSON_SNIPPET_RE = re.compile(r"({[\s\S]*?})|(\[[\s\S]*?])")


def extract_json_from_text(text: str | None) -> Any | None:
    """Extract and parse JSON from LLM output text.

    Tries multiple strategies in order of likelihood:
    1. Direct JSON parsing on raw text
    2. Strip markdown code fences and retry
    3. Regex-find JSON-looking substrings (objects/arrays) and try each

    This function never raises exceptions - it returns None on any failure,
    making it safe for use in parsing pipelines where malformed input is
    expected and should be handled gracefully.

    Args:
        text: Raw text from an LLM, which may contain JSON surrounded by
            markdown fences, prose, or other formatting. Can be None.

    Returns:
        The parsed JSON value (dict, list, str, int, etc.) if found and valid,
        otherwise None.

    Examples:
        >>> extract_json_from_text('{"key": "value"}')
        {'key': 'value'}

        >>> extract_json_from_text('```json\\n{"key": "value"}\\n```')
        {'key': 'value'}

        >>> extract_json_from_text('```\\n[1, 2, 3]\\n```')
        [1, 2, 3]

        >>> extract_json_from_text('Here is the result: {"key": "value"} Thanks!')
        {'key': 'value'}

        >>> extract_json_from_text('Invalid { json here') is None
        True

        >>> extract_json_from_text(None) is None
        True
    """
    if text is None:
        return None

    text = text.strip()
    if not text:
        return None

    # Strategy 1: Try raw parse on the full text
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Strategy 2: Strip markdown code fences and retry
    cleaned = _CODE_FENCE_RE.sub("", text).strip()
    if cleaned != text:
        try:
            return json.loads(cleaned)
        except json.JSONDecodeError:
            pass

    # Strategy 3: Find JSON-looking substrings and try each
    # This handles cases like "Here is the data: {...} and some prose after"
    for match in _JSON_SNIPPET_RE.finditer(text):
        candidate = match.group(0)
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue

    # All strategies failed
    return None
