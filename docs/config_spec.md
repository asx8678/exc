# Config Spec: code_puppy/config/ (split package)

> **Scope:** Every `get_*` accessor and path constant in `code_puppy/config/` (split from
> monolithic `config.py`, 2698→9 sub-modules). Re-exports all names for backward compat.
> Migration-analysis reference for a future `CodePuppyControl.Config.Schema` Elixir impl.
> Appendix: raw keys from `get_default_config_keys()` with no dedicated getter (consumed by adjacent modules).

---

## 1. Full Inventory of `get_*` Symbols

### 1.1 Schema-Backed Config Accessors

These read a single key from the `[puppy]` section of `puppy.cfg` via
`get_value(key)` and convert to a typed return.

| Accessor | Config Key | Return Type | Default / Fallback | Env Override | Elixir Schema? | Notes |
|---|---|---|---|---|---|---|
| `get_puppy_name()` | `puppy_name` | `str` | `"Puppy"` | — | yes | Required key; prompted on first run |
| `get_owner_name()` | `owner_name` | `str` | `"Master"` | — | yes | Required key; prompted on first run |
| `get_yolo_mode` | `yolo_mode` | `bool` | `True` | — | yes | Factory-made (`_make_bool_getter`) |
| `get_auto_save_session` | `auto_save_session` | `bool` | `True` | — | yes | Set to `true` by `ensure_config_exists()` |
| `get_max_saved_sessions` | `max_saved_sessions` | `int` | `20` | — | yes | min 0 |
| `get_allow_recursion` | `allow_recursion` | `bool` | `True` | — | yes | |
| `get_enable_gitignore_filtering` | `enable_gitignore_filtering` | `bool` | `False` | — | yes | Higher-risk flag |
| `get_enable_streaming` | `enable_streaming` | `bool` | `True` | — | yes | Controls SSE streaming |
| `get_http2` | `http2` | `bool` | `False` | — | yes | |
| `get_mcp_disabled` | `disable_mcp` | `bool` | `False` | — | yes | Negated key name (`disable_`) |
| `get_grep_output_verbose` | `grep_output_verbose` | `bool` | `False` | — | yes | |
| `get_compaction_threshold` | `compaction_threshold` | `float` | `0.85` | — | yes | clamped [0.5, 0.95] |
| `get_compaction_strategy()` | `compaction_strategy` | `str` | `"summarization"` | — | yes | enum: `summarization`, `truncation` |
| `get_resume_message_count` | `resume_message_count` | `int` | `50` | — | yes | clamped [1, 100] |
| `get_message_limit(default=100)` | `message_limit` | `int` | **call-time param** (default `100`) | — | yes | See mismatches S5 |
| `get_safety_permission_level()` | `safety_permission_level` | `str` | `"medium"` | — | yes | enum: `none`, `low`, `medium`, `high`, `critical` |
| `get_protected_token_count()` | `protected_token_count` | `int` | `50000` | — | yes | min 1000, max 75% of model context |
| `get_puppy_token()` | `puppy_token` | `str | None` | `None` | — | yes | |
| `get_openai_reasoning_effort()` | `openai_reasoning_effort` | `str` | `"medium"` | — | yes | enum: `minimal`, `low`, `medium`, `high`, `xhigh` |
| `get_openai_reasoning_summary()` | `openai_reasoning_summary` | `str` | `"auto"` | — | yes | enum: `auto`, `concise`, `detailed` |
| `get_openai_verbosity()` | `openai_verbosity` | `str` | `"medium"` | — | yes | enum: `low`, `medium`, `high` |
| `get_temperature()` | `temperature` | `float | None` | `None` | — | yes | clamped [0.0, 2.0]; None = use model default |
| `get_default_agent()` | `default_agent` | `str` | `"code-puppy"` | — | yes | |
| `get_diff_context_lines` | `diff_context_lines` | `int` | `6` | — | yes | clamped [0, 50] |
| `get_diff_addition_color()` | `highlight_addition_color` | `str` | `"#0b1f0b"` | — | yes | Note: key differs from accessor name |
| `get_diff_deletion_color()` | `highlight_deletion_color` | `str` | `"#390e1a"` | — | yes | Note: key differs from accessor name |
| `get_subagent_verbose` | `subagent_verbose` | `bool` | `False` | — | yes | |
| `get_pack_agents_enabled` | `enable_pack_agents` | `bool` | `False` | — | yes | |
| `get_universal_constructor_enabled` | `enable_universal_constructor` | `bool` | `True` | — | yes | |
| `get_elixir_message_shadow_mode_enabled` | `enable_elixir_message_shadow_mode` | `bool` | `False` | — | yes | |
| `get_bus_request_timeout_seconds` | `bus_request_timeout_seconds` | `float` | `300.0` | — | yes | clamped [10.0, 3600.0] |
| `get_summarization_pretruncate_enabled` | `summarization_pretruncate_enabled` | `bool` | `True` | — | yes | |
| `get_summarization_arg_max_length` | `summarization_arg_max_length` | `int` | `500` | — | yes | clamped [100, 10000] |
| `get_summarization_return_max_length` | `summarization_return_max_length` | `int` | `5000` | — | yes | clamped [500, 100000] |
| `get_summarization_return_head_chars` | `summarization_return_head_chars` | `int` | `500` | — | yes | clamped [100, 5000] |
| `get_summarization_return_tail_chars` | `summarization_return_tail_chars` | `int` | `200` | — | yes | clamped [50, 2000] |
| `get_summarization_history_offload_enabled` | `summarization_history_offload_enabled` | `bool` | `False` | — | yes | Privacy: off by default |
| `get_suppress_thinking_messages` | `suppress_thinking_messages` | `bool` | `False` | — | yes | |
| `get_suppress_informational_messages()` | `suppress_informational_messages` | `bool` | `False` | — | yes | |
| `get_max_session_tokens` | `max_session_tokens` | `int` | `0` | — | yes | 0 = disabled |
| `get_max_run_tokens` | `max_run_tokens` | `int` | `0` | — | yes | 0 = disabled |

