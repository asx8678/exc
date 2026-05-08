# Session Logger Plugin

Structured agent run archives for debugging, replay, and QA review.

## What It Does

This plugin writes each agent run to a timestamped session directory with three files:

- `main_agent.log` — Human-readable conversation transcript with timestamps
- `tool_calls.jsonl` — Machine-readable tool invocations (newline-delimited JSON)
- `manifest.json` — Session metadata (start/end time, duration, success status)

## Configuration

Add to `~/.code_puppy/puppy.cfg`:

```ini
[puppy]
session_logger_enabled = true
```

**Note:** Disabled by default (opt-in) to respect user privacy.

Sessions are written to the canonical `sessions_dir` location (typically
`~/.code_puppy/sessions`). There is no separate `session_logger_dir` setting;
the plugin uses the standard sessions directory like all other session-aware
components.

## Dogfooding Mode (For Code Puppy Developers)

Want to capture your own agent runs while developing Code Puppy? The quickest way is via environment variable (no config file edit needed):

```bash
# Set before running code_puppy
export PUPPY_SESSION_LOGGER_ENABLED=true
code_puppy
```

Or copy `.env.example` to `.env` and uncomment:
```bash
PUPPY_SESSION_LOGGER_ENABLED=true
```

**What it captures:**
- Every agent run with timestamps
- All tool invocations with args/results
- Session manifest with success/failure status

**Output location:** `~/.code_puppy/sessions/YYYYmmDD_HHMMSS_session-<id>/`

Useful for:
- Debugging agent behavior during feature development
- QA validation of tool call sequences
- Creating replay scenarios from captured sessions

## Output Location

Sessions are written to timestamped subdirectories:
```
~/.code_puppy/sessions/
└── 20250409_120345_session-a1b2c3d4/
    ├── main_agent.log
    ├── tool_calls.jsonl
    └── manifest.json
```

## File Formats

### main_agent.log
Plain text with ISO-8601 timestamps:
```
[2025-04-09T12:03:45.123456+00:00] Agent 'turbo-executor' started with model 'claude-sonnet-4'
[2025-04-09T12:03:45.234567+00:00] Tool 'list_files' completed (12.5ms)
[2025-04-09T12:03:46.345678+00:00] Agent run completed successfully
```

### tool_calls.jsonl
One JSON object per line:
```json
{"timestamp": "2025-04-09T12:03:45.234567+00:00", "tool_name": "list_files", "args": {"directory": "."}, "result": [...], "duration_ms": 12.5, "error": null}
```

### manifest.json
```json
{
  "session_id": "session-a1b2c3d4",
  "agent_name": "turbo-executor",
  "model_name": "claude-sonnet-4",
  "started_at": "2025-04-09T12:03:45.123456+00:00",
  "ended_at": "2025-04-09T12:03:50.654321+00:00",
  "duration_seconds": 5.53,
  "success": true,
  "error": null,
  "tool_call_count": 3
}
```

## Disabling

Set `session_logger_enabled = false` (or remove the line) in `puppy.cfg` and restart. The plugin will unregister itself on next startup.

## Use Cases

- **Debugging:** Review tool call sequences and response patterns
- **QA:** Validate agent behavior with manifest success/failure tracking
- **Replay:** Reconstruct agent runs from tool_calls.jsonl
- **Audit:** Long-term archive of all agent interactions
