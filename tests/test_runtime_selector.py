"""Tests for the Python RuntimeSelector mirror (ADR-004).

Covers all three modes, env-var parsing edge cases, feature-flag delegation,
unknown-capability fallback, and degraded behaviour when the feature-flags
module is unavailable.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from code_puppy import runtime_selector as rs


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_flags(path: Path, **overrides: bool) -> None:
    """Write a complete flags.json with *overrides* applied.

    Enabled by default: llm_client, tools, cli.
    Disabled by default: base_agent, plugins.
    """
    defaults = {
        "elixir.llm_client": True,
        "elixir.base_agent": False,
        "elixir.tools": True,
        "elixir.plugins": False,
        "elixir.cli": True,
    }
    defaults.update(overrides)
    path.write_text(
        json.dumps(defaults, indent=2) + "\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# CAPABILITIES constant
# ---------------------------------------------------------------------------


class TestCapabilities:
    """The frozenset must precisely match ADR-004."""

    def test_contains_known_capabilities(self) -> None:
        expected = {"llm_client", "base_agent", "tools", "plugins", "cli"}
        assert rs.CAPABILITIES == expected

    def test_is_frozenset(self) -> None:
        assert isinstance(rs.CAPABILITIES, frozenset)

    def test_is_immutable(self) -> None:
        with pytest.raises(AttributeError):
            rs.CAPABILITIES.add("not_real")  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# current_mode — reads PUP_RUNTIME
# ---------------------------------------------------------------------------


class TestCurrentMode:
    """Env var is read on every call — no caching."""

    def test_default_when_unset(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("PUP_RUNTIME", raising=False)
        assert rs.current_mode() == "auto"

    def test_explicit_python(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "python")
        assert rs.current_mode() == "python"

    def test_explicit_elixir(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "elixir")
        assert rs.current_mode() == "elixir"

    def test_explicit_auto(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "auto")
        assert rs.current_mode() == "auto"

    def test_empty_string_falls_back_to_auto(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "")
        assert rs.current_mode() == "auto"

    def test_unknown_value_falls_back_to_auto(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "nonsense")
        assert rs.current_mode() == "auto"

    def test_rereads_env_on_every_call(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "python")
        assert rs.current_mode() == "python"
        monkeypatch.setenv("PUP_RUNTIME", "elixir")
        assert rs.current_mode() == "elixir"


# ---------------------------------------------------------------------------
# _parse_mode — internal parser
# ---------------------------------------------------------------------------


class TestParseMode:
    """Case-insensitive parsing with safe defaults."""

    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            ("python", "python"),
            ("PYTHON", "python"),
            ("Python", "python"),
            (" pYtHoN ", "python"),
            ("elixir", "elixir"),
            ("ELIXIR", "elixir"),
            ("Elixir", "elixir"),
            (" eLiXiR ", "elixir"),
            ("auto", "auto"),
            ("AUTO", "auto"),
            ("Auto", "auto"),
            (" AUTO ", "auto"),
            (None, "auto"),
            ("", "auto"),
            ("   ", "auto"),
            ("rust", "auto"),
            ("hybrid", "auto"),
        ],
    )
    def test_parse_variants(self, raw: str | None, expected: rs.Mode) -> None:
        assert rs._parse_mode(raw) == expected


# ---------------------------------------------------------------------------
# select_runtime — decision logic
# ---------------------------------------------------------------------------


class TestSelectRuntimePythonMode:
    """When PUP_RUNTIME=python every capability returns ``"python"``."""

    @pytest.fixture(autouse=True)
    def _set_mode(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "python")

    @pytest.mark.parametrize("capability", sorted(rs.CAPABILITIES))
    def test_all_known_capabilities_return_python(self, capability: str) -> None:
        assert rs.select_runtime(capability) == "python"

    def test_unknown_capability_returns_python(self) -> None:
        assert rs.select_runtime("unknown_cap") == "python"


class TestSelectRuntimeElixirMode:
    """When PUP_RUNTIME=elixir every capability returns ``"elixir"``."""

    @pytest.fixture(autouse=True)
    def _set_mode(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "elixir")

    @pytest.mark.parametrize("capability", sorted(rs.CAPABILITIES))
    def test_all_known_capabilities_return_elixir(self, capability: str) -> None:
        assert rs.select_runtime(capability) == "elixir"

    def test_unknown_capability_returns_python(self) -> None:
        assert rs.select_runtime("unknown_cap") == "python"


class TestSelectRuntimeAutoMode:
    """In ``auto`` mode the result depends on feature-flag state."""

    @pytest.fixture(autouse=True)
    def _set_auto_mode(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "auto")

    # -- Enabled flags ---------------------------------------------------

    def test_enabled_flag_returns_elixir(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        _write_flags(tmp_path / "flags.json", llm_client=True)
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        assert rs.select_runtime("llm_client") == "elixir"

    def test_disabled_flag_returns_python(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        _write_flags(tmp_path / "flags.json", llm_client=False)
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        assert rs.select_runtime("llm_client") == "python"

    def test_mixed_flags_return_correctly(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        _write_flags(tmp_path / "flags.json")
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        assert rs.select_runtime("tools") == "elixir"
        assert rs.select_runtime("plugins") == "python"
        assert rs.select_runtime("cli") == "elixir"

    def test_unknown_capability_returns_python(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        _write_flags(tmp_path / "flags.json")
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        assert rs.select_runtime("not_a_real_cap") == "python"

    # -- Missing / empty file (all flags default to False) ---------------

    @pytest.mark.parametrize("capability", sorted(rs.CAPABILITIES))
    def test_all_flags_false_when_no_flag_file(
        self, capability: str, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        """No flags.json at all → every flag is False → auto returns python."""
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        assert rs.select_runtime(capability) == "python"

    @pytest.mark.parametrize("capability", sorted(rs.CAPABILITIES))
    def test_all_flags_false_when_empty_flag_file(
        self, capability: str, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        """Empty flags.json → every flag is False → auto returns python."""
        (tmp_path / "flags.json").write_text("", encoding="utf-8")
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        assert rs.select_runtime(capability) == "python"


# ---------------------------------------------------------------------------
# Degraded behaviour when feature-flags module misbehaves
# ---------------------------------------------------------------------------


class TestDegradedFallback:
    """If ``feature_flags.enabled()`` cannot be imported or raises,
    ``select_runtime`` should return ``"python"`` for all capabilities."""

    @pytest.fixture(autouse=True)
    def _set_auto_mode(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "auto")

    def test_enabled_raises_exception_returns_python(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Simulate enabled() raising RuntimeError."""

        def _broken(*args: object, **kwargs: object) -> bool:
            msg = "Simulated failure"
            raise RuntimeError(msg)

        import code_puppy.feature_flags as ff

        monkeypatch.setattr(ff, "enabled", _broken)

        for cap in rs.CAPABILITIES:
            assert rs.select_runtime(cap) == "python", f"{cap} should be python"

    def test_import_error_returns_python(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Simulate ImportError by blocking re-import of feature_flags."""

        class _BlockImport:
            """A module-like object that raises ImportError on any attribute access."""

            def __getattr__(self, name: str) -> object:
                msg = f"Simulated import failure for {name}"
                raise ImportError(msg)

        monkeypatch.setitem(sys.modules, "code_puppy.feature_flags", _BlockImport())

        for cap in rs.CAPABILITIES:
            assert rs.select_runtime(cap) == "python", f"{cap} should be python"

        # monkeypatch.undo() is automatic at the end of the test.


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


class TestEdgeCases:
    """Various boundary conditions."""

    def test_select_runtime_empty_string(self) -> None:
        assert rs.select_runtime("") == "python"

    def test_select_runtime_case_sensitive_capability(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "elixir")
        assert rs.select_runtime("LLM_CLIENT") == "python"
        assert rs.select_runtime("llm_client") == "elixir"

    @pytest.mark.parametrize(
        ("mode_var", "expected"),
        [
            ("python", "python"),
            ("elixir", "elixir"),
        ],
    )
    def test_round_trip_through_env(
        self,
        mode_var: str,
        expected: rs.RuntimeChoice,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        monkeypatch.setenv("PUP_RUNTIME", mode_var)
        assert rs.select_runtime("llm_client") == expected

    def test_all_three_modes_are_covered_by_env(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Sanity check: python mode never returns elixir and vice versa."""
        monkeypatch.setenv("PUP_RUNTIME", "python")
        for cap in rs.CAPABILITIES:
            assert rs.select_runtime(cap) == "python"

        monkeypatch.setenv("PUP_RUNTIME", "elixir")
        for cap in rs.CAPABILITIES:
            assert rs.select_runtime(cap) == "elixir"


# ---------------------------------------------------------------------------
# Module-level state check
# ---------------------------------------------------------------------------


class TestNoMutableGlobalState:
    """The module should not hold mutable state at the top level."""

    def test_no_mutable_module_level_collections(self) -> None:
        """Module-level globals should be constants (frozensets, not sets/lists/dicts)."""
        for name in dir(rs):
            if name.startswith("_"):
                continue
            obj = getattr(rs, name)
            if isinstance(obj, (set, list, dict)):
                # Allow frozenset (immutable).
                if not isinstance(obj, frozenset):
                    pytest.fail(
                        f"{name} is a mutable {type(obj).__name__} at module level"
                    )

    def test_functional_stateless_public_api(self) -> None:
        """The public API contains only functions and type aliases."""
        public = {
            "CAPABILITIES",
            "Mode",
            "RuntimeChoice",
            "current_mode",
            "select_runtime",
        }
        for name in public:
            assert hasattr(rs, name), f"Missing public attribute: {name}"


# ---------------------------------------------------------------------------
# Type-checking smoke tests (runtime-verifiable)
# ---------------------------------------------------------------------------


class TestTypeAliases:
    """Verify that the Literal type aliases are correct at runtime."""

    def test_mode_is_correct_type(self) -> None:
        from typing import get_args

        args = get_args(rs.Mode)
        assert set(args) == {"python", "elixir", "auto"}

    def test_runtime_choice_is_correct_type(self) -> None:
        from typing import get_args

        args = get_args(rs.RuntimeChoice)
        assert set(args) == {"python", "elixir"}

    def test_return_values_match_literals(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_RUNTIME", "python")
        r1: rs.RuntimeChoice = rs.select_runtime("llm_client")
        assert r1 == "python"

        monkeypatch.setenv("PUP_RUNTIME", "elixir")
        r2: rs.RuntimeChoice = rs.select_runtime("llm_client")
        assert r2 == "elixir"
