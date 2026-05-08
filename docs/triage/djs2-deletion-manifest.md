# djs.2 Deletion Manifest — Python Tree Cleanup

**Issue:** code_puppy-djs.2
**Date:** 2026-07-12
**Status:** CATEGORIES A, B, D COMPLETE — ~10,726 LoC deleted ✅

## Context

The Python-to-Elixir migration (Phases A–G) is complete. Phase H infrastructure
(FeatureFlags, RuntimeSelector, Rollout) is implemented. This manifest identifies
Python modules that are **redundant** — fully replaced by Elixir equivalents and
no longer called by the retained thin shell.

**Important:** The Python "thin shell" (~35K LoC) is RETAINED permanently:
- CLI entry points, TUI (Textual/Rich), pydantic-ai agent orchestration
- Bridge layer (elixir_bridge/)
- Plugin system core (callbacks.py, __init__.py)
- Config system, tool schema/binding interfaces

## Plugin Triage (33 unported plugins)

| Plugin | Decision | Rationale |
|--------|----------|-----------|
| `agent_shortcuts` | BRIDGE | Convenience aliases — works via callback bridge |
| `agent_skills` | BRIDGE | Skill injection — reachable via load_prompt hook |
| `auto_test_control` | DROP | Testing utility — not user-facing |
| `claude_code_hooks` | BRIDGE | Claude-specific hooks — works via callback bridge |
| `clean_command` | BRIDGE | Slash command — reachable via custom_command hook |
| `code_explorer` | DELETE (djs.2) | Thin wrapper over Elixir bridge — Elixir `CodeContext` handles natively |
| `code_skeleton` | DELETE (djs.2) | Regex fallback — Elixir `Parser` handles natively |
| `completion_notifier` | DROP | Desktop notifications — low value |
| `customizable_commands` | BRIDGE | Custom slash commands — works via custom_command hook |
| `dual_home` | RETAIN | ADR-003 isolation — critical for thin shell |
| `error_logger` | DROP | Debugging utility — redundant with Elixir Logger |
| `example_custom_command` | DROP | Example/demo code — not needed in production |
| `file_permission_handler` | BRIDGE | Permission decisions — works via file_permission hook |
| `frontend_emitter` | DROP | WebSocket emitter — replaced by Phoenix endpoint |
| `hook_creator` | BRIDGE | Hook management — works via callback bridge |
| `hook_manager` | BRIDGE | Hook lifecycle — works via callback bridge |
| `ollama_setup` | BRIDGE | Model setup — works via custom_command hook |
| `pop_command` | BRIDGE | Slash command — reachable via custom_command hook |
| `proactive_guidance` | BRIDGE | Guidance injection — works via load_prompt hook |
| `prompt_store` | BRIDGE | Prompt management — works via callback bridge |
| `remember_last_agent` | BRIDGE | Agent memory — works via agent_run_end hook |
| `render_check` | DROP | Render validation — debugging utility |
| `repo_compass` | DELETE (djs.2) | Elixir `RepoCompass` + `CodeContext` cover indexing |
| `session_logger` | BRIDGE | Session logging — works via agent_run_end hook |
| `shell_safety` | BRIDGE | Shell command validation — works via run_shell_command hook |
| `supervisor_review` | BRIDGE | Review orchestration — works via callback bridge |
| `synthetic_status` | DROP | Status display — debugging utility |
| `theme_switcher` | BRIDGE | Theme management — works via custom_command hook |
| `tool_allowlist` | BRIDGE | Tool filtering — works via pre_tool_call hook |
| `tracing_langfuse` | DROP | External tracing — optional integration |
| `tracing_langsmith` | DROP | External tracing — optional integration |
| `ttsr` | DROP | Text-to-speech — experimental feature |

**Summary:** 9 DROP, 19 BRIDGE, 3 DELETE (djs.2), 1 RETAIN (dual_home)

## Deletion Categories

### Category A: SAFE TO DELETE (fully ported, no thin-shell dependency) — ✅ COMPLETE

These modules have complete Elixir equivalents AND nothing in the retained thin shell imports them directly:

