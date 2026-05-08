# ADR-001: Elixir ↔ Python Worker Communication Protocol

## Status

**ACCEPTED** (2026-04-14)

## Context

The Elixir migration requires defining how Elixir control plane communicates with Python agent workers.


- Bidirectional asyncio.Queue (Agent→UI, UI→Agent)
- Correlation IDs via `prompt_id → asyncio.Future`
- Pydantic models that are naturally JSON-serializable
- Event types: text, shell_line, tool_result, status changes

## Decision

**Adopt JSON-RPC 2.0 over stdio with Content-Length framing.**

Python workers run as Elixir Ports (subprocesses). Communication uses:

- **stdout**: Protocol messages only (JSON-RPC)
- **stderr**: Diagnostics/logs only
- **Content-Length framing**: Robust multiline payload handling

### Protocol Methods

#### Elixir → Python (Requests)
| Method | Purpose |
|--------|---------|
| `worker.ping` | Health check |
| `run.start` | Start agent run |
| `run.cancel` | Soft cancel request |
| `run.provide_response` | Deliver user response to prompt |
| `worker.shutdown` | Graceful shutdown |

#### Python → Elixir (Notifications)
| Method | Purpose |
|--------|---------|
| `run.status` | Status transition |
| `run.event` | Streaming event (text, shell, tool) |
| `run.prompt_request` | Request user input |
| `run.completed` | Run finished successfully |
| `run.failed` | Run finished with error |

### Correlation Model

**Two layers of IDs:**

1. **Transport-level**: JSON-RPC `id` for request/response correlation
2. **Domain-level**:
   - `run_id`: Execution lifecycle
   - `session_id`: Event routing/PubSub
   - `prompt_id`: User interaction correlation
   - `event_id`: (optional) Dedupe/replay

### Message Envelope

```json
{
  "jsonrpc": "2.0",
  "method": "run.event",
  "params": {
    "event_type": "text",
    "run_id": "run-abc123",
    "session_id": "session-xyz",
    "timestamp": "2026-04-14T10:30:00Z",
    "sequence": 42,
    "payload": {"content": "Hello, world!"}
  }
}
```

### Cancellation Semantics

1. **Soft cancel**: Elixir sends `run.cancel`, Python cooperatively cancels
2. **Hard kill**: If no acknowledgment within timeout, Elixir kills Port

### Authority Split

| Elixir Owns | Python Owns |
|-------------|-------------|
| Run registration | Execution logic |
| Authoritative status | In-process awaitables |
| Request tracking | Model/tool interaction |
| Event routing | Cooperative cancellation |
| Supervision/restarts | Temporary local state |

## Alternatives Considered

### Option B: Protocol Buffers over stdio
- **Rejected for now**: Schema discipline adds complexity before protocol stabilizes
- **Future path**: Revisit if JSON becomes bottleneck

### Option C: gRPC bidirectional streaming
- **Rejected**: Over-engineered for local subprocess architecture
- **Future path**: Only if workers become remote services

### Option D: Erlang External Term Format (erlport)
- **Rejected**: Poor fit with Pydantic/JSON patterns, reduced transparency

## Consequences

### Positive
- Fastest path to working bridge
- Best debugging during migration (readable wire traffic)
- Strong fit with existing Python Pydantic models
- Natural OTP alignment (Ports, monitors, supervisors)
- Clear ownership model

### Negative
- Schema discipline by convention, not generated IDL
- Framing must be careful (Content-Length required)
- May need optimization for high-frequency streams later

## Elixir Modules Required

| Module | Type | Purpose |
|--------|------|---------|
| `PythonWorkerPort` | GenServer | Owns Port, sends/receives JSON-RPC |
| `RunRegistry` | Registry | run_id → worker pid |
| `RunState` | GenServer/ETS | Authoritative run status |
| `RequestTracker` | GenServer | prompt_id correlation |
| `PythonWorkerSupervisor` | DynamicSupervisor | Manages worker processes |

## Testing Requirements

- [ ] Worker emits `run.status`, Elixir stores it
- [ ] Prompt request/response preserves `prompt_id`
- [ ] Cancel causes soft cancel path
- [ ] Unresponsive worker triggers hard kill
- [ ] Worker crash → authoritative Elixir failure state
- [ ] Event streaming reaches PubSub in order
- [ ] Unknown `prompt_id` safely handled

## Revisit Criteria

Revisit this ADR if:
1. Workers must run remotely across machines → consider gRPC
2. JSON throughput becomes bottleneck → consider Protobuf
3. Protocol stabilizes → consider IDL generation