### 1.2 Dynamic / Pattern-Key Accessors

These access config keys constructed from runtime parameters rather than a
fixed key name.

| Accessor | Config Key Pattern | Return Type | Default / Fallback | Env Override | Elixir Schema? | Notes |
|---|---|---|---|---|---|---|
| `get_agent_pinned_model(agent)` | `agent_model_{agent}` | `str | None` | `None` (empty str after clear) | — | yes (dynamic map) | See mismatches S5 |
| `get_all_agent_pinned_models()` | `agent_model_*` | `dict[str,str]` | `{}` | — | yes | Scans all keys with prefix |
| `get_agents_pinned_to_model(model)` | (derived from above) | `list[str]` | `[]` | — | no | Purely derived |
| `get_model_setting(model, setting)` | `model_settings_{sanitized_model}_{setting}` | `float | None` | `None` | — | yes (dynamic map) | `.` -> `_` in model name |
| `get_all_model_settings(model)` | `model_settings_{sanitized_model}_*` | `dict[str, any]` | `{}` | — | yes | Scans prefix; parses int/float/bool |
| `get_effective_model_settings(model)` | (composed) | `dict[str, any]` | `{}` | — | no | Derived: per-model + global temp + supports filter |
| `get_effective_temperature(model)` | (composed) | `float | None` | `None` | — | no | Convenience wrapper |
| `get_effective_top_p(model)` | (composed) | `float | None` | `None` | — | no | Convenience wrapper |
| `get_effective_seed(model)` | (composed) | `int | None` | `None` | — | no | Convenience wrapper |
| `get_banner_color(name)` | `banner_color_{name}` | `str` | `DEFAULT_BANNER_COLORS[name]` or `"blue"` | — | yes (dynamic map) | 17 named banners |
| `get_all_banner_colors()` | `banner_color_*` | `dict[str,str]` | all defaults | — | no | Derived from `DEFAULT_BANNER_COLORS` |
| `get_api_key(key_name)` | `{key_name}` | `str` | `""` | — | yes (dynamic map) | Key name used directly |

### 1.3 Derived Helpers (Not Direct Schema Fields)

These compute values from multiple sources or have complex logic beyond a
single config key lookup.

