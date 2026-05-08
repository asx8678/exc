# ADR-002: Python → Elixir Event Protocol

## Status

**ACCEPTED** (2026-04-14)

## Context

The Python↔Elixir bridge protocol had significant drift. The core issue was:

- Python emitted events as generic `"event"` method with `event_type` in `params`
- Elixir expected specific method names like `"run.status"`, `"run.completed"`, etc.
- This created a 100% mismatch where NO events flowed from Python to Elixir

This ADR documents the **actual working protocol** after resolution, where Elixir was adapted to accept Python's generic event format.

## Decision

**Adopt Python's generic event format with `event_type` discrimination.**

Instead of changing Python to emit Elixir-specific method names, Elixir was updated to handle Python's generic `"event"` method and route based on `params.event_type`.

### Protocol Format

Python sends:

```json
{
  "jsonrpc": "2.0",
  "method": "event",
  "params": {
    "event_type": "tool_result",
    "run_id": "run-abc123",
    "session_id": "session-xyz789",
    "timestamp": 1713123456789,
    "payload": {
      "tool_name": "shell",
      "result": {"output": "..."}
    }
  }
}
```

Elixir receives and maps `event_type` to internal handlers at `port.ex:298`:

| Python `event_type` | Elixir Handler | Purpose |
|---------------------|----------------|---------|
| `agent_response` | `handle_agent_response_event` | Text streaming from agents |
| `tool_call` | `handle_tool_call_event` | Tool invocation notification |
| `tool_result` | `handle_tool_result_event` | Tool output delivery |
| `run_started` | `handle_run_started_event` | Run lifecycle start |
| `run_completed` | `handle_run_completed_event` | Run lifecycle success |
| `run_failed` | `handle_run_failed_event` | Run lifecycle failure |
| `status_update` | `handle_status_event` | Status changes |
| `bridge_ready` | Direct handler | Bridge initialization |
| `bridge_closing` | Direct handler | Bridge shutdown |

### Implementation Reference

**Elixir Handler** (`port.ex:298`):
```elixir
# Generic "event" handler that maps Python's format to internal event types
defp handle_message(%{"method" => "event", "params" => params}, run_id) do
  event_type = params["event_type"]
  session_id = params["session_id"]
  payload = params["payload"] || %{}

  case event_type do
    "agent_response" -> handle_agent_response_event(run_id, session_id, payload)
    "tool_call" -> handle_tool_call_event(run_id, session_id, payload)
    "tool_result" -> handle_tool_result_event(run_id, session_id, payload)
    "run_started" -> handle_run_started_event(run_id, session_id, payload)
    "run_completed" -> handle_run_completed_event(run_id, session_id, payload)
    "run_failed" -> handle_run_failed_event(run_id, session_id, payload)
    "status_update" -> handle_status_event(run_id, session_id, payload)
    "bridge_ready" -> Logger.info("Python bridge ready for run #{run_id}")
    "bridge_closing" -> Logger.info("Python bridge closing for run #{run_id}")
    unknown -> Logger.debug("Unknown event type from Python: #{unknown}")
  end
end
```

**Also Supported** (`port.ex:340`):
Elixir also handles structured `run.event` method for backward compatibility:
```elixir
defp handle_message(%{"method" => "run.event", "params" => params}, run_id) do
  # Structured run event - store and broadcast via EventBus
  ...
end
```

## Event Types Specification

### `agent_response`
Emitted when an agent produces text output.

```json
{
  "event_type": "agent_response",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "content": "Here's the code...",
    "delta": true
  }
}
```

### `tool_call`
Emitted when a tool is invoked.

```json
{
  "event_type": "tool_call",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "tool_name": "grep_search",
    "tool_call_id": "call-123",
    "arguments": {"search_string": "TODO"}
  }
}
```

### `tool_result`
Emitted when a tool completes.

```json
{
  "event_type": "tool_result",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "tool_name": "grep_search",
    "tool_call_id": "call-123",
    "result": {...},
    "is_error": false
  }
}
```

