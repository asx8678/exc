"""Tests for the Python mirror of Elixir feature flags (core boolean behaviour)."""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import cast

import pytest

from code_puppy import feature_flags
from code_puppy.feature_flags import CAPABILITIES, FeatureFlagClient

EXPECTED_CAPABILITIES: dict[str, str] = {
    "llm_client": "Route LLM client calls to Elixir",
    "base_agent": "Route agent execution to Elixir",
    "tools": "Route tool dispatch to Elixir",
    "plugins": "Load plugins via Elixir loader",
    "cli": "Route CLI/REPL to Elixir",
}


def _flags_path(tmp_path: Path) -> Path:
    return tmp_path / "flags.json"


def _write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def _read_json(path: Path) -> dict[str, object]:
    return cast(dict[str, object], json.loads(path.read_text(encoding="utf-8")))


def _percentage_state(client: FeatureFlagClient) -> dict[str, int]:
    return {name: client.percentage(name) for name in feature_flags.CAPABILITIES}


def _assert_all_zero(client: FeatureFlagClient) -> None:
    assert _percentage_state(client) == {name: 0 for name in feature_flags.CAPABILITIES}


# ---------------------------------------------------------------------------
# Capability metadata
# ---------------------------------------------------------------------------


class TestCapabilityMetadata:
    def test_capabilities_match_elixir_schema(self) -> None:
        assert feature_flags.CAPABILITIES == EXPECTED_CAPABILITIES
        assert len(feature_flags.CAPABILITIES) == 5

    @pytest.mark.parametrize("capability", EXPECTED_CAPABILITIES)
    def test_json_key_formatting(self, capability: str) -> None:
        assert feature_flags.json_key(capability) == f"elixir.{capability}"
        assert feature_flags.json_key(f"ELIXIR.{capability.upper()}") == (
            f"elixir.{capability}"
        )


class TestResolver:
    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            ("llm_client", "llm_client"),
            ("elixir.llm_client", "llm_client"),
            ("  ELIXIR.CLI  ", "cli"),
            ("TOOLS", "tools"),
            (" plugins ", "plugins"),
        ],
    )
    def test_resolve_accepts_supported_string_forms(
        self, raw: str, expected: str
    ) -> None:
        assert feature_flags.resolve(raw) == expected

    def test_resolve_rejects_unknown_capability(self) -> None:
        with pytest.raises(ValueError, match="Unknown feature-flag capability"):
            feature_flags.resolve("elixir.future_cap")