| Accessor | Sources | Return Type | Default | Env Override | Elixir Schema? | Notes |
|---|---|---|---|---|---|---|
| `get_global_model_name()` | `runtime_state` -> `model` key -> `models.json` first -> `"gpt-5"` | `str` | `"gpt-5"` (code fallback) | — | yes | Session-cached; validates against models.json |
| `get_model_context_length(model)` | `models.json` `context_length` field | `int` | `128000` | — | no | Not a config key -- reads models.json |
| `get_use_dbos()` | `enable_dbos` key **+** `import dbos` availability | `bool` | `True` (if dbos installed) | — | yes | Dual-gated; see mismatches S5 |
| `get_adaptive_rendering_enabled()` | env `PUPPY_ADAPTIVE_RENDERING` -> key `adaptive_rendering_enabled` | `bool` | `True` | `PUPPY_ADAPTIVE_RENDERING` | yes | Env checked first via `env_bool` |
| `get_post_edit_validation_enabled()` | env `PUPPY_POST_EDIT_VALIDATION` -> key `enable_post_edit_validation` | `bool` | `True` | `PUPPY_POST_EDIT_VALIDATION` | yes | Env checked first via `env_bool` |
| `get_summarization_trigger_fraction()` | `summarization_trigger_fraction` | `float` | `0.85` | — | yes | Clamped [0.5, 0.95] |
| `get_summarization_keep_fraction()` | `summarization_keep_fraction` | `float` | `0.10` | — | yes | Clamped [0.05, 0.50] |
| `get_summarization_history_dir()` | `summarization_history_dir` -> `<home>/history` | `Path` | `<active_home>/history` | — | yes | Respects `PUP_EX_HOME` via `config_paths.home_dir()` |
| `get_enable_agent_memory()` | `enable_agent_memory` key | `bool` | `False` | — | yes | **DEPRECATED** -- use `memory_enabled` (see S5) |
| `get_memory_extraction_model()` | `memory_extraction_model` key | `str | None` | `None` | — | yes | |
| `get_frontend_emitter_enabled()` | `frontend_emitter_enabled` | `bool` | `True` | — | yes | |
| `get_frontend_emitter_max_recent_events()` | `frontend_emitter_max_recent_events` | `int` | `100` | — | yes | |
| `get_frontend_emitter_queue_size()` | `frontend_emitter_queue_size` | `int` | `100` | — | yes | |
| `get_ws_history_maxlen()` | `ws_history_maxlen` | `int` | `200` | — | yes | |
| `get_ws_history_ttl_seconds()` | `ws_history_ttl_seconds` | `int` | `3600` | `PUPPY_WS_HISTORY_TTL_SECONDS` (allowlisted but **not read**) | yes | See mismatches S5 |
| `get_memory_debounce_seconds` | `memory_debounce_seconds` | `int` | `30` | — | yes | clamped [1, 300] |
| `get_memory_max_facts` | `memory_max_facts` | `int` | `50` | — | yes | clamped [1, 1000] |
| `get_memory_token_budget` | `memory_token_budget` | `int` | `500` | — | yes | clamped [100, 2000] |

### 1.4 Path / Runtime Helpers (Not Schema Fields)

These are runtime state or filesystem operations, not config keys.

| Accessor / Constant | Source | Return Type | Notes | Elixir Schema? |
|---|---|---|---|---|
| `get_current_autosave_id()` | `runtime_state` | `str` | Runtime-only, not persisted | no |
| `get_current_autosave_session_name()` | `runtime_state` | `str` | Runtime-only | no |
| `get_user_agents_directory()` | `_path_agents_dir()` (auto-creates) | `str` | Side-effect: mkdir | no (path constant) |
| `get_project_agents_directory()` | `cwd()/.code_puppy/agents/` | `str | None` | No auto-create | no |
| `model_supports_setting(model, setting)` | `models.json` + heuristics | `bool` | Reads model config | no |
| `load_api_keys_to_environment()` | `.env` -> `puppy.cfg` -> `os.environ` | `None` | Side-effect: mutates env; see S7 | no |
| `get_value(key)` / `get_config_keys()` | configparser | various | Low-level accessors | no |

---

## 2. Category Breakdown

### Model Settings
| Key | Type | Default | Notes |
|---|---|---|---|
| `model` | `str` | first entry in models.json | Global model name; session-cached |
| `temperature` | `float | None` | `None` | Global temp override; per-model takes precedence |
| `openai_reasoning_effort` | `str` | `"medium"` | enum: minimal/low/medium/high/xhigh |
| `openai_reasoning_summary` | `str` | `"auto"` | enum: auto/concise/detailed |
| `openai_verbosity` | `str` | `"medium"` | enum: low/medium/high |
| `model_settings_{model}_{setting}` | `float` | - | Dynamic per-model settings |
| `http2` | `bool` | `False` | HTTP/2 for httpx clients |
| `enable_streaming` | `bool` | `True` | SSE streaming |

### Agent Pinning
| Key | Type | Default | Notes |
|---|---|---|---|
| `agent_model_{agent}` | `str` | - | Per-agent model override |
| `default_agent` | `str` | `"code-puppy"` | |

### Compaction / Summarization / Limits
| Key | Type | Default | Notes |
|---|---|---|---|
| `compaction_strategy` | `str` | `"summarization"` | summarization / truncation |
| `compaction_threshold` | `float` | `0.85` | [0.5, 0.95] |
| `protected_token_count` | `int` | `50000` | min 1000, max 75% context |
| `message_limit` | `int` | `100` (call-time default) | See S5 |
| `summarization_trigger_fraction` | `float` | `0.85` | [0.5, 0.95] |
| `summarization_keep_fraction` | `float` | `0.10` | [0.05, 0.50] |
| `summarization_pretruncate_enabled` | `bool` | `True` | |
| `summarization_arg_max_length` | `int` | `500` | [100, 10000] |
| `summarization_return_max_length` | `int` | `5000` | [500, 100000] |
| `summarization_return_head_chars` | `int` | `500` | [100, 5000] |
| `summarization_return_tail_chars` | `int` | `200` | [50, 2000] |
| `summarization_history_offload_enabled` | `bool` | `False` | Privacy default |
| `summarization_history_dir` | `str` | `<home>/history` | Respects PUP_EX_HOME |
| `max_session_tokens` | `int` | `0` | 0 = disabled |
| `max_run_tokens` | `int` | `0` | 0 = disabled |
| `resume_message_count` | `int` | `50` | [1, 100] |

