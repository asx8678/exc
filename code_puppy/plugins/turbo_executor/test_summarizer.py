"""Regression tests for turbo executor summarizer.

Covers: _summarize_list_files must safely handle all content shapes
returned by the runtime (string, list, wrapped dict, empty, malformed).
Also covers per-operation exception safety and register_callbacks fallback.
"""

import pytest

from code_puppy.plugins.turbo_executor.models import (
    OperationResult,
    OperationType,
    PlanResult,
    PlanStatus,
)
from code_puppy.plugins.turbo_executor.summarizer import (
    _normalize_list_files_content,
    _summarize_list_files,
    quick_summary,
    summarize_operation_result,
    summarize_plan_result,
)


class TestNormalizeListFilesContent:
    def test_string_content(self):
        data = {"content": "file_a.py\nfile_b.py"}
        entries, display, known = _normalize_list_files_content(data)
        assert entries == ["file_a.py", "file_b.py"]
        assert known is True

    def test_list_content(self):
        data = {"content": ["src/main.py", "README.md"]}
        entries, display, known = _normalize_list_files_content(data)
        assert entries == ["src/main.py", "README.md"]
        assert known is True

    def test_list_filters_none(self):
        data = {"content": ["a.py", None, "b.py"]}
        entries, _, known = _normalize_list_files_content(data)
        assert entries == ["a.py", "b.py"] and known is True

    def test_dict_wrapped_files(self):
        data = {"content": {"files": ["a.py", "b.py"]}}
        entries, _, known = _normalize_list_files_content(data)
        assert entries == ["a.py", "b.py"] and known is True

    def test_dict_unknown_shape_is_unknown(self):
        data = {"content": {"unexpected": "payload"}}
        entries, display, known = _normalize_list_files_content(data)
        assert len(entries) == 1 and known is False

    def test_none_content(self):
        entries, display, known = _normalize_list_files_content({"content": None})
        assert entries == [] and known is True

    def test_missing_content_key(self):
        entries, display, known = _normalize_list_files_content({})
        assert entries == [] and known is True

    def test_empty_string(self):
        entries, _, known = _normalize_list_files_content({"content": ""})
        assert entries == [] and known is True

    def test_empty_list(self):
        entries, _, known = _normalize_list_files_content({"content": []})
        assert entries == [] and known is True

    def test_integer_fallback_is_unknown(self):
        entries, display, known = _normalize_list_files_content({"content": 42})
        assert entries == ["42"] and known is False


class TestSummarizeListFiles:
    def test_list_content_no_crash(self):
        data = {"content": ["src/main.py", "README.md"]}
        result = _summarize_list_files(data)
        assert chr(128194) in result  # 📂 open folder emoji
        assert "2 files" in result

    def test_string_content_preserved(self):
        data = {"content": "file_a.py\nfile_b.py"}
        result = _summarize_list_files(data)
        assert "file_a.py" in result

    def test_dict_wrapped_content(self):
        data = {"content": {"files": ["a.py", "b.py", "c.py"]}}
        result = _summarize_list_files(data)
        assert "3 files" in result

    def test_error_data(self):
        result = _summarize_list_files({"error": "Directory not found"})
        assert "Directory not found" in result

    def test_empty_content(self):
        result = _summarize_list_files({"content": []})
        assert "empty" in result.lower() or "no files" in result.lower()

    def test_none_content(self):
        result = _summarize_list_files({"content": None})
        assert "empty" in result.lower() or "no files" in result.lower()

    def test_unknown_payload_uses_neutral_wording(self):
        result = _summarize_list_files({"content": 42})
        assert "unrecognized list_files payload" in result
        assert "1 files" not in result and "Found" not in result

    def test_unknown_dict_shape_uses_neutral_wording(self):
        result = _summarize_list_files({"content": {"weird": True}})
        assert "unrecognized list_files payload" in result

    def test_known_list_payload_shows_counts(self):
        result = _summarize_list_files({"content": ["a.py", "b.py"]})
        assert "2 files" in result and "unrecognized" not in result

    def test_large_list_truncated(self):
        data = {"content": [f"file_{i}.py" for i in range(500)]}
        result = _summarize_list_files(data)
        assert "500 files" in result


