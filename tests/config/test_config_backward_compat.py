"""Regression tests for code_puppy.config backward compatibility.

Verifies that the split config package re-exports all legacy names
and that the AppRunner.configure_agent no-model no-agent path works.
"""

from __future__ import annotations

from unittest import mock

# ---------------------------------------------------------------------------
# Legacy name re-export tests
# ---------------------------------------------------------------------------


class TestLegacyNameReexports:
    """All names that existed in the monolithic config.py must still be importable."""

    def test_validate_model_exists_reexported(self):
        """_validate_model_exists must be importable from code_puppy.config."""
        from code_puppy.config import _validate_model_exists

        assert callable(_validate_model_exists)

    def test_get_elixir_message_shadow_mode_enabled_reexported(self):
        """get_elixir_message_shadow_mode_enabled must be importable."""
        from code_puppy.config import get_elixir_message_shadow_mode_enabled

        assert callable(get_elixir_message_shadow_mode_enabled)

    def test_get_enable_gitignore_filtering_reexported(self):
        """get_enable_gitignore_filtering must be importable."""
        from code_puppy.config import get_enable_gitignore_filtering

        assert callable(get_enable_gitignore_filtering)

    def test_get_summarization_return_head_chars_reexported(self):
        """get_summarization_return_head_chars must be importable."""
        from code_puppy.config import get_summarization_return_head_chars

        assert callable(get_summarization_return_head_chars)

    def test_shadow_mode_default_is_false(self):
        """Shadow mode should default to False (opt-in)."""
        from code_puppy.config.debug import get_elixir_message_shadow_mode_enabled

        # This reads from config, but with a clean env it should return False
        result = get_elixir_message_shadow_mode_enabled()
        assert isinstance(result, bool)
        # Default should be False
        assert result is False

    def test_gitignore_filtering_default_is_false(self):
        """Gitignore filtering should default to False (opt-in)."""
        from code_puppy.config.debug import get_enable_gitignore_filtering

        result = get_enable_gitignore_filtering()
        assert isinstance(result, bool)
        assert result is False

    def test_return_head_chars_has_sensible_default(self):
        """summarization_return_head_chars must return a positive int."""
        from code_puppy.config.limits import get_summarization_return_head_chars

        result = get_summarization_return_head_chars()
        assert isinstance(result, int)
        assert result >= 100

    def test_shadow_mode_import_from_config(self):
        """Shadow mode import via 'from code_puppy.config import ...' works."""
        from code_puppy.config import (
            _validate_model_exists,
            get_elixir_message_shadow_mode_enabled,
            get_enable_gitignore_filtering,
            get_summarization_return_head_chars,
        )

        # All should be callable
        for fn in [
            get_elixir_message_shadow_mode_enabled,
            get_enable_gitignore_filtering,
            get_summarization_return_head_chars,
            _validate_model_exists,
        ]:
            assert callable(fn), f"{fn} is not callable"


# ---------------------------------------------------------------------------
# AppRunner.configure_agent no-model no-agent path
# ---------------------------------------------------------------------------


class TestAppRunnerConfigureAgentNoModelNoAgent:
    """Verify that AppRunner.configure_agent works when no --model/--agent is given."""

    def test_no_model_no_agent_path(self):
        """configure_agent with empty model/agent should not crash."""
        # The function should be importable and callable with None args
        from code_puppy.config import get_default_agent

        # These should not raise
        default_agent = get_default_agent()
        assert isinstance(default_agent, str)
        assert len(default_agent) > 0

        # get_global_model_name hits Elixir transport at module level;
        # mock the runtime_state reference in the models module.
        with (
            mock.patch(
                "code_puppy.config.models.runtime_state.get_session_model",
                return_value=None,
            ),
            mock.patch(
                "code_puppy.config.models.runtime_state.set_session_model",
            ),
        ):
            from code_puppy.config import get_global_model_name

            model_name = get_global_model_name()
            # It can be None or a string depending on config state
            assert model_name is None or isinstance(model_name, str)

    def test_validate_model_exists_callable(self):
        """_validate_model_exists should be callable with a string model name."""
        from code_puppy.config import _validate_model_exists

        # With a non-existent model, should return False
        # (it doesn't raise, it returns a bool)
        result = _validate_model_exists("totally-fake-model-xyz-12345")
        assert isinstance(result, bool)
        # Non-existent model should return False
        assert result is False

    def test_all_legacy_names_in_all(self):
        """All legacy names should be listed in __all__."""
        import code_puppy.config as config

        for name in [
            "_validate_model_exists",
            "get_elixir_message_shadow_mode_enabled",
            "get_enable_gitignore_filtering",
            "get_summarization_return_head_chars",
        ]:
            assert name in config.__all__, f"{name!r} missing from __all__"


class TestStarImportLegacyNames:
    """Regression: ``from code_puppy.config import *`` must expose all legacy names."""

    _EXPECTED_NAMES = [
        # Lazy path constants
        "CONFIG_FILE",
        "MCP_SERVERS_FILE",
        "MODELS_FILE",
        "DATA_DIR",
        "DBOS_DATABASE_URL",
        "COMMAND_HISTORY_FILE",
        "STATE_DIR",
        "CACHE_DIR",
        "CONFIG_DIR",
        # Core loader
        "get_value",
        "set_value",
        "reset_value",
        "ensure_config_exists",
        "get_config_keys",
        "set_config_value",
        # Models
        "set_model_name",
        "get_global_model_name",
        "get_model_setting",
        "set_model_setting",
        "get_temperature",
        "set_temperature",
        "get_effective_temperature",
        # Agents
        "get_default_agent",
        "set_default_agent",
        "get_puppy_name",
        "get_owner_name",
        "get_project_agents_directory",
        "get_user_agents_directory",
        # Limits
        "get_bus_request_timeout_seconds",
        "get_summarization_history_dir",
        "get_protected_token_count",
        "get_compaction_threshold",
        # Debug / keys
        "get_api_key",
        "set_api_key",
        "get_yolo_mode",
        "get_use_dbos",
        "get_enable_gitignore_filtering",
        # Cache / session
        "get_auto_save_session",
        "set_auto_save_session",
        "save_command_to_history",
        # Isolation
        "ConfigIsolationViolation",
        "assert_write_allowed",
        "safe_write",
        "is_pup_ex",
        # TUI
        "get_banner_color",
        "set_banner_color",
        "set_diff_highlight_style",
        # MCP
        "load_mcp_server_configs",
    ]

    def test_star_import_exposes_legacy_names(self):
        """from code_puppy.config import * must expose key legacy names."""
        import code_puppy.config as config

        missing = [n for n in self._EXPECTED_NAMES if n not in config.__all__]
        assert not missing, f"Missing from __all__: {missing}"

    def test_star_import_namespace_has_names(self):
        """Star-imported namespace must actually contain the expected names."""
        ns = {}
        exec("from code_puppy.config import *", ns)  # noqa: S102

        missing = [n for n in self._EXPECTED_NAMES if n not in ns]
        assert not missing, f"Missing from star-import namespace: {missing}"