### Display / TUI
| Key | Type | Default | Notes |
|---|---|---|---|
| `adaptive_rendering_enabled` | `bool` | `True` | Env: `PUPPY_ADAPTIVE_RENDERING` |
| `enable_post_edit_validation` | `bool` | `True` | Env: `PUPPY_POST_EDIT_VALIDATION` |
| `suppress_thinking_messages` | `bool` | `False` | |
| `suppress_informational_messages` | `bool` | `False` | |
| `diff_context_lines` | `int` | `6` | [0, 50] |
| `highlight_addition_color` | `str` | `"#0b1f0b"` | |
| `highlight_deletion_color` | `str` | `"#390e1a"` | |
| `banner_color_{name}` | `str` | per DEFAULT_BANNER_COLORS | 17 named banners |
| `grep_output_verbose` | `bool` | `False` | |

### Feature Flags
| Key | Type | Default | Notes |
|---|---|---|---|
| `yolo_mode` | `bool` | `True` | |
| `enable_dbos` | `bool` | `True` | Also gated on `import dbos` |
| `enable_pack_agents` | `bool` | `False` | |
| `enable_universal_constructor` | `bool` | `True` | |
| `enable_streaming` | `bool` | `True` | |
| `enable_elixir_message_shadow_mode` | `bool` | `False` | |
| `enable_gitignore_filtering` | `bool` | `False` | Higher-risk flag |
| `subagent_verbose` | `bool` | `False` | |
| `enable_agent_memory` | `bool` | `False` | **DEPRECATED** -- use `memory_enabled` |
| `memory_enabled` | `bool` | `False` | Canonical (consumed by plugin) |
| `disable_mcp` | `bool` | `False` | Negated name |

### Safety
| Key | Type | Default | Notes |
|---|---|---|---|
| `safety_permission_level` | `str` | `"medium"` | enum: none/low/medium/high/critical |
| `allow_recursion` | `bool` | `True` | |
| `enable_user_plugins` | `str or None` | unset (None) | No getter in config.py; consumer checks `is None`, not boolean truthiness |
| `allowed_user_plugins` | `str` | - | Comma-separated; no getter in config.py |

### Frontend / History Buffers
| Key | Type | Default | Notes |
|---|---|---|---|
| `frontend_emitter_enabled` | `bool` | `True` | |
| `frontend_emitter_max_recent_events` | `int` | `100` | |
| `frontend_emitter_queue_size` | `int` | `100` | |
| `ws_history_maxlen` | `int` | `200` | |
| `ws_history_ttl_seconds` | `int` | `3600` | Env allowlisted but not read by getter |

### Memory
| Key | Type | Default | Notes |
|---|---|---|---|
| `enable_agent_memory` | `bool` | `False` | **DEPRECATED** |
| `memory_enabled` | `bool` | `False` | Canonical (plugin-side) |
| `memory_debounce_seconds` | `int` | `30` | [1, 300] |
| `memory_max_facts` | `int` | `50` | [1, 1000] |
| `memory_token_budget` | `int` | `500` | [100, 2000] |
| `memory_extraction_model` | `str | None` | `None` | |

### Identity / Defaults
| Key | Type | Default | Notes |
|---|---|---|---|
| `puppy_name` | `str` | `"Puppy"` | Required; prompted on first run |
| `owner_name` | `str` | `"Master"` | Required; prompted on first run |
| `puppy_token` | `str | None` | `None` | |
| `default_agent` | `str` | `"code-puppy"` | |

