"""Tests for percentage-based rollout in feature flags.

Covers: integer percentage parsing from JSON, percentage-based set(),
probabilistic enabled() behaviour, and percentage serialization.
"""

from __future__ import annotations

import json
import logging
import random
from pathlib import Path

import pytest

from code_puppy import feature_flags
from code_puppy.feature_flags import FeatureFlagClient


def _flags_path(tmp_path: Path) -> Path:
    return tmp_path / "flags.json"


def _write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def _read_json(path: Path) -> dict[str, object]:
    import json as _json

    return _json.loads(path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Percentage parsing from JSON
# ---------------------------------------------------------------------------


class TestPercentageParsing:
    def test_integer_percentage_parsed_correctly(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": 25, "elixir.cli": 75})
        client = FeatureFlagClient(path=path)
        assert client.percentage("llm_client") == 25
        assert client.percentage("cli") == 75

    def test_mixed_bool_and_int_in_json(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(
            path,
            {
                "elixir.llm_client": True,
                "elixir.base_agent": 0,
                "elixir.tools": 50,
            },
        )
        client = FeatureFlagClient(path=path)
        assert client.percentage("llm_client") == 100
        assert client.percentage("base_agent") == 0
        assert client.percentage("tools") == 50

    def test_integer_outside_range_warns_and_defaults_to_zero(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": 999})
        with caplog.at_level(logging.WARNING, logger=feature_flags.__name__):
            client = FeatureFlagClient(path=path)
        assert client.percentage("cli") == 0
        assert "expected boolean or integer 0..100" in caplog.text

    def test_negative_integer_warns_and_defaults_to_zero(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": -5})
        with caplog.at_level(logging.WARNING, logger=feature_flags.__name__):
            client = FeatureFlagClient(path=path)
        assert client.percentage("cli") == 0


# ---------------------------------------------------------------------------
# set() with integer percentages
# ---------------------------------------------------------------------------


class TestPercentageSet:
    def test_set_int_75_stores_as_75(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", 75)
        assert client.percentage("cli") == 75

    def test_set_int_0_stores_as_0(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", 0)
        assert client.percentage("cli") == 0

    def test_set_int_100_stores_as_100(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", 100)
        assert client.percentage("cli") == 100

    def test_canonical_write_format_50_percent(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("cli", 50)
        raw = path.read_text(encoding="utf-8")
        assert '"elixir.cli": 50' in raw
        assert raw.endswith("\n")

    def test_canonical_write_format_zeros_and_hundreds_as_bool(
        self, tmp_path: Path
    ) -> None:
        path = _flags_path(tmp_path)
        client = FeatureFlagClient(path=path)
        client.set("llm_client", 100)
        client.set("base_agent", 0)
        client.set("tools", 50)
        decoded = _read_json(path)
        assert decoded["elixir.llm_client"] is True
        assert decoded["elixir.base_agent"] is False
        assert decoded["elixir.tools"] == 50

    def test_set_int_out_of_range_raises_value_error(self, tmp_path: Path) -> None:
        client = FeatureFlagClient(path=_flags_path(tmp_path))
        with pytest.raises(ValueError, match="must be 0..100"):
            client.set("cli", 101)
        with pytest.raises(ValueError, match="must be 0..100"):
            client.set("cli", -1)


# ---------------------------------------------------------------------------
# Probabilistic enabled() behaviour
# ---------------------------------------------------------------------------


class TestProbabilisticEnabled:
    def test_zero_percent_always_returns_false(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": 0})
        client = FeatureFlagClient(path=path)
        for _ in range(100):
            assert client.enabled("llm_client") is False

    def test_one_hundred_percent_always_returns_true(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": 100})
        client = FeatureFlagClient(path=path)
        for _ in range(100):
            assert client.enabled("llm_client") is True

    def test_fifty_percent_roughly_half(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": 50})
        client = FeatureFlagClient(path=path)

        # Deterministic seed for reproducibility
        random.seed(42)
        true_count = sum(client.enabled("llm_client") for _ in range(1000))
        assert 400 <= true_count <= 600, f"Expected ~500, got {true_count} (seed=42)"

    def test_twenty_five_percent_roughly_quarter(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": 25})
        client = FeatureFlagClient(path=path)

        random.seed(42)
        true_count = sum(client.enabled("llm_client") for _ in range(1000))
        assert 175 <= true_count <= 325, f"Expected ~250, got {true_count} (seed=42)"

    def test_seventy_five_percent_roughly_three_quarters(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": 75})
        client = FeatureFlagClient(path=path)

        random.seed(42)
        true_count = sum(client.enabled("llm_client") for _ in range(1000))
        assert 675 <= true_count <= 825, f"Expected ~750, got {true_count} (seed=42)"

    def test_boolean_true_backward_compat(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": True})
        client = FeatureFlagClient(path=path)
        for _ in range(50):
            assert client.enabled("cli") is True

    def test_boolean_false_backward_compat(self, tmp_path: Path) -> None:
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.cli": False})
        client = FeatureFlagClient(path=path)
        for _ in range(50):
            assert client.enabled("cli") is False

    def test_probabilistic_differs_from_deterministic_for_partial(
        self, tmp_path: Path
    ) -> None:
        """For 1..99%, enabled() is probabilistic while is_enabled() is deterministic.

        This test verifies the semantic difference: is_enabled() returns True
        even when a particular enabled() call returns False.
        """
        path = _flags_path(tmp_path)
        _write_json(path, {"elixir.llm_client": 50})
        client = FeatureFlagClient(path=path)

        random.seed(99)  # A seed known to produce some False results at 50%
        saw_false = any(not client.enabled("llm_client") for _ in range(100))
        assert saw_false, (
            "At 50%, enabled() should probabilistically return False sometimes"
        )
        # Clear the seeded state ... is_enabled() is always True
        assert client.is_enabled("llm_client") is True