### `run_started`
Emitted when a run begins.

```json
{
  "event_type": "run_started",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "agent_name": "turbo-executor",
    "start_time": "2026-04-14T10:30:00Z"
  }
}
```

### `run_completed`
Emitted when a run finishes successfully.

```json
{
  "event_type": "run_completed",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "result": "success",
    "duration_ms": 4500
  }
}
```

### `run_failed`
Emitted when a run fails.

```json
{
  "event_type": "run_failed",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "error": "Rate limit exceeded",
    "error_code": "rate_limit"
  }
}
```

### `status_update`
Emitted for status changes.

```json
{
  "event_type": "status_update",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "status": "thinking",
    "message": "Processing request..."
  }
}
```

### `bridge_ready`
Emitted when the bridge initializes.

```json
{
  "event_type": "bridge_ready",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "version": "1.0.0",
    "capabilities": ["stdio", "jsonrpc"]
  }
}
```

### `bridge_closing`
Emitted before the bridge shuts down.

```json
{
  "event_type": "bridge_closing",
  "run_id": "run-abc123",
  "session_id": "session-xyz",
  "payload": {
    "reason": "shutdown",
    "graceful": true
  }
}
```

## Key Design Decisions

### 1. Event Type Discrimination
Python's generic `event` method with `event_type` field is more flexible than method-per-type. It allows:
- Adding new event types without protocol changes
- Easier client implementations
- Cleaner routing logic

### 2. Nested Payload Structure
Data is nested in `params.payload` rather than flat in `params`. This:
- Keeps metadata (run_id, session_id, timestamp) separate from content
- Allows payload schema to evolve independently
- Matches Python's internal event model

### 3. Dual Handler Support
Elixir supports both:
- Generic `"event"` method (Python format, preferred)
- Specific `"run.event"` method (backward compatibility)

## Consequences

### Positive
- ✅ Full event flow from Python to Elixir now works
- ✅ Minimal changes required in Python
- ✅ Python's flexible event model preserved
- ✅ Clear separation between metadata and payload
- ✅ Easy to add new event types

### Negative
- ❌ Slightly more complex routing in Elixir (vs direct method matching)
- ❌ Payload is nested (requires extraction)
- ❌ Elixir → Python lifecycle methods still missing (future work)

## Related Issues

- **Elixir migration epic** (all CLOSED)

## References

| File | Line | Description |
|------|------|-------------|
| `port.ex` | 298 | Generic event handler |
| `port.ex` | 340 | `run.event` handler |
| `port.ex` | 505 | `handle_agent_response_event` |
| `port.ex` | 523 | `handle_tool_call_event` |
| `port.ex` | 539 | `handle_tool_result_event` |
| `port.ex` | 555 | `handle_run_started_event` |
| `port.ex` | 570 | `handle_run_completed_event` |
| `port.ex` | 585 | `handle_run_failed_event` |
| `port.ex` | 600 | `handle_status_event` |

## Future Work

### Still Missing (Elixir → Python)
Python still needs handlers for:
- `run/start` - Start a run from Elixir
- `run/cancel` - Cancel a run from Elixir
- `exit` - Shutdown Python worker from Elixir
- `initialize` - Protocol handshake from Elixir

These were not required for the migration epic and remain future work.

## Testing

Tests are in `elixir/code_puppy_control/test/python_worker/port_protocol_test.exs`:

```elixir
test "handles generic event method with agent_response event_type", %{pid: pid} do
  message = %{
    "jsonrpc" => "2.0",
    "method" => "event",
    "params" => %{
      "event_type" => "agent_response",
      "run_id" => "test-run",
      "session_id" => "test-session",
      "payload" => %{"content" => "Hello", "delta" => true}
    }
  }

  assert {:ok, _} = PythonWorkerPort.handle_message(pid, message, "test-run")
end
```

---

**Decision Date**: 2026-04-14  
**Decision Maker**: Elixir Migration Team  
**Status**: Implemented and validated