### Secrets / API Keys
| Key Pattern | Type | Default | Notes |
|---|---|---|---|
| `OPENAI_API_KEY` | `str` | `""` | Loaded into env by load_api_keys_to_environment() |
| `ANTHROPIC_API_KEY` | `str` | `""` | |
| `GEMINI_API_KEY` | `str` | `""` | |
| `GOOGLE_API_KEY` | `str` | `""` | |
| `CEREBRAS_API_KEY` | `str` | `""` | |
| `SYN_API_KEY` | `str` | `""` | |
| `AZURE_OPENAI_API_KEY` | `str` | `""` | |
| `AZURE_OPENAI_ENDPOINT` | `str` | `""` | |
| `OPENROUTER_API_KEY` | `str` | `""` | |
| `ZAI_API_KEY` | `str` | `""` | |
| `GITHUB_TOKEN` | `str` | `""` | In allowlist, not in api_key_names |
| `FIREWORKS_API_KEY` | `str` | `""` | In allowlist, not in api_key_names |
| `GROQ_API_KEY` | `str` | `""` | In allowlist, not in api_key_names |
| `MISTRAL_API_KEY` | `str` | `""` | In allowlist, not in api_key_names |
| `MOONSHOT_API_KEY` | `str` | `""` | In allowlist, not in api_key_names |

---

## 3. Paths and File Constants

All path constants are lazily resolved via `__getattr__` (PEP 562) using
`_LAZY_PATH_FACTORIES`. Internal code uses `_xdg_*()` / `_path_*()` helpers
that respect Elixir-home isolation (ADR-003). `pup_ex` is a Mix task namespace, not a standalone `pup-ex` executable.

### Resolution Priority

```
1. Module-level override (test monkeypatch, e.g. config.CONFIG_DIR = "/tmp")
2. XDG env var set? -> <XDG value>/code_puppy  (subject to ADR-003 pup-ex guard)
3. XDG env var unset? -> home_dir() directly
   a. PUP_EX_HOME (Elixir home / `pup_ex` task context) -> $PUP_EX_HOME or ~/.code_puppy_ex/
   b. PUP_HOME / PUPPY_HOME (standard mode) -> value or ~/.code_puppy/
```

> **Important:** When the relevant XDG env var is **unset**, `_get_xdg_dir()`
> returns `config_paths.home_dir()` directly -- not `<home>/config` or any
> subdirectory. This means that in the common no-XDG case, all four base
> directories (`CONFIG_DIR`, `DATA_DIR`, `CACHE_DIR`, `STATE_DIR`) collapse
> to the same active home directory. File constants (`CONFIG_FILE`, `MODELS_FILE`,
> etc.) are then derived as subpaths under that shared base.

> **Legacy note:** This flat-home fallback is a legacy bias in `config.py`.
> The newer Elixir `CodePuppyControl.Config.Paths` module organises paths
> into proper XDG-style subdirectories (`config/`, `data/`, `cache/`, `state/`)
> even when XDG env vars are unset. Migration should adopt the Elixir
> behaviour rather than replicating the Python flat-home quirk.

### Constant Table

| Constant | Base Dir | Subpath | XDG Env Var | Notes |
|---|---|---|---|---|
| `CONFIG_DIR` | `_xdg_config_dir()` | - | `XDG_CONFIG_HOME` | XDG set: `<XDG>/code_puppy`; else: `home_dir()` |
| `DATA_DIR` | `_xdg_data_dir()` | - | `XDG_DATA_HOME` | XDG set: `<XDG>/code_puppy`; else: `home_dir()` |
| `CACHE_DIR` | `_xdg_cache_dir()` | - | `XDG_CACHE_HOME` | XDG set: `<XDG>/code_puppy`; else: `home_dir()` |
| `STATE_DIR` | `_xdg_state_dir()` | - | `XDG_STATE_HOME` | XDG set: `<XDG>/code_puppy`; else: `home_dir()` |
| `CONFIG_FILE` | `_xdg_config_dir()` | `puppy.cfg` | - | Main config file |
| `MCP_SERVERS_FILE` | `_xdg_config_dir()` | `mcp_servers.json` | - | |
| `MODELS_FILE` | `_xdg_data_dir()` | `models.json` | - | Model registry |
| `EXTRA_MODELS_FILE` | `_xdg_data_dir()` | `extra_models.json` | - | User-added models |
| `AGENTS_DIR` | `_xdg_data_dir()` | `agents/` | - | Auto-created by `get_user_agents_directory()` |
| `SKILLS_DIR` | `_xdg_data_dir()` | `skills/` | - | |
| `CONTEXTS_DIR` | `_xdg_data_dir()` | `contexts/` | - | |
| `AUTOSAVE_DIR` | `_xdg_cache_dir()` | `autosaves/` | - | |
| `COMMAND_HISTORY_FILE` | `_xdg_state_dir()` | `command_history.txt` | - | |
| `CHATGPT_MODELS_FILE` | `_xdg_data_dir()` | `chatgpt_models.json` | - | |
| `CLAUDE_MODELS_FILE` | `_xdg_data_dir()` | `claude_models.json` | - | |
| `_DEFAULT_SQLITE_FILE` | `_xdg_data_dir()` | `dbos_store.sqlite` | - | |
| `DBOS_DATABASE_URL` | derived | - | `DBOS_SYSTEM_DATABASE_URL` | Falls back to `sqlite:///<_DEFAULT_SQLITE_FILE>` |

