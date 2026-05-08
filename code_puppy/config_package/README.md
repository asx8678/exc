# Config Package (Typed Settings Layer)

This package provides a **typed, dataclass-based configuration layer** for code_puppy.
It is **additive** — it coexists with the existing `config.py` dict-based API,
providing a modern alternative without breaking existing code.

## Quick Start

```python
# Load typed config (singleton)
from code_puppy.config_package import get_puppy_config
cfg = get_puppy_config()

# Access typed fields
print(cfg.default_model)          # "claude-opus-4-6"
print(cfg.data_dir)               # Path("/home/user/.code_puppy")
print(cfg.max_concurrent_runs)    # 2
print(cfg.allow_parallel_runs)    # True

# Reload after config edits
cfg = reload_puppy_config()

# Convert to dict for legacy consumers
config_dict = cfg.to_dict()
```

## Architecture

### Additive Design

- **Old API**: `from code_puppy.config import get_value, DATA_DIR` (dict-based)
- **New API**: `from code_puppy.config_package import get_puppy_config` (typed)
- **Both work** — migrate gradually at your own pace

### Sources (Priority Order)

1. **Environment variables** (highest priority)
   - `PUPPY_DEFAULT_MODEL`, `CODE_PUPPY_DATA_DIR`, etc.
   - Full list: see `loader.py` or run `get_puppy_config().to_dict()`

2. **puppy.cfg file** (via legacy config module)
   - Settings in `[puppy]` section: `model`, `data_dir`, etc.

3. **Hardcoded defaults** (lowest priority)
   - Defaults are in `loader.py` (single source of truth)

## PuppyConfig Fields

| Field | Type | Default | Env Var(s) |
|-------|------|---------|------------|
| `data_dir` | `Path` | `~/.code_puppy` | `PUPPY_DATA_DIR`, `CODE_PUPPY_DATA_DIR` |
| `config_dir` | `Path` | `~/.code_puppy` | `PUPPY_CONFIG_DIR`, `CODE_PUPPY_CONFIG_DIR` |
| `config_file` | `Path` | `~/.code_puppy/puppy.cfg` | — |
| `sessions_dir` | `Path` | `DATA_DIR/sessions` | `PUPPY_SESSIONS_DIR` |
| `default_agent` | `str` | `"code-puppy"` | `PUPPY_DEFAULT_AGENT` |
| `default_model` | `str` | `"claude-opus-4-6"` | `PUPPY_DEFAULT_MODEL` |
| `max_concurrent_runs` | `int` | `2` | `PUPPY_MAX_CONCURRENT_RUNS` |
| `allow_parallel_runs` | `bool` | `True` | `PUPPY_ALLOW_PARALLEL_RUNS` |
| `run_wait_timeout` | `float \| None` | `None` | `PUPPY_RUN_WAIT_TIMEOUT` |
| `ws_history_maxlen` | `int` | `200` | `PUPPY_WS_HISTORY_MAXLEN` |
| `session_logger_enabled` | `bool` | `False` | `PUPPY_SESSION_LOGGER` |
| `enable_dbos` | `bool` | `True` | `PUPPY_ENABLE_DBOS` |
| `temperature` | `float` | `0.0` | `PUPPY_TEMPERATURE` |
| `debug` | `bool` | `False` | `PUPPY_DEBUG`, `CODE_PUPPY_DEBUG` |
| `log_level` | `str` | `"INFO"` | `PUPPY_LOG_LEVEL` |
| `puppy_name` | `str` | `"Puppy"` | `PUPPY_NAME` |
| `owner_name` | `str` | `"Master"` | `PUPPY_OWNER_NAME` |

(For complete list, see `models.py`)

## Environment Variable Patterns

### Standard Pattern
Most settings use `PUPPY_*` env vars:
```bash
export PUPPY_DEFAULT_MODEL=gpt-4
export PUPPY_DEBUG=true
```

### Legacy Fallback
For backward compatibility, some settings also check `CODE_PUPPY_*`:
```bash
export CODE_PUPPY_DATA_DIR=/custom/path  # Fallback if PUPPY_DATA_DIR unset
```

## Migration Guide

### From Old Dict API

Old way:
```python
from code_puppy.config import get_value, DATA_DIR
model = get_value("model") or "claude-opus-4-6"
path = DATA_DIR
```

New way:
```python
from code_puppy.config_package import get_puppy_config
cfg = get_puppy_config()
model = cfg.default_model  # Already typed as str
path = cfg.data_dir        # Already typed as Path
```

### When to Migrate

- **New code**: Use the typed API
- **Refactoring**: Consider migrating when touching config code
- **Critical paths**: Only migrate if you need type safety or better defaults handling

## Testing

Use the test helper for isolation:

```python
import pytest
from code_puppy.config_package import (
    get_puppy_config,
    reset_puppy_config_for_tests,
)

@pytest.fixture(autouse=True)
def reset_config():
    reset_puppy_config_for_tests()
    yield
    reset_puppy_config_for_tests()

def test_with_env_override(monkeypatch):
    monkeypatch.setenv("PUPPY_DEFAULT_MODEL", "gpt-test")
    cfg = get_puppy_config()  # Fresh load
    assert cfg.default_model == "gpt-test"
```

## Adding New Fields

Three places to update:

1. **`models.py`**: Add the field to `PuppyConfig` dataclass
   ```python
   new_feature: bool
   ```

2. **`loader.py`**: Add the loading logic in `load_puppy_config()`
   ```python
   new_feature=_get_bool(
       ("PUPPY_NEW_FEATURE",),
       "new_feature",
       False,
   ),
   ```

3. **`README.md`**: Document the field in the table

## Resilience Guarantees

The loader is designed to **never crash the app**:
- If `code_puppy.config` import fails → uses hardcoded defaults
- If `puppy.cfg` doesn't exist → uses hardcoded defaults
- If env var parsing fails → falls back to default
- All exceptions are caught; config loading always succeeds

## File Structure

```
config_package/
├── __init__.py       # Public API exports
├── README.md         # This documentation
├── env_helpers.py    # Typed env var helpers
├── models.py         # PuppyConfig dataclass
└── loader.py         # Loading logic + singleton cache
```

## Relationship to `config.py`

- `config.py`: Original 1773-line dict-based API (unchanged, supported)
- `config_package/`: New typed layer (additive, optional)

Both use the same `puppy.cfg` file. Both respect the same env vars.
Pick whichever API fits your code better.
