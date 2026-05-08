"""Tests for ADR-003 dual-home config isolation.

Verifies that:
1. Elixir pup-ex config/home is ``~/.code_puppy_ex/`` only
2. Elixir pup-ex NEVER reads/writes ``~/.code_puppy/``
3. Paths resolve correctly under both modes
4. ConfigIsolationViolation is raised on violations
5. The sandbox escape hatch works for tests
6. Split sub-modules honor the isolation contract
"""

from __future__ import annotations

import os
from pathlib import Path
from unittest import mock

import pytest

from code_puppy.config_paths import (
    ConfigIsolationViolation,
    assert_write_allowed,
    home_dir,
    is_pup_ex,
    legacy_home_dir,
    python_home_dir,
    safe_atomic_write,
    safe_mkdir_p,
    safe_write,
    with_sandbox,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def pup_ex_home(tmp_path):
    """Set PUP_EX_HOME to a temp dir and clean up after."""
    ex_home = str(tmp_path / ".code_puppy_ex")
    os.makedirs(ex_home, exist_ok=True)
    with mock.patch.dict(os.environ, {"PUP_EX_HOME": ex_home}):
        yield ex_home


@pytest.fixture
def pup_python_home(tmp_path):
    """Set PUP_HOME to a temp dir and clean up after."""
    py_home = str(tmp_path / ".code_puppy")
    os.makedirs(py_home, exist_ok=True)
    with mock.patch.dict(os.environ, {"PUP_HOME": py_home}):
        yield py_home


# ---------------------------------------------------------------------------
# is_pup_ex detection
# ---------------------------------------------------------------------------


class TestPupExDetection:
    def test_pup_ex_detected_via_env(self, pup_ex_home):
        assert is_pup_ex() is True

    def test_pup_ex_detected_via_runtime(self):
        with mock.patch.dict(os.environ, {"PUP_RUNTIME": "elixir"}):
            assert is_pup_ex() is True

    def test_standard_mode(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            # Remove PUP_EX_HOME and PUP_RUNTIME if set
            os.environ.pop("PUP_EX_HOME", None)
            os.environ.pop("PUP_RUNTIME", None)
            assert is_pup_ex() is False


# ---------------------------------------------------------------------------
# Home directory resolution
# ---------------------------------------------------------------------------


class TestHomeDirResolution:
    def test_ex_home_from_env(self, pup_ex_home):
        assert str(home_dir()) == pup_ex_home

    def test_ex_home_default(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            os.environ.pop("PUP_EX_HOME", None)
            os.environ.pop("PUP_RUNTIME", None)
            os.environ.pop("PUP_HOME", None)
            os.environ.pop("PUPPY_HOME", None)
            # In standard mode, should resolve to ~/.code_puppy
            assert str(home_dir()).endswith(".code_puppy")

    def test_python_home_dir_respects_pup_home(self, pup_python_home):
        os.environ.pop("PUP_EX_HOME", None)
        assert str(python_home_dir()) == pup_python_home

    def test_legacy_home_always_hardcoded(self):
        """legacy_home_dir() always returns ~/.code_puppy regardless of env."""
        result = str(legacy_home_dir())
        assert result.endswith(".code_puppy")


# ---------------------------------------------------------------------------
# Isolation guard
# ---------------------------------------------------------------------------


class TestIsolationGuard:
    def test_block_write_to_legacy_home_in_pup_ex(self, pup_ex_home):
        """ADR-003: pup-ex MUST NOT write to ~/.code_puppy/."""
        legacy_path = str(legacy_home_dir()) + "/test.txt"
        with pytest.raises(ConfigIsolationViolation):
            assert_write_allowed(legacy_path, "write")

    def test_block_mkdir_in_legacy_home(self, pup_ex_home):
        legacy_path = str(legacy_home_dir()) + "/subdir"
        with pytest.raises(ConfigIsolationViolation):
            assert_write_allowed(legacy_path, "mkdir")

    def test_allow_write_to_ex_home(self, pup_ex_home):
        """Writes to the active pup-ex home should be allowed."""
        ex_path = pup_ex_home + "/test.txt"
        # Should not raise
        assert_write_allowed(ex_path, "write")

    def test_allow_write_in_standard_mode(self):
        """Standard Python pup can write to ~/.code_puppy/."""
        with mock.patch.dict(os.environ, {}, clear=True):
            os.environ.pop("PUP_EX_HOME", None)
            os.environ.pop("PUP_RUNTIME", None)
            legacy_path = str(legacy_home_dir()) + "/test.txt"
            # Should not raise
            assert_write_allowed(legacy_path, "write")


# ---------------------------------------------------------------------------
# Safe write wrappers
# ---------------------------------------------------------------------------


class TestSafeWriteWrappers:
    def test_safe_write_in_pup_ex(self, pup_ex_home, tmp_path):
        target = str(tmp_path / "ex_home" / "test.txt")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        # Use sandbox to write outside the real home
        with with_sandbox(paths=[os.path.dirname(target)]):
            safe_write(target, "hello")
            assert Path(target).read_text() == "hello"

    def test_safe_mkdir_p_in_pup_ex(self, pup_ex_home, tmp_path):
        target = str(tmp_path / "ex_home" / "new_dir")
        with with_sandbox(paths=[target]):
            safe_mkdir_p(target)
            assert os.path.isdir(target)

    def test_safe_atomic_write_in_pup_ex(self, pup_ex_home, tmp_path):
        target = str(tmp_path / "ex_home" / "atomic.txt")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with with_sandbox(paths=[os.path.dirname(target)]):
            safe_atomic_write(target, "atomic content")
            assert Path(target).read_text() == "atomic content"


# ---------------------------------------------------------------------------
# Sandbox escape hatch
# ---------------------------------------------------------------------------


class TestSandbox:
    def test_sandbox_allows_all(self):
        with with_sandbox(allow_all=True):
            # Should not raise even for paths outside home
            assert_write_allowed("/tmp/arbitrary/test.txt", "write")

    def test_sandbox_whitelist(self, pup_ex_home):
        with with_sandbox(paths=["/tmp/specific_dir"]):
            assert_write_allowed("/tmp/specific_dir/file.txt", "write")

    def test_sandbox_restores_after_exit(self, pup_ex_home):
        """After sandbox exits, guard should be active again."""
        legacy_path = str(legacy_home_dir()) + "/test.txt"
        with with_sandbox(allow_all=True):
            # Inside sandbox: allowed
            assert_write_allowed(legacy_path, "write")
        # Outside sandbox: blocked
        with pytest.raises(ConfigIsolationViolation):
            assert_write_allowed(legacy_path, "write")


# ---------------------------------------------------------------------------
# Config sub-module isolation (code_puppy-ctj.2 specific)
# ---------------------------------------------------------------------------


class TestConfigSubmoduleIsolation:
    """Verify that the split config sub-modules honor ADR-003."""

    def test_paths_resolve_under_ex_home(self, pup_ex_home):
        """All path accessors must resolve under pup-ex home."""
        from code_puppy.config.paths import (
            _path_autosave_dir,
            _path_config_file,
            _xdg_cache_dir,
            _xdg_config_dir,
            _xdg_data_dir,
            _xdg_state_dir,
        )

        assert str(_xdg_config_dir()).startswith(pup_ex_home)
        assert str(_xdg_data_dir()).startswith(pup_ex_home)
        assert str(_xdg_cache_dir()).startswith(pup_ex_home)
        assert str(_xdg_state_dir()).startswith(pup_ex_home)
        assert str(_path_config_file()).startswith(pup_ex_home)
        assert str(_path_autosave_dir()).startswith(pup_ex_home)

    def test_lazy_path_constants_resolve_under_ex_home(self, pup_ex_home):
        """Lazy path constants (CONFIG_FILE etc.) must respect isolation."""
        from code_puppy.config import paths

        config_file = paths._LAZY_PATH_FACTORIES["CONFIG_FILE"]()
        assert str(config_file).startswith(pup_ex_home)

        models_file = paths._LAZY_PATH_FACTORIES["MODELS_FILE"]()
        assert str(models_file).startswith(pup_ex_home)

        autosave_dir = paths._LAZY_PATH_FACTORIES["AUTOSAVE_DIR"]()
        assert str(autosave_dir).startswith(pup_ex_home)

    def test_set_config_value_blocked_outside_home(self, pup_ex_home):
        """set_config_value must not write outside the active home."""
        from code_puppy.config.loader import set_config_value

        # Point config file to legacy home via override
        from code_puppy.config.paths import _LAZY_PATH_OVERRIDES

        _LAZY_PATH_OVERRIDES["CONFIG_FILE"] = str(legacy_home_dir()) + "/puppy.cfg"

        try:
            with pytest.raises(ConfigIsolationViolation):
                set_config_value("test_key", "test_value")
        finally:
            _LAZY_PATH_OVERRIDES.pop("CONFIG_FILE", None)


# ---------------------------------------------------------------------------
# Backward compatibility
# ---------------------------------------------------------------------------


class TestBackwardCompatibility:
    """Ensure the split package preserves all public API."""

    def test_all_public_names_exported(self):
        from code_puppy import config

        # Core access
        assert callable(getattr(config, "get_value", None))
        assert callable(getattr(config, "set_value", None))
        assert callable(getattr(config, "set_config_value", None))

        # Model management
        assert callable(getattr(config, "get_global_model_name", None))
        assert callable(getattr(config, "set_model_name", None))
        assert callable(getattr(config, "get_agent_pinned_model", None))

        # Feature toggles
        assert callable(getattr(config, "get_yolo_mode", None))
        assert callable(getattr(config, "get_use_dbos", None))
        assert callable(getattr(config, "get_auto_save_session", None))

        # Personalization
        assert callable(getattr(config, "get_puppy_name", None))
        assert callable(getattr(config, "get_owner_name", None))
        assert callable(getattr(config, "get_default_agent", None))

        # Limits
        assert callable(getattr(config, "get_protected_token_count", None))
        assert callable(getattr(config, "get_compaction_threshold", None))

        # UI
        assert callable(getattr(config, "get_banner_color", None))
        assert callable(getattr(config, "get_diff_addition_color", None))

        # Path constants
        assert config.CONFIG_FILE is not None
        assert config.DATA_DIR is not None
        assert config.AUTOSAVE_DIR is not None

        # Isolation
        assert config.is_pup_ex is not None
        assert config.home_dir is not None
        assert config.ConfigIsolationViolation is not None

    def test_module_submodule_access(self):
        """Sub-modules should be accessible from the package."""
        from code_puppy.config import agents, cache, debug, limits, mcp, models, tui

        assert hasattr(models, "get_global_model_name")
        assert hasattr(agents, "get_default_agent")
        assert hasattr(tui, "DEFAULT_BANNER_COLORS")
        assert hasattr(limits, "get_protected_token_count")
        assert hasattr(debug, "get_yolo_mode")
        assert hasattr(cache, "get_auto_save_session")
        assert hasattr(mcp, "load_mcp_server_configs")

    def test_from_config_import_pattern(self):
        """from code_puppy.config import X still works."""
        from code_puppy.config import (
            CONFIG_FILE,
            DEFAULT_BANNER_COLORS,
            get_value,
            get_yolo_mode,
        )

        assert get_value is not None
        assert get_yolo_mode is not None
        assert isinstance(DEFAULT_BANNER_COLORS, dict)
        assert isinstance(CONFIG_FILE, (str, Path))