### ADR-003 Isolation Rule

When `PUP_EX_HOME` is set, any XDG-derived path that resolves **outside** the
active home tree is silently overridden to stay within it. This is enforced by
`_is_path_within_home()` in `config_paths.py`.

---

## 4. Elixir Schema Reference

The Elixir implementation lives in `CodePuppyControl.Config.*` sub-modules;
below is a field-spec reference for `[puppy]` section keys. For the runnable implementation, see:

- `CodePuppyControl.Config` (facade)
- `CodePuppyControl.Config.Paths` (XDG path resolution)
- `CodePuppyControl.Config.Isolation` (ADR-003 guard)
- `CodePuppyControl.Config.Loader` / `Writer` (INI I/O)
- `CodePuppyControl.Config.Models`, `Agents`, `Limits`, `Debug`, `TUI`, `Cache`

```text
Reference: CodePuppyControl.Config [puppy] section fields
All fields map to the [puppy] section of puppy.cfg.

--- Identity / Defaults ---
  puppy_name            string   default: "Puppy"
  owner_name            string   default: "Master"
  puppy_token           string   default: nil
  default_agent         string   default: "code-puppy"

--- Model Settings ---
  model                 string   default: nil          (resolved via models.json)
  temperature           float    default: nil          min: 0.0, max: 2.0
  openai_reasoning_effort
                        enum     default: "medium"
                                 values: [minimal, low, medium, high, xhigh]
  openai_reasoning_summary
                        enum     default: "auto"
                                 values: [auto, concise, detailed]
  openai_verbosity      enum     default: "medium"
                                 values: [low, medium, high]
  http2                 boolean  default: false
  enable_streaming      boolean  default: true

--- Per-Model Settings (dynamic keys) ---
  model_settings        map      default: %{}
    Key: {sanitized_model_name, setting_name} -> value
    Pattern: model_settings_{sanitized_model}_{setting}
    Sanitization: . - / in model name -> _ (lowercased)
    Example: %{("gpt_5", "temperature") => 0.7}

--- Agent Pinning (dynamic keys) ---
  agent_models          map      default: %{}
    Pattern: agent_model_{agent_name} -> model_name

--- Banner Colors (dynamic keys) ---
  banner_colors         map      default: %{}
    Pattern: banner_color_{name}
    Defaults from DEFAULT_BANNER_COLORS (17 entries):
      thinking -> "deep_sky_blue4"         agent_response -> "medium_purple4"
      shell_command -> "dark_orange3"       read_file -> "steel_blue"
      edit_file -> "dark_goldenrod"          create_file -> "dark_goldenrod"
      replace_in_file -> "dark_goldenrod"   delete_snippet -> "dark_goldenrod"
      grep -> "grey37"                      directory_listing -> "dodger_blue2"
      agent_reasoning -> "dark_violet"       invoke_agent -> "deep_pink4"
      subagent_response -> "sea_green3"     list_agents -> "dark_slate_gray3"
      universal_constructor -> "dark_cyan"  terminal_tool -> "dark_goldenrod"
      mcp_tool_call -> "dark_cyan"          shell_passthrough -> "medium_sea_green"

--- Diff Colors ---
  highlight_addition_color
                        string   default: "#0b1f0b"
  highlight_deletion_color
                        string   default: "#390e1a"

--- Compaction / Summarization / Limits ---
  compaction_strategy   enum     default: "summarization"
                                 values: [summarization, truncation]
  compaction_threshold  float    default: 0.85       min: 0.5, max: 0.95
  protected_token_count integer  default: 50000      min: 1000,
                                 max: :model_context_75pct
  message_limit         integer  default: 100
  summarization_trigger_fraction
                        float    default: 0.85       min: 0.5, max: 0.95
  summarization_keep_fraction
                        float    default: 0.10       min: 0.05, max: 0.50
  summarization_pretruncate_enabled
                        boolean  default: true
  summarization_arg_max_length
                        integer  default: 500        min: 100, max: 10000
  summarization_return_max_length
                        integer  default: 5000       min: 500, max: 100000
  summarization_return_head_chars
                        integer  default: 500        min: 100, max: 5000
  summarization_return_tail_chars
                        integer  default: 200        min: 50, max: 2000
  summarization_history_offload_enabled
                        boolean  default: false
  summarization_history_dir
                        string   default: nil        (nil -> <home>/history)
  max_session_tokens   integer  default: 0          (0 = disabled)
  max_run_tokens       integer  default: 0          (0 = disabled)
  resume_message_count  integer  default: 50         min: 1, max: 100

--- Display / TUI ---
  adaptive_rendering_enabled
                        boolean  default: true       env: PUPPY_ADAPTIVE_RENDERING
  enable_post_edit_validation
                        boolean  default: true       env: PUPPY_POST_EDIT_VALIDATION
  suppress_thinking_messages
                        boolean  default: false
  suppress_informational_messages
                        boolean  default: false
  diff_context_lines    integer  default: 6          min: 0, max: 50
  grep_output_verbose   boolean  default: false

--- Feature Flags ---
  yolo_mode             boolean  default: true
  enable_dbos           boolean  default: true       (also gated on dep presence)
  enable_pack_agents    boolean  default: false
  enable_universal_constructor
                        boolean  default: true
  enable_elixir_message_shadow_mode
                        boolean  default: false
  enable_gitignore_filtering
                        boolean  default: false
  subagent_verbose      boolean  default: false
  disable_mcp           boolean  default: false

--- Safety ---
  safety_permission_level
                        enum     default: "medium"
                                 values: [none, low, medium, high, critical]
  allow_recursion      boolean  default: true
  enable_user_plugins  boolean  default: false
  allowed_user_plugins  string  default: nil        (comma-separated list;
                                 only enforced when truthy)

--- Frontend / History Buffers ---
  frontend_emitter_enabled
                        boolean  default: true
  frontend_emitter_max_recent_events
                        integer  default: 100
  frontend_emitter_queue_size
                        integer  default: 100
  ws_history_maxlen     integer  default: 200
  ws_history_ttl_seconds
                        integer  default: 3600

--- Memory ---
  enable_agent_memory   boolean  default: false      DEPRECATED
  memory_enabled        boolean  default: false      (canonical key)
  memory_debounce_seconds
                        integer  default: 30         min: 1, max: 300
  memory_max_facts      integer  default: 50         min: 1, max: 1000
  memory_token_budget   integer  default: 500        min: 100, max: 2000
  memory_extraction_model
                        string   default: nil

--- Session / Autosave ---
  auto_save_session     boolean  default: true
  max_saved_sessions    integer  default: 20         min: 0

--- Misc ---
  bus_request_timeout_seconds
                        float    default: 300.0      min: 10.0, max: 3600.0
  cancel_agent_key      string   default: nil        (consumed by keymap.py)

--- API Keys (dynamic, stored in [puppy] section) ---
  NOT schema fields -- loaded via load_api_keys_to_environment/0.
  Allowlisted names:
    OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY,
    GOOGLE_API_KEY, CEREBRAS_API_KEY, SYN_API_KEY,
    AZURE_OPENAI_API_KEY, AZURE_OPENAI_ENDPOINT,
    OPENROUTER_API_KEY, ZAI_API_KEY, GITHUB_TOKEN,
    FIREWORKS_API_KEY, GROQ_API_KEY, MISTRAL_API_KEY,
    MOONSHOT_API_KEY

--- Computed / Derived (not in cfg) ---
  get_global_model_name/0:
    runtime_state -> cfg "model" -> models.json -> "gpt-5"
  get_model_context_length/1:
    models.json -> context_length (default 128000)
  get_use_dbos/0:
    enable_dbos AND import dbos succeeds
  get_effective_model_settings/1:
    per-model + global temp + supports filter
```

