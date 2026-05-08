# Python Module Dependency Graph

> Generated for Python-to-Elixir migration planning. See [ADR-004](adr/ADR-004-python-to-elixir-migration-strategy.md).

**Generated**: 2026-01-01T00:00:00+00:00
**Total modules analyzed**: 521

## Summary Statistics

| Metric | Value |
|--------|-------|
| Total modules | 521 |
| Total lines of code | 145,692 |
| Leaf modules (no internal deps) | 144 |
| Hub modules (≥10 importers) | 22 |
| Import cycles detected | 106 |

## High-Fan-In Hub Modules (High Blast Radius)

> These modules are imported by many others. Because dependents rely on their interface, they require compatibility facades and extra review during migration. Use the dependency-first porting order below rather than a blanket “port last” rule — the generated order already ensures dependencies precede their importers.

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `messaging` | 131 | 10 | 268 |
| `config` | 109 | 12 | 2,694 |
| `callbacks` | 72 | 5 | 1,228 |
| `code_puppy` | 31 | 2 | 93 |
| `config_paths` | 31 | 1 | 427 |
| `tools.command_runner` | 27 | 8 | 1,812 |
| `agents` | 26 | 2 | 31 |
| `agents.base_agent` | 26 | 25 | 2,901 |
| `tools.common` | 25 | 9 | 1,315 |
| `agents.agent_manager` | 19 | 9 | 1,038 |
| `tui.base_screen` | 18 | 0 | 25 |
| `command_line.mcp.base` | 15 | 1 | 32 |
| `command_line.command_registry` | 14 | 0 | 150 |
| `mcp_.managed_server` | 14 | 5 | 442 |
| `model_factory` | 14 | 13 | 1,143 |

## Low-Dependency Leaf Candidates (Port FIRST)

> These modules have few or no internal dependencies. Safe to port early.

| Module | Fan-In | LOC | Notes |
|--------|--------|-----|-------|
| `tools.process_runner_protocol` | 0 | 370 | Pure leaf |
| `tool_schema` | 0 | 369 | Pure leaf |
| `mcp_.system_tools` | 0 | 207 | Pure leaf |
| `utils.editor_detect` | 0 | 137 | Pure leaf |
| `utils.gitignore` | 0 | 121 | Pure leaf |
| `utils.symbol_hierarchy` | 0 | 110 | Pure leaf |
| `plugins.frontend_emitter` | 0 | 24 | Pure leaf |
| `plugins.prompt_store` | 0 | 20 | Pure leaf |
| `plugins.session_logger` | 0 | 9 | Pure leaf |
| `plugins.ttsr` | 0 | 9 | Pure leaf |
| `plugins.repo_compass` | 0 | 8 | Pure leaf |
| `plugins.loop_detection` | 0 | 6 | Pure leaf |
| `plugins.shell_safety` | 0 | 6 | Pure leaf |
| `plugins.tracing_langfuse` | 0 | 6 | Pure leaf |
| `plugins.ollama_setup` | 0 | 5 | Pure leaf |
| `plugins.tracing_langsmith` | 0 | 5 | Pure leaf |
| `tui.screens` | 0 | 5 | Pure leaf |
| `plugins.file_permission_handler` | 0 | 4 | Pure leaf |
| `plugins.completion_notifier` | 0 | 3 | Pure leaf |
| `plugins.render_check` | 0 | 3 | Pure leaf |

## Import Cycles Detected

> Cycles must be broken before porting (refactor to remove circular deps).

1. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → code_puppy`
2. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → code_puppy`
3. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → plugins → config → code_puppy`
4. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → plugins → config → config_package.loader → code_puppy`
5. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → plugins → config → model_factory → code_puppy`
6. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → plugins → config → model_factory → claude_cache_client → plugins.claude_code_oauth.utils → plugins.claude_code_oauth.config → code_puppy`
7. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → plugins → config → model_factory → model_utils → code_puppy`
8. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → plugins → config → session_storage → code_puppy`
9. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → plugins → config → session_storage → command_line.prompt_toolkit_completion → code_puppy`
10. `code_puppy → agents → agents.agent_manager → agents.base_agent → agents.agent_prompt_mixin → callbacks → plugins → config → session_storage → command_line.prompt_toolkit_completion → command_line.mcp_completion → mcp_.manager → mcp_.registry → code_puppy`

... and 96 more cycles

## Recommended Porting Order

> Ordered by topological level (dependencies first). For acyclic dependencies, if A imports B, B appears before A. Within an SCC (import cycle), members may be grouped/ordered arbitrarily, but outside-cycle dependencies still come first. Within each level, sorted by fan-in (lowest first).

| Phase | Modules | Criteria |
|-------|---------|----------|
| Foundation (depth=0) | `command_line`, `mcp_.system_tools`, `mcp_prompts`, `plugins.agent_shortcuts`, `plugins.auto_test_control` (+141 more) | Leaves → Hubs |
| Utilities (depth=1) | `mcp_.examples.retry_example`, `plugins.agent_skills`, `plugins.repo_compass.marker_merge`, `scheduler.platform`, `agents.agent_state` (+30 more) | Leaves → Hubs |
| Core Services (depth=2) | `agent_pinning_transport`, `text_ops`, `utils.hashline`, `hook_engine.executor`, `message_transport` (+12 more) | Leaves → Hubs |
| Agents (depth=3) | `plugins.error_classifier`, `command_line.skills_completion`, `hook_engine.engine`, `tui.screens.skills_install_screen`, `plugins.agent_trace.cli_analytics` | Leaves → Hubs |
| Integration (depth=4) | `plugins.agent_trace`, `agents.agent_prompt_mixin`, `command_line.load_context_completion`, `command_line.mcp_completion`, `command_line.pin_command_completion` (+101 more) | Leaves → Hubs |
| Integration (depth=5) | `agents.agent_code_puppy`, `agents.agent_code_reviewer`, `agents.agent_code_scout`, `agents.agent_creator_agent`, `agents.agent_golang_reviewer` (+105 more) | Leaves → Hubs |
| Integration (depth=6) | `agents.pack`, `capability`, `command_line.mcp.custom_server_installer`, `plugins.auto_test_control.register_callbacks`, `plugins.claude_code_oauth` (+46 more) | Leaves → Hubs |
| Integration (depth=7) | `plugins.agent_memory`, `plugins.code_explorer`, `plugins.code_explorer.register_callbacks`, `plugins.git_auto_commit`, `plugins.git_auto_commit.cli` (+16 more) | Leaves → Hubs |
| Integration (depth=8) | `plugins.agent_skills.register_callbacks`, `plugins.turbo_executor.test_summarizer`, `command_line.mcp.install_menu`, `plugins.agent_memory.agent_run_end`, `plugins.agent_memory.commands` (+2 more) | Leaves → Hubs |
| Integration (depth=9) | `plugins.agent_memory.register_callbacks`, `plugins.chatgpt_oauth`, `command_line.mcp.install_command` | Leaves → Hubs |
| Integration (depth=10) | `command_line.mcp.handler` | Leaves → Hubs |
| Integration (depth=11) | `command_line.mcp` | Leaves → Hubs |
| Integration (depth=12) | `command_line.config_commands`, `command_line.core_commands`, `command_line.session_commands`, `command_line.command_handler` | Leaves → Hubs |
| Integration (depth=13) | `interactive_loop`, `tui.message_bridge`, `api.routers.commands`, `tui.app` | Leaves → Hubs |
| Integration (depth=14) | `tui.stream_renderer`, `api.routers`, `tui.launcher` | Leaves → Hubs |
| Integration (depth=15) | `app_runner`, `api.app` | Leaves → Hubs |
| Integration (depth=16) | `api`, `api.main`, `cli_runner` | Leaves → Hubs |
| Integration (depth=17) | `main` | Leaves → Hubs |
| Integration (depth=18) | `__main__` | Leaves → Hubs |

## Limitations

1. **Static analysis only**: Dynamic imports (importlib, __import__) not detected.
2. **Conditional imports**: Imports inside try/except or TYPE_CHECKING treated equally.
3. **Star imports**: `from x import *` dependencies may be incomplete.
4. **External dependencies**: Third-party package internals not analyzed.
5. **Runtime dependencies**: Plugin loading, config-driven imports not captured.

## Appendix: Modules by Depth

Full module data in [python_dependency_graph.json](python_dependency_graph.json).

### Depth 0 (146 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `config_paths` | 31 | 1 | 427 |
| `tui.base_screen` | 18 | 0 | 25 |
| `command_line.command_registry` | 14 | 0 | 150 |
| `tui.widgets.searchable_list` | 14 | 0 | 256 |
| `tui.widgets.split_panel` | 14 | 0 | 47 |
| `messaging.messages` | 10 | 0 | 584 |
| `command_line.pagination` | 9 | 0 | 42 |
| `command_line.utils` | 9 | 0 | 92 |
| `permission_decision` | 8 | 0 | 67 |
| `run_context` | 8 | 0 | 264 |
| `tools.subagent_context` | 8 | 0 | 158 |
| `plugins.agent_trace.schema` | 7 | 0 | 264 |
| `utils.thread_safe_cache` | 7 | 0 | 43 |
| `plugins.agent_skills.metadata` | 6 | 0 | 260 |
| `tools.ask_user_question.constants` | 6 | 0 | 73 |
| `api.security` | 5 | 0 | 282 |
| `config_package.env_helpers` | 5 | 0 | 153 |
| `mcp_.mcp_security` | 5 | 0 | 513 |
| `plugins.turbo_executor.models` | 5 | 0 | 151 |
| `utils.file_display` | 5 | 0 | 389 |

> ... 126 more at this depth

### Depth 1 (35 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `plugins.elixir_bridge` | 12 | 1 | 725 |
| `elixir_transport_helpers` | 7 | 1 | 263 |
| `plugins.universal_constructor` | 6 | 1 | 27 |
| `tools.ask_user_question.models` | 6 | 1 | 284 |
| `plugins.agent_memory.storage` | 5 | 1 | 387 |
| `plugins.agent_trace.reducer` | 4 | 1 | 420 |
| `plugins.git_auto_commit.context_guard` | 4 | 1 | 255 |
| `plugins.error_classifier.registry` | 3 | 1 | 166 |
| `plugins.hook_manager.config` | 3 | 1 | 292 |
| `plugins.turbo_executor.summarizer` | 3 | 1 | 407 |
| `capability.registry` | 2 | 1 | 372 |
| `config_package._resolvers` | 2 | 1 | 229 |
| `hook_engine.matcher` | 2 | 1 | 201 |
| `messaging.subagent_console` | 2 | 1 | 452 |
| `plugins.agent_trace.emitter` | 2 | 1 | 268 |
| `plugins.agent_trace.store` | 2 | 2 | 181 |
| `plugins.repo_compass.turbo_indexer_bridge` | 2 | 1 | 48 |
| `agents.agent_state` | 1 | 1 | 152 |
| `chatgpt_codex_client` | 1 | 1 | 406 |
| `compaction.history_offload` | 1 | 2 | 281 |

> ... 15 more at this depth

### Depth 2 (17 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `plugins.universal_constructor.registry` | 7 | 2 | 302 |
| `concurrency_limits` | 4 | 2 | 462 |
| `adaptive_rate_limiter` | 3 | 2 | 1,164 |
| `plugins.agent_skills.skill_catalog` | 3 | 1 | 253 |
| `plugins.agent_trace.analytics` | 3 | 2 | 530 |
| `plugins.agent_trace.cli_renderer` | 3 | 2 | 470 |
| `plugins.pack_parallelism.run_limiter` | 3 | 2 | 838 |
| `hook_engine.executor` | 1 | 2 | 299 |
| `message_transport` | 1 | 1 | 315 |
| `plugins.error_classifier.builtins` | 1 | 2 | 298 |
| `plugins.repo_compass.formatter` | 1 | 1 | 38 |
| `plugins.universal_constructor.sandbox` | 1 | 1 | 600 |
| `round_robin_model` | 1 | 2 | 165 |
| `tui.screens.hooks_screen` | 1 | 4 | 218 |
| `agent_pinning_transport` | 0 | 1 | 167 |
| `text_ops` | 0 | 1 | 198 |
| `utils.hashline` | 0 | 1 | 343 |

### Depth 3 (5 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `plugins.agent_trace.cli_analytics` | 2 | 2 | 408 |
| `command_line.skills_completion` | 1 | 1 | 158 |
| `hook_engine.engine` | 1 | 5 | 213 |
| `tui.screens.skills_install_screen` | 1 | 5 | 265 |
| `plugins.error_classifier` | 0 | 3 | 41 |

### Depth 4 (106 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `messaging` | 131 | 10 | 268 |
| `config` | 109 | 12 | 2,694 |
| `callbacks` | 72 | 5 | 1,228 |
| `code_puppy` | 31 | 2 | 93 |
| `tools.command_runner` | 27 | 8 | 1,812 |
| `agents` | 26 | 2 | 31 |
| `agents.base_agent` | 26 | 25 | 2,901 |
| `tools.common` | 25 | 9 | 1,315 |
| `agents.agent_manager` | 19 | 9 | 1,038 |
| `mcp_.managed_server` | 14 | 5 | 442 |
| `model_factory` | 14 | 13 | 1,143 |
| `config_package` | 12 | 4 | 63 |
| `command_line.model_picker_completion` | 10 | 6 | 423 |
| `async_utils` | 8 | 1 | 284 |
| `mcp_.manager` | 8 | 7 | 978 |
| `tools.browser.browser_manager` | 8 | 5 | 377 |
| `messaging.spinner` | 7 | 3 | 184 |
| `session_storage` | 7 | 7 | 876 |
| `error_logging` | 6 | 1 | 319 |
| `scheduler.config` | 6 | 1 | 130 |

> ... 86 more at this depth

### Depth 5 (110 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `command_line.mcp.base` | 15 | 1 | 32 |
| `command_line.mcp.utils` | 12 | 2 | 127 |
| `mcp_.server_registry_catalog` | 6 | 2 | 1,142 |
| `workflow_state` | 5 | 3 | 388 |
| `plugins.agent_memory.config` | 4 | 1 | 205 |
| `agent_model_pinning` | 3 | 3 | 190 |
| `command_line.onboarding_wizard` | 3 | 4 | 346 |
| `command_line.shell_passthrough` | 3 | 1 | 232 |
| `plugins.chatgpt_oauth.config` | 3 | 2 | 55 |
| `plugins.git_auto_commit.shell_bridge` | 3 | 1 | 241 |
| `api.routers.agents` | 2 | 1 | 36 |
| `api.routers.config` | 2 | 2 | 122 |
| `api.routers.sessions` | 2 | 4 | 406 |
| `command_line.colors_menu` | 2 | 3 | 534 |
| `command_line.diff_menu` | 2 | 4 | 864 |
| `command_line.mcp.custom_server_form` | 2 | 4 | 675 |
| `command_line.model_settings_menu` | 2 | 5 | 952 |
| `command_line.motd` | 2 | 3 | 93 |
| `config_presets` | 2 | 2 | 243 |
| `models_dev_parser` | 2 | 1 | 685 |

> ... 90 more at this depth

### Depth 6 (51 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `plugins.git_auto_commit.commit_flow` | 3 | 2 | 347 |
| `prompt_runner` | 3 | 8 | 154 |
| `repl_session` | 3 | 8 | 398 |
| `tui.widgets.completion_overlay` | 3 | 1 | 108 |
| `code_context` | 2 | 3 | 225 |
| `command_line.add_model_menu` | 2 | 6 | 1,155 |
| `command_line.mcp.list_command` | 2 | 4 | 93 |
| `command_line.mcp.wizard_utils` | 2 | 5 | 329 |
| `plugins.agent_memory.signal_safeguards` | 2 | 2 | 361 |
| `plugins.agent_skills.skills_install_menu` | 2 | 8 | 684 |
| `plugins.chatgpt_oauth.utils` | 2 | 2 | 724 |
| `plugins.claude_code_oauth.register_callbacks` | 2 | 13 | 472 |
| `plugins.turbo_executor` | 2 | 3 | 33 |
| `plugins.turbo_executor.orchestrator` | 2 | 5 | 471 |
| `api.websocket` | 1 | 4 | 341 |
| `command_line.agent_menu` | 1 | 7 | 611 |
| `command_line.mcp.edit_command` | 1 | 5 | 130 |
| `command_line.mcp.help_command` | 1 | 2 | 146 |
| `command_line.mcp.logs_command` | 1 | 4 | 230 |
| `command_line.mcp.remove_command` | 1 | 4 | 81 |

> ... 31 more at this depth

### Depth 7 (21 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `plugins.agent_memory.core` | 6 | 7 | 152 |
| `plugins.chatgpt_oauth.oauth_flow` | 4 | 5 | 313 |
| `plugins.agent_memory.messaging` | 3 | 4 | 128 |
| `command_line.mcp.catalog_server_installer` | 2 | 5 | 174 |
| `plugins.agent_memory.processing` | 2 | 5 | 383 |
| `plugins.turbo_executor.register_callbacks` | 2 | 7 | 397 |
| `agents.agent_turbo_executor` | 1 | 3 | 175 |
| `command_line.mcp.status_command` | 1 | 6 | 184 |
| `command_line.repl_commands` | 1 | 3 | 181 |
| `plugins.agent_skills.skills_menu` | 1 | 8 | 798 |
| `tui.screens.add_model_screen` | 1 | 5 | 387 |
| `plugins.agent_memory` | 0 | 6 | 100 |
| `plugins.code_explorer` | 0 | 1 | 31 |
| `plugins.code_explorer.register_callbacks` | 0 | 3 | 544 |
| `plugins.git_auto_commit` | 0 | 4 | 98 |
| `plugins.git_auto_commit.cli` | 0 | 3 | 181 |
| `plugins.git_auto_commit.register_callbacks` | 0 | 5 | 249 |
| `plugins.scheduler.register_callbacks` | 0 | 4 | 85 |
| `plugins.supervisor_review.register_callbacks` | 0 | 3 | 141 |
| `tui` | 0 | 4 | 12 |

> ... 1 more at this depth

### Depth 8 (7 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `command_line.mcp.install_menu` | 1 | 6 | 703 |
| `plugins.agent_memory.agent_run_end` | 1 | 4 | 84 |
| `plugins.agent_memory.commands` | 1 | 4 | 303 |
| `plugins.agent_memory.prompts` | 1 | 5 | 150 |
| `plugins.chatgpt_oauth.register_callbacks` | 1 | 8 | 198 |
| `plugins.agent_skills.register_callbacks` | 0 | 9 | 374 |
| `plugins.turbo_executor.test_summarizer` | 0 | 3 | 316 |

### Depth 9 (3 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `command_line.mcp.install_command` | 1 | 7 | 212 |
| `plugins.agent_memory.register_callbacks` | 0 | 5 | 54 |
| `plugins.chatgpt_oauth` | 0 | 2 | 6 |

### Depth 10 (1 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `command_line.mcp.handler` | 1 | 16 | 138 |

### Depth 11 (1 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `command_line.mcp` | 1 | 1 | 10 |

### Depth 12 (4 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `command_line.command_handler` | 6 | 17 | 314 |
| `command_line.config_commands` | 1 | 15 | 673 |
| `command_line.core_commands` | 1 | 21 | 787 |
| `command_line.session_commands` | 1 | 7 | 308 |

### Depth 13 (4 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `tui.app` | 3 | 29 | 867 |
| `api.routers.commands` | 2 | 6 | 382 |
| `interactive_loop` | 1 | 29 | 679 |
| `tui.message_bridge` | 1 | 3 | 374 |

### Depth 14 (3 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `api.routers` | 1 | 4 | 12 |
| `tui.launcher` | 1 | 2 | 41 |
| `tui.stream_renderer` | 0 | 3 | 336 |

### Depth 15 (2 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `api.app` | 2 | 9 | 174 |
| `app_runner` | 1 | 19 | 485 |

### Depth 16 (3 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `cli_runner` | 1 | 7 | 179 |
| `api` | 0 | 1 | 13 |
| `api.main` | 0 | 1 | 21 |

### Depth 17 (1 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `main` | 1 | 1 | 10 |

### Depth 18 (1 modules)

| Module | Fan-In | Fan-Out | LOC |
|--------|--------|---------|-----|
| `__main__` | 0 | 1 | 10 |
