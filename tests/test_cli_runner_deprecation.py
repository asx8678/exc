"""Tests for the legacy `pup` alias deprecation warning (Phase 1).

Covers:
- Opt-in warning when PUP_PUP_ALIAS_DEPRECATED=1 and invoked as `pup`
- Windows-style `pup.exe` detection
- No warning when invoked as `code-puppy`
- No warning when PUP_PUP_ALIAS_DEPRECATED is unset
- Warning fires before --help/--version

See docs/release/python-pup-alias-deprecation-plan.md for the full plan.
"""

import sys
import warnings

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# We need to re-import cli_runner for each test so module-level state
# (os.environ, sys.argv) is picked up fresh. Using importlib.reload.
from importlib import import_module, reload


def _reload_cli_runner():
    """Force-reload code_puppy.cli_runner so env/argv changes are seen."""
    mod = import_module("code_puppy.cli_runner")
    return reload(mod)


# ---------------------------------------------------------------------------
# Tests: _warn_if_legacy_pup_alias
# ---------------------------------------------------------------------------


class TestLegacyPupAliasDeprecation:
    """Phase 1 opt-in deprecation warning for the Python `pup` alias."""

    def test_warning_emitted_when_env_set_and_invoked_as_pup(self, monkeypatch):
        """PUP_PUP_ALIAS_DEPRECATED=1 + sys.argv[0] basename 'pup' → warning."""
        monkeypatch.setenv("PUP_PUP_ALIAS_DEPRECATED", "1")
        monkeypatch.setattr(sys, "argv", ["pup", "--help"])

        mod = _reload_cli_runner()

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            mod._warn_if_legacy_pup_alias()

        assert len(caught) == 1
        assert issubclass(caught[0].category, DeprecationWarning)
        assert "legacy Python/PyPI alias" in str(caught[0].message)
        assert "'pup'" in str(caught[0].message)

    def test_warning_emitted_for_pup_exe(self, monkeypatch):
        """PUP_PUP_ALIAS_DEPRECATED=1 + sys.argv[0] basename 'pup.exe' → warning."""
        monkeypatch.setenv("PUP_PUP_ALIAS_DEPRECATED", "1")
        monkeypatch.setattr(sys, "argv", ["C:\\Scripts\\pup.exe", "--help"])

        mod = _reload_cli_runner()

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            mod._warn_if_legacy_pup_alias()

        assert len(caught) == 1
        assert issubclass(caught[0].category, DeprecationWarning)

    def test_no_warning_when_invoked_as_code_puppy(self, monkeypatch):
        """PUP_PUP_ALIAS_DEPRECATED=1 + sys.argv[0] basename 'code-puppy' → no warning."""
        monkeypatch.setenv("PUP_PUP_ALIAS_DEPRECATED", "1")
        monkeypatch.setattr(sys, "argv", ["code-puppy", "--help"])

        mod = _reload_cli_runner()

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            mod._warn_if_legacy_pup_alias()

        assert len(caught) == 0

    def test_no_warning_when_invoked_as_code_puppy_exe(self, monkeypatch):
        """PUP_PUP_ALIAS_DEPRECATED=1 + sys.argv[0] basename 'code-puppy.exe' → no warning."""
        monkeypatch.setenv("PUP_PUP_ALIAS_DEPRECATED", "1")
        monkeypatch.setattr(sys, "argv", ["C:\\Scripts\\code-puppy.exe", "--help"])

        mod = _reload_cli_runner()

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            mod._warn_if_legacy_pup_alias()

        assert len(caught) == 0

    def test_no_warning_when_env_unset(self, monkeypatch):
        """PUP_PUP_ALIAS_DEPRECATED unset + invoked as 'pup' → no warning."""
        monkeypatch.delenv("PUP_PUP_ALIAS_DEPRECATED", raising=False)
        monkeypatch.setattr(sys, "argv", ["pup", "--help"])

        mod = _reload_cli_runner()

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            mod._warn_if_legacy_pup_alias()

        assert len(caught) == 0

    def test_no_warning_when_env_empty(self, monkeypatch):
        """PUP_PUP_ALIAS_DEPRECATED='' + invoked as 'pup' → no warning."""
        monkeypatch.setenv("PUP_PUP_ALIAS_DEPRECATED", "")
        monkeypatch.setattr(sys, "argv", ["pup", "--help"])

        mod = _reload_cli_runner()

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            mod._warn_if_legacy_pup_alias()

        assert len(caught) == 0

    def test_warning_emitted_for_truthy_env_values(self, monkeypatch):
        """PUP_PUP_ALIAS_DEPRECATED accepts '1', 'true', 'yes' (case-insensitive)."""
        for val in ("1", "true", "yes", "on", "True", "YES", "ON"):
            monkeypatch.setenv("PUP_PUP_ALIAS_DEPRECATED", val)
            monkeypatch.setattr(sys, "argv", ["pup", "--help"])

            mod = _reload_cli_runner()

            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                mod._warn_if_legacy_pup_alias()

            assert len(caught) == 1, f"Expected warning for env value {val!r}"

    def test_no_warning_for_unrelated_basename(self, monkeypatch):
        """PUP_PUP_ALIAS_DEPRECATED=1 + unrelated argv[0] basename → no warning."""
        monkeypatch.setenv("PUP_PUP_ALIAS_DEPRECATED", "1")
        monkeypatch.setattr(sys, "argv", ["/usr/local/bin/some-other-tool", "--help"])

        mod = _reload_cli_runner()

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            mod._warn_if_legacy_pup_alias()

        assert len(caught) == 0

    def test_stderr_message_content(self, monkeypatch, capsys):
        """Stderr warning includes the word 'Deprecation' and migration guidance."""
        monkeypatch.setenv("PUP_PUP_ALIAS_DEPRECATED", "1")
        monkeypatch.setattr(sys, "argv", ["pup", "--help"])

        mod = _reload_cli_runner()

        with warnings.catch_warnings(record=True):
            warnings.simplefilter("always")
            mod._warn_if_legacy_pup_alias()

        captured = capsys.readouterr()
        assert "Deprecation" in captured.err
        assert "code-puppy" in captured.err
        assert "python-pup-alias-deprecation-plan" in captured.err