---

## 5. Notable Mismatches / Migration Risks

### 5.1 `get_global_model_name()` -- doc vs. code fallback

The docstring claims the last-resort fallback is `claude-4-0-sonnet`, but the
actual code path (`_default_model_from_models_json()`) falls back to `"gpt-5"`.
The session-cache layer in `runtime_state` adds another indirection. **Migration
must use `"gpt-5"` as the hardcoded fallback, not `"claude-4-0-sonnet"`.**

### 5.2 `get_use_dbos()` -- dual-gated

Returns `True` only when **both** `enable_dbos` is truthy (default `True`) in
config **and** `import dbos` succeeds. The Elixir side cannot replicate the
Python import check directly -- it needs an equivalent "is DBOS available?"
check or must treat DBOS as always-absent until explicitly wired.

### 5.3 `get_message_limit(default=100)` -- call-time default

Unlike other accessors, the default is a **function parameter** (`default=100`),
not a hardcoded constant in the config key. Callers can pass different
defaults: `get_message_limit(default=50)`. The schema field's semantic default
is therefore ambiguous. **Recommendation:** pin the default to `100` in the
Elixir schema and document that callers previously varied this parameter.

### 5.4 `get_agent_pinned_model()` -- empty string vs. None

After `clear_agent_pinned_model(agent)`, the key is set to `""` (empty string)
because `configparser` cannot easily delete keys. The getter returns whatever
`get_value()` returns, which is `""` -- not `None`. The docstring says "or None
if no model is pinned", but code returns empty string after clear. **Migration
should normalize empty strings to `nil`.**

