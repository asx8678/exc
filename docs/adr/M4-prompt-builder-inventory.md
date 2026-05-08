# M4: Prompt Builder Inventory

## Summary
- **12 manual callers** of `on_load_prompt()`
- **7 plugin providers** on `load_prompt` hook
- **7 agents don't call** `on_load_prompt()` in their `get_system_prompt()`
- **Cache issue**: `cached_system_prompt` never invalidated on plugin state change

## Manual Callers (12 total)

| File | Line | Context Source | Notes |
|------|------|----------------|-------|
| `agent_tools.py` | :688 | explicit | invoke_agent subagent |
| `agent_tools.py` | :979 | explicit | run_agent_task (uses _trigger_callbacks_sync) |
| `agent_code_puppy.py` | :93 | session | get_system_prompt |
| `agent_planning.py` | :161 | session | get_system_prompt |
| `prompt_reviewer.py` | :140 | session | get_system_prompt |
| `agent_pack_leader.py` | :413 | session | get_system_prompt |
| `pack/shepherd.py` | :300 | session | get_system_prompt |
| `pack/watchdog.py` | :363 | session | get_system_prompt |
| `pack/terrier.py` | :283 | session | get_system_prompt |
| `pack/retriever.py` | :389 | session | get_system_prompt |
| `pack/shepherd.py` | :341 | session | get_system_prompt |

## Agents WITHOUT on_load_prompt (7)

| Agent | File |
|-------|------|
| AgentGolangReviewer | agent_golang_reviewer.py |
| AgentTypescriptReviewer | agent_typescript_reviewer.py |
| AgentSecurityAuditor | agent_security_auditor.py |
| AgentJavascriptReviewer | agent_javascript_reviewer.py |
| AgentPythonReviewer | agent_python_reviewer.py |
| AgentPythonProgrammer | agent_python_programmer.py |
| AgentTerminalQA | agent_terminal_qa.py |
| AgentTurboExecutor | agent_turbo_executor.py |
| JsonAgent | json_agent.py |

## Plugin Providers (7)

| Plugin | Callback |
|--------|----------|
| file_mentions | _on_load_prompt |
| ttsr | inject_triggered_rules |
| prompt_store | load_custom_prompt |
| file_permission_handler | get_file_permission_prompt_additions |
| pack_parallelism | _prompt_addition |
| turbo_executor | _load_turbo_prompt |

## Cache Location
- `AgentRuntimeState.cached_system_prompt` in `agent_state.py:60`
- Populated in `base_agent.py:1535-1541`
- **Never invalidated on plugin state change** - stale prompt risk

## M5 Scope Based on This Inventory

1. Add `on_load_prompt()` to `AgentPromptMixin.get_full_system_prompt()`
2. Remove manual calls from 10 agents (keep agent_tools.py special handling)
3. Add cache invalidation hook for prompt-affecting plugin changes