class TestSummarizeOperationResultSafety:
    """Per-operation summarization must not propagate exceptions."""

    def test_summarizer_raising_returns_fallback(self):
        op = OperationResult(
            operation_id="op-1",
            type=OperationType.LIST_FILES,
            status="success",
            data={"content": "irrelevant"},
            duration_ms=5.0,
        )
        # Patch the _OPERATION_SUMMARIZERS dict entry to trigger the except path
        from code_puppy.plugins.turbo_executor.summarizer import _OPERATION_SUMMARIZERS

        original = _OPERATION_SUMMARIZERS[OperationType.LIST_FILES]
        _OPERATION_SUMMARIZERS[OperationType.LIST_FILES] = lambda d: (
            _ for _ in ()
        ).throw(RuntimeError("boom"))
        try:
            result = summarize_operation_result(op)
        finally:
            _OPERATION_SUMMARIZERS[OperationType.LIST_FILES] = original
        assert "summary unavailable" in result
        assert "structured data returned successfully" in result

    def test_grep_summarizer_raising_returns_fallback(self):
        op = OperationResult(
            operation_id="op-2",
            type=OperationType.GREP,
            status="success",
            data={"malformed": True},
            duration_ms=5.0,
        )
        from code_puppy.plugins.turbo_executor.summarizer import _OPERATION_SUMMARIZERS

        original = _OPERATION_SUMMARIZERS[OperationType.GREP]
        _OPERATION_SUMMARIZERS[OperationType.GREP] = lambda d: (_ for _ in ()).throw(
            ValueError("bad data")
        )
        try:
            result = summarize_operation_result(op)
        finally:
            _OPERATION_SUMMARIZERS[OperationType.GREP] = original
        assert "summary unavailable" in result and "grep" in result

    def test_normal_operation_not_affected(self):
        op = OperationResult(
            operation_id="op-1",
            type=OperationType.LIST_FILES,
            status="success",
            data={"content": ["a.py"]},
            duration_ms=5.0,
        )
        result = summarize_operation_result(op)
        assert "1 files" in result and "unavailable" not in result

    def test_error_status_skips_summarizer(self):
        op = OperationResult(
            operation_id="op-1",
            type=OperationType.LIST_FILES,
            status="error",
            error="Permission denied",
            data={},
            duration_ms=5.0,
        )
        result = summarize_operation_result(op)
        assert "Operation Failed" in result


class TestPlanResultRobustness:
    def _make_plan(self, content):
        op = OperationResult(
            operation_id="op-1",
            type=OperationType.LIST_FILES,
            status="success",
            data={"content": content},
            duration_ms=10.0,
        )
        return PlanResult(
            plan_id="test-plan",
            status=PlanStatus.COMPLETED,
            operation_results=[op],
            total_duration_ms=10.0,
        )

    def test_plan_with_list_content(self):
        summary = summarize_plan_result(self._make_plan(["a.py", "b.py"]))
        assert "test-plan" in summary and "2 files" in summary

    def test_plan_with_string_content(self):
        summary = summarize_plan_result(self._make_plan("a.py\nb.py"))
        assert "test-plan" in summary

    def test_plan_with_malformed_content(self):
        summary = summarize_plan_result(self._make_plan(42))
        assert "test-plan" in summary

    def test_quick_summary_always_works(self):
        result = quick_summary(self._make_plan(["a.py"]))
        assert "test-plan" in result and "1/1 ops" in result

    def test_plan_survives_broken_operation_summarizer(self):
        op = OperationResult(
            operation_id="op-1",
            type=OperationType.LIST_FILES,
            status="success",
            data={"content": "string"},
            duration_ms=5.0,
        )
        plan = PlanResult(
            plan_id="test-plan",
            status=PlanStatus.COMPLETED,
            operation_results=[op],
            total_duration_ms=10.0,
        )
        summary = summarize_plan_result(plan)
        assert "test-plan" in summary