### 5.5 `get_ws_history_ttl_seconds()` -- env var documented but not read

The docstring references env var `PUPPY_WS_HISTORY_TTL_SECONDS`, and it
appears in the `_CODEPUPPY_ENV_ALLOWLIST`, but the accessor itself only reads
`ws_history_ttl_seconds` from config. **The env var is currently a no-op for
this accessor.** Migration should either implement the env override or remove
the doc reference.

### 5.6 Extra raw keys with no dedicated getter

`get_default_config_keys()` lists `cancel_agent_key`, `enable_user_plugins`,
and `allowed_user_plugins`, but config.py has no `get_cancel_agent_key()`,
`get_enable_user_plugins()`, or `get_allowed_user_plugins()`. These are
consumed from adjacent modules (`keymap.py`, `plugins/__init__.py`).

### 5.7 `enable_agent_memory` deprecated in favor of `memory_enabled`

The config key `enable_agent_memory` is consumed by `get_enable_agent_memory()`
in config.py, but the canonical key is `memory_enabled` (used by
`code_puppy/plugins/agent_memory/config.py`). The plugin reads both with a
deprecation warning. **Migration should support both keys with a deprecation
path, canonicalizing to `memory_enabled`.**

### 5.8 Key-name asymmetries

- `get_diff_addition_color()` reads `highlight_addition_color` (not `diff_addition_color`)
- `get_diff_deletion_color()` reads `highlight_deletion_color` (not `diff_deletion_color`)
- `get_mcp_disabled` reads `disable_mcp` (negated key)
- `get_adaptive_rendering_enabled()` reads `adaptive_rendering_enabled` (matches), but env var is `PUPPY_ADAPTIVE_RENDERING` (no `enabled` suffix)
- `get_post_edit_validation_enabled()` reads `enable_post_edit_validation` (different prefix)

These naming inconsistencies should be reconciled in the Elixir schema.

### 5.9 `enable_user_plugins` -- presence-truthy, not boolean-truthy

Although `enable_user_plugins` is documented as a boolean-ish opt-in, the
current consumer in `code_puppy/plugins/__init__.py` only checks
`get_value("enable_user_plugins") is None`. This means:
- **unset / missing** => disabled (the intended default)
- **any present string value** (even `"false"`, `"0"`, `"no"`) => **enabled**

This is a stricter-than-boolean check inverted on its head: mere presence
is sufficient to enable, regardless of value. **Migration should normalize
this to a proper boolean field** in the Elixir schema, using the same
truthy semantics as `_is_truthy()` for consistency with other bool keys.

---

## 6. Appendix: Extra Raw Config Keys (No Getter in config.py)

These keys are declared in `get_default_config_keys()` or referenced by
adjacent modules but have **no** `get_*` accessor function in config.py itself.

| Key | Default | Consumer | Notes |
|---|---|---|---|
| `cancel_agent_key` | `"ctrl+c"` | `code_puppy/keymap.py` -> `get_cancel_agent_key()` | Validates against `VALID_CANCEL_KEYS`; allows overriding Ctrl+C interrupt key |
| `enable_user_plugins` | unset (None) | `code_puppy/plugins/__init__.py` -> `get_value("enable_user_plugins")` | **Presence-truthy, not boolean-truthy:** consumer checks `is None` only; unset => disabled; any present value (even `"false"`) => enabled. Migration should normalize to a proper boolean. |
| `allowed_user_plugins` | `""` (empty) | `code_puppy/plugins/__init__.py` -> `get_value("allowed_user_plugins")` | Comma-separated plugin names; empty/unset = **no allowlist restriction** (all user plugins load once `enable_user_plugins` is true); allowlist only enforced when truthy |

---

## 7. `load_api_keys_to_environment()` -- Load Order

This function is a side-effect that mutates `os.environ`. Its load order is:

1. **`.env` file** (CWD) -- only allowlisted keys (`_CODEPUPPY_ENV_ALLOWLIST`);
   existing env vars are **not** overwritten
2. **`puppy.cfg`** -- for `api_key_names` list (9 keys); only sets if not
   already in `os.environ`
3. **Existing `os.environ`** -- always preserved (highest actual priority)

The allowlist includes ~35 env vars (API keys, runtime config, feature toggles,
rendering settings, bridge settings). The `api_key_names` subset (9 keys) is
what gets loaded from `puppy.cfg` into the environment. The full allowlist is
what may be loaded from `.env`. **This asymmetry is intentional** -- puppy.cfg
only gets API keys, while .env may also carry feature toggles.
