"""Deterministic streaming prompt fixtures for LLM benchmark probes.

Offline-safe: no network, no API keys, no provider mocking. These fixtures
define standardized prompts that future live streaming probes (code_puppy-axx)
will use to measure TTFT/TBT. They are pure data — suitable for unit tests,
schema validation, and reproducible benchmark identification.

Convention: each fixture carries a stable ``prompt_id`` so benchmark results
can reference the exact prompt used without embedding the full text in
metadata.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class StreamingPrompt:
    """A deterministic prompt definition for streaming LLM benchmarks.

    Attributes:
        prompt_id: Stable identifier (e.g. "short_v1"). Never reuse an id
            when the prompt text changes — bump the version suffix instead.
        text: The exact prompt text sent to the provider.
        description: Human-readable summary for docs/display.
        expected_min_tokens: Conservative lower bound on expected response
            tokens. Used by validators and timeout heuristics — never as a
            mock result.
    """

    prompt_id: str
    text: str
    description: str
    expected_min_tokens: int


# ---------------------------------------------------------------------------
# Standard fixture catalogue
# ---------------------------------------------------------------------------

SHORT = StreamingPrompt(
    prompt_id="short_v1",
    text="Write a one-sentence Python function that adds two numbers.",
    description="Minimal prompt; expected ~1 short sentence of code.",
    expected_min_tokens=10,
)

MEDIUM = StreamingPrompt(
    prompt_id="medium_v1",
    text=(
        "Explain the difference between async/await and threading in Python. "
        "Give a short paragraph for each approach and one code snippet."
    ),
    description="Multi-paragraph explanatory prompt; forces sustained generation.",
    expected_min_tokens=80,
)


# Public registry — iterate this for exhaustive fixture coverage.
FIXTURES: dict[str, StreamingPrompt] = {
    SHORT.prompt_id: SHORT,
    MEDIUM.prompt_id: MEDIUM,
}


def get_fixture(prompt_id: str) -> StreamingPrompt:
    """Look up a fixture by prompt_id; raises KeyError if unknown."""
    return FIXTURES[prompt_id]


def all_fixture_ids() -> list[str]:
    """Return sorted list of all registered fixture ids."""
    return sorted(FIXTURES.keys())
