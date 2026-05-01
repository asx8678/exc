"""Tests for the Python mirror of Elixir feature flags."""

import json
import logging
from pathlib import Path
from typing import cast

import pytest

from code_puppy import feature_flags
from code_puppy.feature_flags import CAPABILITIES, FeatureFlagClient

EXPECTED_CAPABILITIES = {
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


def _enabled_state(client: FeatureFlagClient) -> dict[str, bool]:
    return {name: client.enabled(name) for name in feature_flags.CAPABILITIES}


def _assert_all_false(client: FeatureFlagClient) -> None:
    assert _enabled_state(client) == {
        name: False for name in feature_flags.CAPABILITIES
    }


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


class TestFileLoading:
    def test_missing_file_defaults_all_flags_false(self, tmp_path: Path) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        _assert_all_false(client)
        assert client.list() == [
            (name, False, description)
            for name, description in EXPECTED_CAPABILITIES.items()
        ]

    def test_empty_file_defaults_all_flags_false(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        path.write_text("", encoding="utf-8")
        _assert_all_false(FeatureFlagClient(path=path))

    def test_malformed_json_defaults_all_flags_false(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        path.write_text("this is not json at all {{{", encoding="utf-8")
        _assert_all_false(FeatureFlagClient(path=path))

    def test_invalid_utf8_file_defaults_all_false(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        path.write_bytes(b"\xff\xfe\xfd\xfc")
        client = FeatureFlagClient(path=path)
        for cap in CAPABILITIES:
            assert client.enabled(cap) is False

    def test_json_array_defaults_all_flags_false_and_warns(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, [1, 2, 3])

        with caplog.at_level(logging.WARNING, logger=feature_flags.__name__):
            _assert_all_false(FeatureFlagClient(path=path))

        assert "flags.json is not a JSON object" in caplog.text

    def test_valid_full_schema_loads_correctly(self, tmp_path: Path) -> None:
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

        assert _enabled_state(FeatureFlagClient(path=path)) == {
            "llm_client": True,
            "base_agent": False,
            "tools": True,
            "plugins": False,
            "cli": True,
        }

    def test_valid_partial_schema_defaults_missing_keys_false(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": True})
        client = FeatureFlagClient(path=path)

        assert client.enabled("cli") is True
        for capability in set(EXPECTED_CAPABILITIES) - {"cli"}:
            assert client.enabled(capability) is False

    def test_unprefixed_keys_are_accepted(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"llm_client": True})
        client = FeatureFlagClient(path=path)
        assert client.enabled("llm_client") is True

    def test_alias_collision_resolves_deterministically_unprefixed_first(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        path.write_text(
            json.dumps({"llm_client": True, "elixir.llm_client": False}),
            encoding="utf-8",
        )
        client = FeatureFlagClient(path=path)
        assert client.enabled("llm_client") is True

    def test_alias_collision_resolves_deterministically_prefixed_first(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        path.write_text(
            json.dumps({"elixir.llm_client": False, "llm_client": True}),
            encoding="utf-8",
        )
        client = FeatureFlagClient(path=path)
        assert client.enabled("llm_client") is True

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

        assert client.enabled("llm_client") is True
        for capability in set(EXPECTED_CAPABILITIES) - {"llm_client"}:
            assert client.enabled(capability) is False

    def test_non_bool_values_are_ignored_and_warn_once(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": "yes", "elixir.tools": True})

        with caplog.at_level(logging.WARNING, logger=feature_flags.__name__):
            client = FeatureFlagClient(path=path)
            client.reload()

        assert client.enabled("cli") is False
        assert client.enabled("tools") is True
        assert caplog.text.count("expected boolean") == 1


class TestClientApi:
    def test_enabled_known_capability_returns_current_bool(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.plugins": True})
        client = FeatureFlagClient(path=path)
        assert client.enabled("plugins") is True
        assert client.enabled("base_agent") is False

    def test_enabled_unknown_capability_raises_value_error(
        self, tmp_path: Path
    ) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        with pytest.raises(ValueError, match="Unknown feature-flag capability"):
            client.enabled("not_real")

    def test_list_returns_five_name_enabled_description_tuples(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": True, "elixir.cli": True})
        entries = FeatureFlagClient(path=path).list()

        assert entries == [
            ("llm_client", True, "Route LLM client calls to Elixir"),
            ("base_agent", False, "Route agent execution to Elixir"),
            ("tools", False, "Route tool dispatch to Elixir"),
            ("plugins", False, "Load plugins via Elixir loader"),
            ("cli", True, "Route CLI/REPL to Elixir"),
        ]
        assert all(len(entry) == 3 for entry in entries)

    def test_reload_reflects_external_disk_changes(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        assert client.enabled("cli") is False

        _write_json(path, {"elixir.cli": True})
        assert client.enabled("cli") is False

        client.reload()
        assert client.enabled("cli") is True

    def test_reload_from_corrupted_file_resets_to_all_false(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        path.write_text('{"elixir.cli": true}', encoding="utf-8")
        client = FeatureFlagClient(path=path)
        assert client.enabled("cli") is True
        path.write_bytes(b"\xff\xfe\xfd\xfc")
        client.reload()
        assert client.enabled("cli") is False

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
        assert client.enabled("tools") is True

    def test_set_non_bool_value_raises_type_error(self, tmp_path: Path) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        with pytest.raises(TypeError, match="must be bool"):
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

        _assert_all_false(client)
        assert _read_json(path) == {
            f"elixir.{name}": False for name in sorted(EXPECTED_CAPABILITIES)
        }

    def test_reset_after_sets_round_trips(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("llm_client", True)
        client.set("tools", True)
        client.reset()
        client.reload()
        _assert_all_false(client)

    def test_multiple_sets_persist_final_state(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("llm_client", True)
        client.set("tools", True)
        client.set("llm_client", False)

        assert client.enabled("llm_client") is False
        assert client.enabled("tools") is True
        decoded = _read_json(path)
        assert decoded["elixir.llm_client"] is False
        assert decoded["elixir.tools"] is True

    def test_client_without_path_uses_elixir_home(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setenv("PUP_EX_HOME", str(tmp_path))
        monkeypatch.delenv("PUP_HOME", raising=False)
        monkeypatch.delenv("PUPPY_HOME", raising=False)
        client = FeatureFlagClient()
        client.set("cli", True)
        assert (tmp_path / "flags.json").exists()
        assert client.enabled("cli") is True

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
        assert client.enabled("cli") is False


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
        assert ("cli", True, "Route CLI/REPL to Elixir") in (feature_flags.list_flags())

        _write_json(tmp_path / "flags.json", {"elixir.cli": False})
        assert feature_flags.enabled("cli") is True
        feature_flags.reload()
        assert feature_flags.enabled("cli") is False


class TestResilience:
    def test_recreated_client_after_disk_corruption_falls_back_all_false(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", True)
        assert client.enabled("cli") is True

        path.write_text("{ nope", encoding="utf-8")
        _assert_all_false(FeatureFlagClient(path=path))