class TestRegisterCallbacksFallback:
    """Exercises the real fallback path in register_callbacks.py."""

    @pytest.mark.asyncio
    async def test_fallback_summary_preserves_counts(self):
        """When summarize_plan_result raises inside turbo_execute,
        the response still contains structured results + fallback summary."""
        import json
        from unittest.mock import AsyncMock, MagicMock, patch

        from pydantic_ai import RunContext

        from code_puppy.plugins.turbo_executor.models import (
            OperationResult,
            OperationType,
            PlanResult,
            PlanStatus,
        )
        from code_puppy.plugins.turbo_executor.register_callbacks import (
            _register_turbo_execute_tool,
        )

        # --- Build a fake orchestrator ---
        fake_plan_result = PlanResult(
            plan_id="cb-fallback-test",
            status=PlanStatus.PARTIAL,
            operation_results=[
                OperationResult(
                    operation_id="op-1",
                    type=OperationType.LIST_FILES,
                    status="success",
                    data={"content": ["a.py"]},
                    duration_ms=5.0,
                ),
                OperationResult(
                    operation_id="op-2",
                    type=OperationType.LIST_FILES,
                    status="error",
                    error="oops",
                    data={},
                    duration_ms=3.0,
                ),
            ],
            total_duration_ms=8.0,
        )

        fake_orch = MagicMock()
        fake_orch.validate_plan.return_value = []  # no validation errors
        fake_orch.execute = AsyncMock(return_value=fake_plan_result)

        # --- Capture the turbo_execute function via a fake agent ---
        captured = {}

        class FakeAgent:
            def tool(self, fn):
                captured["fn"] = fn
                return fn

        _register_turbo_execute_tool(FakeAgent())
        turbo_execute_fn = captured["fn"]

        # --- Build a minimal RunContext ---
        ctx = RunContext(deps=None, model=None, usage=None)

        # --- Build valid plan_json ---
        plan_json = json.dumps(
            {
                "id": "cb-fallback-test",
                "operations": [
                    {
                        "type": "list_files",
                        "args": {"directory": "."},
                        "id": "op-1",
                    },
                ],
            }
        )

        # --- Patch: orchestrator + summarize_plan_result that raises ---
        with (
            patch(
                "code_puppy.plugins.turbo_executor.register_callbacks._get_orchestrator",
                return_value=fake_orch,
            ),
            patch(
                "code_puppy.plugins.turbo_executor.register_callbacks.summarize_plan_result",
                side_effect=RuntimeError("summary boom"),
            ),
        ):
            response = await turbo_execute_fn(ctx, plan_json, summarize=True)

        # --- Assertions on the real response dict ---
        assert response["success_count"] == 1, (
            f"expected 1, got {response.get('success_count')}"
        )
        assert response["error_count"] == 1, (
            f"expected 1, got {response.get('error_count')}"
        )
        assert "cb-fallback-test" in response.get("summary", ""), (
            f"fallback summary missing plan_id; got: {response.get('summary')!r}"
        )
        assert "Structured results are included" in response.get("summary", ""), (
            f"fallback summary missing structured-results hint; got: {response.get('summary')!r}"
        )
        assert "quick_summary" in response, "quick_summary key missing"
        assert "1 success" in response["quick_summary"], (
            f"quick_summary wrong; got: {response['quick_summary']!r}"
        )
        assert "operation_results" in response, "operation_results key missing"
        assert len(response["operation_results"]) == 2, (
            f"expected 2 op results, got {len(response['operation_results'])}"
        )
