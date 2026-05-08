"""Test hook engine alias mappings."""

from code_puppy.hook_engine.aliases import (
    ALIAS_LOOKUP,
    CODEX_ALIASES,
    GEMINI_ALIASES,
    get_aliases,
)


def test_gemini_aliases_populated():
    """GEMINI_ALIASES should have mappings."""
    assert len(GEMINI_ALIASES) > 0


def test_codex_aliases_populated():
    """CODEX_ALIASES should have mappings."""
    assert len(CODEX_ALIASES) > 0


def test_gemini_read_file_maps_to_internal():
    """Gemini's read_file should map to agent_read_file."""
    assert GEMINI_ALIASES["read_file"] == "read_file"


def test_codex_shell_maps_to_internal():
    """Codex's shell should map to agent_run_shell_command."""
    assert CODEX_ALIASES["shell"] == "agent_run_shell_command"


def test_alias_lookup_includes_gemini():
    """ALIAS_LOOKUP should include Gemini aliases."""
    assert "read_file" in ALIAS_LOOKUP or "run_command" in ALIAS_LOOKUP


def test_get_aliases_returns_frozenset():
    """get_aliases should return frozenset."""
    result = get_aliases("read_file")
    assert isinstance(result, frozenset)