class TestPathResolution:
    def test_elixir_home_env_precedence(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("PUP_EX_HOME", "/tmp/pup-ex")
        monkeypatch.setenv("PUP_HOME", "/tmp/pup-home")
        monkeypatch.setenv("PUPPY_HOME", "/tmp/puppy-home")
        assert feature_flags.elixir_home_dir() == Path("/tmp/pup-ex")
        assert feature_flags.flags_file() == Path("/tmp/pup-ex/flags.json")

        monkeypatch.delenv("PUP_EX_HOME")
        assert feature_flags.elixir_home_dir() == Path("/tmp/pup-home")

        monkeypatch.delenv("PUP_HOME")
        assert feature_flags.elixir_home_dir() == Path("/tmp/puppy-home")

    def test_default_elixir_home_is_code_puppy_ex(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.delenv("PUP_EX_HOME", raising=False)
        monkeypatch.delenv("PUP_HOME", raising=False)
        monkeypatch.delenv("PUPPY_HOME", raising=False)
        expected_home = Path.home() / ".code_puppy_ex"
        assert feature_flags.elixir_home_dir() == expected_home
        assert feature_flags.flags_file() == expected_home / "flags.json"

    def test_empty_pup_ex_home_is_treated_as_present(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("PUP_EX_HOME", "")
        monkeypatch.setenv("PUP_HOME", "/should/not/be/used")
        assert feature_flags.elixir_home_dir() == Path("")
        assert feature_flags.flags_file() == Path("flags.json")


# ---------------------------------------------------------------------------
# File loading — core boolean behaviour
# ---------------------------------------------------------------------------


class TestFileLoading:
    def test_missing_file_defaults_all_zero(self, tmp_path: Path) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        _assert_all_zero(client)
        entries = client.list()
        assert entries == [
            (name, 0, description)
            for name, description in EXPECTED_CAPABILITIES.items()
        ]

    def test_empty_file_defaults_all_zero(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        path.write_text("", encoding="utf-8")
        _assert_all_zero(FeatureFlagClient(path=path))

    def test_malformed_json_defaults_all_zero(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        path.write_text("not json {{{", encoding="utf-8")
        _assert_all_zero(FeatureFlagClient(path=path))

    def test_invalid_utf8_file_defaults_all_zero(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        path.write_bytes(b"\xff\xfe\xfd\xfc")
        client = FeatureFlagClient(path=path)
        for cap in CAPABILITIES:
            assert client.percentage(cap) == 0

    def test_json_array_defaults_all_zero_and_warns(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, [1, 2, 3])

        with caplog.at_level(logging.WARNING, logger=feature_flags.__name__):
            _assert_all_zero(FeatureFlagClient(path=path))

        assert "flags.json is not a JSON object" in caplog.text

    def test_valid_full_schema_bool_loads_correctly(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(
            path,
            {
                "elixir.llm_client": True,
                "elixir.base_agent": False,
                "elixir.tools": True,
                "elixir.plugins": False,
                "elixir.cli": True,
            },
        )

        assert _percentage_state(FeatureFlagClient(path=path)) == {
            "llm_client": 100,
            "base_agent": 0,
            "tools": 100,
            "plugins": 0,
            "cli": 100,
        }

    def test_valid_partial_schema_bool_defaults_missing_keys_zero(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": True})
        client = FeatureFlagClient(path=path)

        assert client.percentage("cli") == 100
        for capability in set(EXPECTED_CAPABILITIES) - {"cli"}:
            assert client.percentage(capability) == 0

    def test_unprefixed_keys_are_accepted(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"llm_client": True})
        client = FeatureFlagClient(path=path)
        assert client.percentage("llm_client") == 100

    def test_alias_collision_resolves_deterministically_unprefixed_first(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        path.write_text(
            json.dumps({"llm_client": True, "elixir.llm_client": False}),
            encoding="utf-8",
        )
        client = FeatureFlagClient(path=path)
        assert client.percentage("llm_client") == 100

    def test_alias_collision_resolves_deterministically_prefixed_first(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        path.write_text(
            json.dumps({"elixir.llm_client": False, "llm_client": True}),
            encoding="utf-8",
        )
        client = FeatureFlagClient(path=path)
        assert client.percentage("llm_client") == 100

    def test_unknown_keys_are_ignored(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(
            path,
            {
                "elixir.llm_client": True,
                "elixir.future_cap": True,
                "totally_random_key": True,
            },
        )
        client = FeatureFlagClient(path=path)

        assert client.percentage("llm_client") == 100
        for capability in set(EXPECTED_CAPABILITIES) - {"llm_client"}:
            assert client.percentage(capability) == 0

    def test_non_bool_non_int_values_are_ignored_and_warn_once(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": "yes", "elixir.tools": True})

        with caplog.at_level(logging.WARNING, logger=feature_flags.__name__):
            client = FeatureFlagClient(path=path)
            client.reload()

        assert client.percentage("cli") == 0
        assert client.percentage("tools") == 100
        assert caplog.text.count("expected boolean or integer") == 1


# ---------------------------------------------------------------------------
# Client API — percentage(), enabled(), is_enabled(), set()
# ---------------------------------------------------------------------------


class TestClientApi:
    def test_percentage_known_capability_returns_current_int(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.plugins": 42})
        client = FeatureFlagClient(path=path)
        assert client.percentage("plugins") == 42
        assert client.percentage("base_agent") == 0

    def test_unknown_capability_raises_value_error(self, tmp_path: Path) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        with pytest.raises(ValueError, match="Unknown feature-flag capability"):
            client.percentage("not_real")

    def test_list_returns_five_name_percentage_description_tuples(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": 100, "elixir.cli": 75})
        entries = FeatureFlagClient(path=path).list()

        assert entries == [
            ("llm_client", 100, "Route LLM client calls to Elixir"),
            ("base_agent", 0, "Route agent execution to Elixir"),
            ("tools", 0, "Route tool dispatch to Elixir"),
            ("plugins", 0, "Load plugins via Elixir loader"),
            ("cli", 75, "Route CLI/REPL to Elixir"),
        ]
        assert all(len(entry) == 3 for entry in entries)

    def test_reload_reflects_external_disk_changes(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        assert client.percentage("cli") == 0

        _write_json(path, {"elixir.cli": True})
        assert client.percentage("cli") == 0

        client.reload()
        assert client.percentage("cli") == 100

    def test_reload_from_corrupted_file_resets_to_all_zero(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        path.write_text('{"elixir.cli": true}', encoding="utf-8")
        client = FeatureFlagClient(path=path)
        assert client.percentage("cli") == 100
        path.write_bytes(b"\xff\xfe\xfd\xfc")
        client.reload()
        assert client.percentage("cli") == 0

    # --- set() with bool values ---

    def test_set_bool_true_persists_as_100(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", True)
        assert client.percentage("cli") == 100

    def test_set_bool_false_persists_as_0(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", False)
        assert client.percentage("cli") == 0

    def test_set_writes_canonical_keys_and_pretty_newline(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", True)

        raw = path.read_text(encoding="utf-8")
        decoded = _read_json(path)
        assert raw.endswith("\n")
        assert all(key.startswith("elixir.") for key in decoded)
        assert set(decoded) == {f"elixir.{name}" for name in EXPECTED_CAPABILITIES}
        assert decoded["elixir.cli"] is True
        assert decoded["elixir.llm_client"] is False

    def test_canonical_write_format_is_pinned(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", True)
        raw = path.read_text(encoding="utf-8")
        assert raw == (
            "{\n"
            '  "elixir.base_agent": false,\n'
            '  "elixir.cli": true,\n'
            '  "elixir.llm_client": false,\n'
            '  "elixir.plugins": false,\n'
            '  "elixir.tools": false\n'
            "}\n"
        )

    def test_set_updates_in_memory_without_reload(self, tmp_path: Path) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        client.set("ELIXIR.TOOLS", True)
        assert client.percentage("tools") == 100

    def test_set_non_bool_non_int_value_raises_type_error(self, tmp_path: Path) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        with pytest.raises(TypeError, match="must be bool or int"):
            client.set("cli", "yes")  # type: ignore[arg-type]

    def test_set_unknown_capability_raises_value_error(self, tmp_path: Path) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        with pytest.raises(ValueError, match="Unknown feature-flag capability"):
            client.set("unknown", True)

    def test_reset_writes_all_false_to_disk_and_memory(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("llm_client", True)
        client.reset()

        _assert_all_zero(client)
        decoded = _read_json(path)
        assert decoded == {
            f"elixir.{name}": False for name in sorted(EXPECTED_CAPABILITIES)
        }

    def test_reset_after_sets_round_trips(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("llm_client", True)
        client.set("tools", 50)
        client.reset()
        client.reload()
        _assert_all_zero(client)

    def test_multiple_sets_persist_final_state(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("llm_client", True)
        client.set("tools", 50)
        client.set("llm_client", False)

        assert client.percentage("llm_client") == 0
        assert client.percentage("tools") == 50
        decoded = _read_json(path)
        assert decoded["elixir.llm_client"] is False
        assert decoded["elixir.tools"] == 50

    def test_client_without_path_uses_elixir_home(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        monkeypatch.delenv("PUP_HOME", raising=False)
        monkeypatch.delenv("PUPPY_HOME", raising=False)
        client = FeatureFlagClient()
        client.set("cli", 25)
        assert (tmp_path / "flags.json").exists()
        assert client.percentage("cli") == 25

    def test_set_refuses_to_write_under_legacy_python_home(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        legacy = tmp_path / ".code_puppy"
        legacy.mkdir()
        monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
        flags_path = legacy / "flags.json"
        client = FeatureFlagClient(path=flags_path)
        with pytest.raises(RuntimeError, match="legacy"):
            client.set("cli", True)
        assert not flags_path.exists()
        assert client.percentage("cli") == 0

    # --- is_enabled() backward compat (deterministic) ---

    def test_is_enabled_deterministic_zero(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", 0)
        assert client.is_enabled("cli") is False

    def test_is_enabled_deterministic_one(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", 1)
        assert client.is_enabled("cli") is True

    def test_is_enabled_deterministic_twenty_five(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", 25)
        assert client.is_enabled("cli") is True

    def test_is_enabled_deterministic_one_hundred(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", 100)
        assert client.is_enabled("cli") is True


# ---------------------------------------------------------------------------
# Module-level API
# ---------------------------------------------------------------------------


class TestModuleLevelApi:
    def test_module_level_functions_delegate_to_default_client(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        monkeypatch.delenv("PUP_HOME", raising=False)
        monkeypatch.delenv("PUPPY_HOME", raising=False)

        feature_flags.reset()
        feature_flags.set_flag("cli", True)

        assert feature_flags.enabled("cli") is True
        assert ("cli", 100, "Route CLI/REPL to Elixir") in feature_flags.list_flags()

        _write_json(tmp_path / "flags.json", {"elixir.cli": False})
        assert feature_flags.enabled("cli") is True
        feature_flags.reload()
        assert feature_flags.enabled("cli") is False

    def test_module_level_is_enabled(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        feature_flags.reset()
        feature_flags.set_flag("cli", 25)
        assert feature_flags.is_enabled("cli") is True

    def test_set_flag_with_int_percentage(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        feature_flags.reset()
        feature_flags.set_flag("llm_client", 25)
        assert feature_flags.list_flags() == [
            ("llm_client", 25, "Route LLM client calls to Elixir"),
            ("base_agent", 0, "Route agent execution to Elixir"),
            ("tools", 0, "Route tool dispatch to Elixir"),
            ("plugins", 0, "Load plugins via Elixir loader"),
            ("cli", 0, "Route CLI/REPL to Elixir"),
        ]


# ---------------------------------------------------------------------------
# Resilience
# ---------------------------------------------------------------------------


class TestResilience:
    def test_recreated_client_after_disk_corruption_falls_back_all_zero(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", True)
        assert client.percentage("cli") == 100

        path.write_text("{ nope", encoding="utf-8")
        _assert_all_zero(FeatureFlagClient(path=path))

    def test_warning_deduplication(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Repeated warnings for the same key are only logged once."""
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": "maybe", "elixir.tools": "maybe"})
        with caplog.at_level(logging.WARNING, logger=feature_flags.__name__):
            client = FeatureFlagClient(path=path)
            client.reload()
            client.reload()
        assert caplog.text.count("expected boolean or integer") == 2