| Path | Lines | Elixir Replacement | Confidence | Audit Note |
|------|-------|-------------------|------------|------------|
| `code_puppy/api/` | 2,296 | `CodePuppyControlWeb` (Phoenix) | HIGH | `core_commands.py:636` has subprocess string `"code_puppy.api.main"` — trivial cleanup done |
| `code_puppy/plugins/state_migration/` | 855 | `SessionStorage.Migrator` | HIGH | `tests/test_state_migration.py` also deleted |
| `code_puppy/plugins/error_logger/` | 166 | Elixir Logger | HIGH | No external imports |
| `code_puppy/plugins/example_custom_command/` | 51 | Example only | HIGH | No external imports |
| `code_puppy/plugins/auto_test_control/` | 341 | Testing utility | HIGH | No external imports |
| `code_puppy/plugins/completion_notifier/` | 207 | Low value | HIGH | No external imports |
| `code_puppy/plugins/frontend_emitter/` | 468 | Phoenix endpoint | HIGH | Only caller is `api/websocket.py` (also deleted) |
| `code_puppy/plugins/render_check/` | 232 | Debugging utility | HIGH | No external imports |
| `code_puppy/plugins/synthetic_status/` | 264 | Debugging utility | HIGH | No external imports |
| `code_puppy/plugins/tracing_langfuse/` | 473 | Optional integration | HIGH | No external imports |
| `code_puppy/plugins/tracing_langsmith/` | 469 | Optional integration | HIGH | No external imports |
| `code_puppy/plugins/ttsr/` | 804 | Experimental | HIGH | No external imports |

**Estimated deletion: ~6,626 LoC** ✅

### Category B: DELETE WITH CAUTION (ported but has thin-shell callers) — ✅ COMPLETE

| Path | Lines | Elixir Replacement | Thin-Shell Callers | Cleanup Action |
|------|-------|-------------------|-------------------|----------------|
| `code_puppy/tools/browser/` | 4,750 | DROP-V1 (no replacement) | `tools/__init__.py` (re-exports), `agent_tools.py` (session context) | Removed all browser imports + registry entries from `__init__.py`; removed session context from `agent_tools.py`; added browser tool names to `REMOVED_LEGACY_TOOLS` |
| `code_puppy/scheduler/` | 840 | `CodePuppyControl.Scheduler` (Oban) | `scheduler_tools.py`, `tui/screens/scheduler_screen.py`, `plugins/scheduler/` | Stubbed `scheduler_tools.py` (returns migration message); deleted `scheduler_screen.py`; updated `tui/app.py` `/scheduler` command to emit info message; deleted `plugins/scheduler/` |

**Estimated deletion: ~4,750 + 840 + 972 + 304 = ~6,866 LoC (directories) + ~285 LoC (scheduler_tools rewrite) + ~75 LoC (tools/__init__.py rewrite) = ~7,226 net LoC removed**

### Category C: RETAIN (thin shell dependency)

Everything in Tiers 1-8 of THIN_SHELL_CONTRACT stays.

### Category D: Elixir equivalents exist — ✅ COMPLETE

| Path | Lines | Elixir Replacement | Action |
|------|-------|-------------------|--------|
| `code_puppy/plugins/repo_compass/` | 1,691 | `CodePuppyControl.Indexer.RepoCompass` | Deleted — Elixir RepoCompass + CodeContext cover indexing; `load_prompt` injection handled by Elixir `stdio_service.ex` `code_context.*` handlers |
| `code_puppy/plugins/code_explorer/` + `code_puppy/code_context/` | 575 + 859 = 1,434 | `CodePuppyControl.CodeContext` | Deleted — thin wrapper over Elixir bridge calls; `code_context/` only used by `code_explorer` plugin |
| `code_puppy/plugins/code_skeleton/` | 375 | `CodePuppyControl.Parsing.Parser` | Deleted — skeleton generation is Elixir-native; regex fallback is legacy |

**Estimated deletion: ~1,691 + 1,434 + 375 = ~3,500 LoC**

## Execution Summary

| Category | LoC Deleted | Status |
|----------|------------|--------|
| A | ~6,626 | ✅ COMPLETE |
| B | ~7,226 net | ✅ COMPLETE |
| D | ~3,500 | ✅ COMPLETE |
| **Total** | **~17,352** | **✅** |

## Post-Deletion Verification

- [x] `uv run pytest tests/` passes (108 passed)
- [x] `uv run ruff check code_puppy/` clean (no import errors)
- [ ] `cd elixir/code_puppy_control && mix test` passes (Elixir side)
- [ ] No runtime import errors on `uv run pup -i` (manual check)
