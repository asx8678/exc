# Code Puppy Bridge Protocol V1

**Status:** ACCEPTED  
**Version:** 1.0.0  
**Last Updated:** 2026-04-14  
**Supersedes:** All prior protocol drafts, `docs/BRIDGE_PROTOCOL.md`

---

## 1. Overview

The Code Puppy Bridge Protocol enables bidirectional communication between the **Python agent runtime** and the **Elixir control plane** using JSON-RPC 2.0 over stdio with Content-Length framing.

### 1.1 Design Principles

- **Explicit over implicit**: Specific method names instead of generic `event`
- **Request/Response for commands**: Elixir commands Python via JSON-RPC requests
- **Notifications for streaming**: Python streams events to Elixir via JSON-RPC notifications
- **Clear ownership**: Elixir owns run lifecycle; Python owns execution logic

### 1.2 Transport

- **stdout**: Protocol messages only (JSON-RPC)
- **stderr**: Diagnostics, logs, and debugging output
- **Framing**: HTTP-style Content-Length framing (mandatory)

---

## 2. Wire Format

### 2.1 Content-Length Framing (Mandatory)

All messages use HTTP-style Content-Length framing. The newline-delimited fallback has been **removed**.

```
Content-Length: <byte-length>\r\n
\r\n
<json-body>
```

**Example:**
```
Content-Length: 156\r\n
\r\n
{"jsonrpc":"2.0","method":"run.status","params":{"run_id":"run-123","status":"running"}}
```

### 2.2 JSON-RPC 2.0 Structure

All messages follow the JSON-RPC 2.0 specification.

#### 2.2.1 Request (Elixir → Python)

```json
{
  "jsonrpc": "2.0",
  "id": "<request-id>",
  "method": "<dot.style.method>",
  "params": {
    "run_id": "<run-id>",
    ...
  }
}
```

#### 2.2.2 Response (Python → Elixir)

**Success:**
```json
{
  "jsonrpc": "2.0",
  "id": "<request-id>",
  "result": {
    "status": "ok",
    ...
  }
}
```

**Error:**
```json
{
  "jsonrpc": "2.0",
  "id": "<request-id>",
  "error": {
    "code": <error-code>,
    "message": "<error-message>",
    "data": { ... }
  }
}
```

#### 2.2.3 Notification (Python → Elixir)

Notifications have no `id` field and require no response:

```json
{
  "jsonrpc": "2.0",
  "method": "<dot.style.method>",
  "params": {
    "run_id": "<run-id>",
    ...
  }
}
```

---

## 3. Method Reference

### 3.1 Elixir → Python (Requests)

| Method | Direction | Description | Response |
|--------|-----------|-------------|----------|
| `run.start` | Elixir → Python | Start a new agent run | `result` or `error` |
| `run.cancel` | Elixir → Python | Cancel an active run | `result` or `error` |
| `initialize` | Elixir → Python | Initialize the Python worker | `result` or `error` |
| `exit` | Elixir → Python | Shutdown the Python worker | `result` or `error` |
| `invoke_agent` | Elixir → Python | Direct agent invocation | `result` or `error` |
| `run_shell` | Elixir → Python | Execute shell command | `result` or `error` |
| `file_list` | Elixir → Python | List directory contents | `result` or `error` |
| `file_read` | Elixir → Python | Read file contents | `result` or `error` |
| `file_write` | Elixir → Python | Write file contents | `result` or `error` |
| `grep_search` | Elixir → Python | Search in files | `result` or `error` |
| `get_status` | Elixir → Python | Get bridge status | `result` or `error` |
| `ping` | Elixir → Python | Health check | `result` or `error` |

### 3.2 Python → Elixir (Notifications)

| Method | Direction | Description |
|--------|-----------|-------------|
| `run.status` | Python → Elixir | Status update during run |
| `run.event` | Python → Elixir | Generic event during run |
| `run.completed` | Python → Elixir | Run finished successfully |
| `run.failed` | Python → Elixir | Run failed with error |
| `run.text` | Python → Elixir | Text output from agent |
| `run.tool_result` | Python → Elixir | Tool execution result |
| `run.prompt` | Python → Elixir | Prompt request for user input |
| `bridge.ready` | Python → Elixir | Bridge initialized and ready |
| `bridge.closing` | Python → Elixir | Bridge shutting down |

---

## 4. Method Schemas

### 4.1 Elixir → Python Methods

#### 4.1.1 `run.start`

Start a new agent run.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "method": "run.start",
  "params": {
    "agent_name": "turbo-executor",
    "prompt": "Analyze the codebase",
    "session_id": "sess-abc123",
    "run_id": "run-def456",
    "context": { }
  }
}
```

**Success Response:**
```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "result": {
    "status": "started",
    "run_id": "run-def456",
    "session_id": "sess-abc123"
  }
}
```

**Error Response:**
```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "error": {
    "code": -32602,
    "message": "Invalid params: missing agent_name"
  }
}
```

#### 4.1.2 `run.cancel`

Cancel an active run.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "req-002",
  "method": "run.cancel",
  "params": {
    "run_id": "run-def456"
  }
}
```

**Success Response:**
```json
{
  "jsonrpc": "2.0",
  "id": "req-002",
  "result": {
    "status": "cancelled",
    "run_id": "run-def456"
  }
}
```

#### 4.1.3 `initialize`

Initialize the Python worker.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "req-003",
  "method": "initialize",
  "params": {
    "capabilities": ["shell", "file_ops", "agents"],
    "config": { }
  }
}
```

#### 4.1.4 `exit`

Shutdown the Python worker gracefully.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "req-004",
  "method": "exit",
  "params": {
    "reason": "shutdown",
    "timeout_ms": 5000
  }
}
```

### 4.2 Python → Elixir Notifications

#### 4.2.1 `run.status`

Status update during run.

```json
{
  "jsonrpc": "2.0",
  "method": "run.status",
  "params": {
    "run_id": "run-def456",
    "session_id": "sess-abc123",
    "status": "running",
    "timestamp": "2026-04-14T10:30:00Z"
  }
}
```

**Status Values:** `initializing`, `running`, `paused`, `cancelling`, `completed`, `failed`

#### 4.2.2 `run.event`

Generic event during run.

```json
{
  "jsonrpc": "2.0",
  "method": "run.event",
  "params": {
    "run_id": "run-def456",
    "session_id": "sess-abc123",
    "event_type": "tool_call",
    "timestamp": "2026-04-14T10:30:01Z",
    "data": {
      "tool_name": "file_read",
      "tool_args": { "path": "README.md" }
    }
  }
}
```

#### 4.2.3 `run.completed`

Run finished successfully.

```json
{
  "jsonrpc": "2.0",
  "method": "run.completed",
  "params": {
    "run_id": "run-def456",
    "session_id": "sess-abc123",
    "timestamp": "2026-04-14T10:35:00Z",
    "result": {
      "output": "...",
      "metrics": { }
    }
  }
}
```

#### 4.2.4 `run.failed`

Run failed with error.

```json
{
  "jsonrpc": "2.0",
  "method": "run.failed",
  "params": {
    "run_id": "run-def456",
    "session_id": "sess-abc123",
    "timestamp": "2026-04-14T10:35:00Z",
    "error": {
      "code": -32000,
      "message": "Agent execution failed",
      "details": { }
    }
  }
}
```

#### 4.2.5 `run.text`

Text output from agent.

```json
{
  "jsonrpc": "2.0",
  "method": "run.text",
  "params": {
    "run_id": "run-def456",
    "session_id": "sess-abc123",
    "timestamp": "2026-04-14T10:30:02Z",
    "text": "I'll analyze the codebase for you.",
    "finished": false
  }
}
```

#### 4.2.6 `run.tool_result`

Tool execution result.

```json
{
  "jsonrpc": "2.0",
  "method": "run.tool_result",
  "params": {
    "run_id": "run-def456",
    "session_id": "sess-abc123",
    "timestamp": "2026-04-14T10:30:03Z",
    "tool_call_id": "call-xyz789",
    "tool_name": "file_read",
    "result": {
      "success": true,
      "content": "..."
    }
  }
}
```

#### 4.2.7 `run.prompt`

Prompt request for user input.

```json
{
  "jsonrpc": "2.0",
  "method": "run.prompt",
  "params": {
    "run_id": "run-def456",
    "session_id": "sess-abc123",
    "prompt_id": "prompt-001",
    "timestamp": "2026-04-14T10:30:04Z",
    "question": "What file should I analyze?",
    "options": ["src/", "tests/", "docs/"]
  }
}
```

#### 4.2.8 `bridge.ready`

Bridge initialized and ready.

```json
{
  "jsonrpc": "2.0",
  "method": "bridge.ready",
  "params": {
    "timestamp": "2026-04-14T10:00:00Z",
    "capabilities": ["shell", "file_ops", "agents"],
    "version": "1.0.0"
  }
}
```

#### 4.2.9 `bridge.closing`

Bridge shutting down.

```json
{
  "jsonrpc": "2.0",
  "method": "bridge.closing",
  "params": {
    "timestamp": "2026-04-14T11:00:00Z",
    "reason": "shutdown"
  }
}
```

---

## 5. Error Codes

| Code | Name | Meaning |
|------|------|---------|
| -32700 | Parse error | Invalid JSON |
| -32600 | Invalid request | Malformed request object |
| -32601 | Method not found | Unknown method name |
| -32602 | Invalid params | Invalid method parameters |
| -32603 | Internal error | Internal JSON-RPC error |
| -32000 | Server error | Generic server error |
| -32001 | Run not found | Specified run_id does not exist |
| -32002 | Run already active | Cannot start, run is already running |
| -32003 | Cancellation failed | Failed to cancel the run |
| -32004 | Bridge not initialized | Bridge has not been initialized |

---

## 6. Correlation Model

### 6.1 ID Types

1. **`request_id`**: JSON-RPC `id` field for request/response correlation
2. **`run_id`**: Execution lifecycle identifier
3. **`session_id`**: Event routing and PubSub identifier
4. **`prompt_id`**: User interaction correlation
5. **`tool_call_id`**: Tool invocation correlation

### 6.2 ID Format

All IDs are strings with the following prefixes:
- Requests: `req-` + nanoid (12 chars)
- Runs: `run-` + nanoid (12 chars)
- Sessions: `sess-` + nanoid (12 chars)
- Prompts: `prompt-` + nanoid (12 chars)
- Tool calls: `call-` + nanoid (12 chars)

### 6.3 Example Flow

```
1. Elixir:  {"id":"req-001","method":"run.start","params":{"run_id":"run-abc"}}
2. Python:  {"id":"req-001","result":{"status":"started"}}
3. Python:  {"method":"run.status","params":{"run_id":"run-abc","status":"running"}}
4. Python:  {"method":"run.text","params":{"run_id":"run-abc","text":"Hello"}}
5. Python:  {"method":"run.completed","params":{"run_id":"run-abc"}}
```

---

## 7. Deprecation Notes

### 7.1 Deprecated Method Names

The following method names are **DEPRECATED** and will be removed in V2:

| Deprecated | Replacement | Status |
|------------|-------------|--------|
| `run/start` (slash style) | `run.start` (dot style) | Deprecated |
| `run/cancel` (slash style) | `run.cancel` (dot style) | Deprecated |
| `event` (generic) | `run.status`, `run.text`, `run.tool_result`, `run.event`, `run.completed`, `run.failed` | Replaced |

**Migration:** Update all method names to use dot-style notation.

### 7.2 Deprecated Environment Variables

| Deprecated | Status | Replacement |
|------------|--------|-------------|
| `CODE_PUPPY_BRIDGE_PROTOCOL=newline` | **REMOVED** | Use `content-length` only |

The newline-delimited framing fallback has been completely removed. All implementations must use Content-Length framing.

### 7.3 Deprecated Event Structure

The generic `event` method with nested `payload` structure has been replaced by specific methods with flat params:

**OLD (Deprecated):**
```json
{
  "method": "event",
  "params": {
    "event_type": "tool_output",
    "payload": { "tool_name": "shell", "output": "..." }
  }
}
```

**NEW (Standard):**
```json
{
  "method": "run.tool_result",
  "params": {
    "tool_name": "shell",
    "result": { "output": "..." }
  }
}
```

---

## 8. Migration Guide

### 8.1 Python Migration

#### Step 1: Update Method Handlers

Add handlers for the new Elixir → Python methods:

```python
class BridgeProtocol:
    async def handle_run_start(self, params):
        # Handle run.start
        pass

    async def handle_run_cancel(self, params):
        # Handle run.cancel
        pass

    async def handle_initialize(self, params):
        # Handle initialize
        pass

    async def handle_exit(self, params):
        # Handle exit
        pass
```

#### Step 2: Replace Generic Event Emission

Replace the generic `event` emission with specific methods:

```python
# OLD (Deprecated)
async def _on_stream_event(self, event_type, run_id, session_id, payload):
    await self.send_notification("event", {
        "event_type": event_type,
        "run_id": run_id,
        "session_id": session_id,
        "timestamp": time.time(),
        "payload": payload
    })

# NEW (Standard)
async def emit_run_status(self, run_id, session_id, status):
    await self.send_notification("run.status", {
        "run_id": run_id,
        "session_id": session_id,
        "status": status,
        "timestamp": time.time()
    })

async def emit_run_text(self, run_id, session_id, text, finished=False):
    await self.send_notification("run.text", {
        "run_id": run_id,
        "session_id": session_id,
        "text": text,
        "finished": finished,
        "timestamp": time.time()
    })

async def emit_run_tool_result(self, run_id, session_id, tool_call_id, tool_name, result):
    await self.send_notification("run.tool_result", {
        "run_id": run_id,
        "session_id": session_id,
        "tool_call_id": tool_call_id,
        "tool_name": tool_name,
        "result": result,
        "timestamp": time.time()
    })
```

#### Step 3: Remove Deprecated Framing Support

Remove the newline-delimited framing fallback:

```python
# OLD (Deprecated)
if os.environ.get("CODE_PUPPY_BRIDGE_PROTOCOL") == "newline":
    # Use newline framing
    pass

# NEW (Standard)
# Always use Content-Length framing
```

#### Step 4: Update Event Mappings

Map internal event types to the new method names:

| Internal Event | Old Method | New Method |
|----------------|------------|------------|
| `status_change` | `event` | `run.status` |
| `agent_response` | `event` | `run.text` |
| `tool_output` | `event` | `run.tool_result` |
| `run_complete` | `event` | `run.completed` |
| `error` | `event` | `run.failed` |
| `tool_call` | `event` | `run.event` |
| `prompt_request` | `event` | `run.prompt` |

### 8.2 Elixir Migration

#### Step 1: Update Method Names

Replace slash-style with dot-style method names:

```elixir
# OLD (Deprecated)
GenServer.call(worker, {:send_request, "run/start", params})
GenServer.call(worker, {:send_request, "run/cancel", params})

# NEW (Standard)
GenServer.call(worker, {:send_request, "run.start", params})
GenServer.call(worker, {:send_request, "run.cancel", params})
```

#### Step 2: Handle Specific Events

Ensure all specific event methods are handled:

```elixir
# In port.ex handle_message

defp handle_message(%{"method" => "run.status"} = message, state) do
  # Handle status update
  broadcast_event(message["params"]["session_id"], :status, message["params"])
  {:noreply, state}
end

defp handle_message(%{"method" => "run.text"} = message, state) do
  # Handle text output
  broadcast_event(message["params"]["session_id"], :text, message["params"])
  {:noreply, state}
end

defp handle_message(%{"method" => "run.tool_result"} = message, state) do
  # Handle tool result
  broadcast_event(message["params"]["session_id"], :tool_result, message["params"])
  {:noreply, state}
end

defp handle_message(%{"method" => "run.completed"} = message, state) do
  # Handle run completion
  complete_run(message["params"]["run_id"], :completed, message["params"])
  {:noreply, state}
end

defp handle_message(%{"method" => "run.failed"} = message, state) do
  # Handle run failure
  complete_run(message["params"]["run_id"], :failed, message["params"])
  {:noreply, state}
end

defp handle_message(%{"method" => "bridge.ready"} = message, state) do
  # Handle bridge ready
  {:noreply, %{state | ready: true}}
end

defp handle_message(%{"method" => "bridge.closing"} = message, state) do
  # Handle bridge closing
  {:stop, :normal, state}
end
```

#### Step 3: Remove Generic Event Handler

Remove or deprecate the generic `event` handler:

```elixir
# OLD (Deprecated)
defp handle_message(%{"method" => "event"} = message, state) do
  # Generic handler - no longer needed
  {:noreply, state}
end

# NEW (Standard) - Remove this handler
```

#### Step 4: Update Test Mocks

Update test mocks to match the actual protocol:

```python
# In mock_python_worker_script.py

# OLD (Deprecated)
send_notification("event", {
    "event_type": "status_change",
    "run_id": run_id,
    "payload": {"status": "running"}
})

# NEW (Standard)
send_notification("run.status", {
    "run_id": run_id,
    "status": "running"
})
```

---

## 9. Implementation Checklist

### 9.1 Python Side

- [ ] Add `run.start` method handler
- [ ] Add `run.cancel` method handler
- [ ] Add `initialize` method handler
- [ ] Add `exit` method handler
- [ ] Implement `run.status` notification emission
- [ ] Implement `run.event` notification emission
- [ ] Implement `run.completed` notification emission
- [ ] Implement `run.failed` notification emission
- [ ] Implement `run.text` notification emission
- [ ] Implement `run.tool_result` notification emission
- [ ] Implement `run.prompt` notification emission
- [ ] Implement `bridge.ready` notification emission
- [ ] Implement `bridge.closing` notification emission
- [ ] Remove generic `event` method emission
- [ ] Remove newline-delimited framing support
- [ ] Remove `CODE_PUPPY_BRIDGE_PROTOCOL` environment variable support

### 9.2 Elixir Side

- [ ] Update method names to dot-style (`run.start`, `run.cancel`)
- [ ] Add handler for `run.status` notification
- [ ] Add handler for `run.event` notification
- [ ] Add handler for `run.completed` notification
- [ ] Add handler for `run.failed` notification
- [ ] Add handler for `run.text` notification
- [ ] Add handler for `run.tool_result` notification
- [ ] Add handler for `run.prompt` notification
- [ ] Add handler for `bridge.ready` notification
- [ ] Add handler for `bridge.closing` notification
- [ ] Remove or deprecate generic `event` handler
- [ ] Update test mocks to use correct method names

### 9.3 Testing

- [ ] End-to-end test: Start run, receive status updates
- [ ] End-to-end test: Cancel run
- [ ] End-to-end test: Tool execution with results
- [ ] End-to-end test: Text streaming
- [ ] End-to-end test: Run completion
- [ ] End-to-end test: Run failure handling
- [ ] End-to-end test: Bridge lifecycle (ready/closing)

---

## 10. Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-04-14 | Initial canonical specification. Standardizes on dot-style method names, removes newline framing fallback, replaces generic `event` with specific methods. |

---

## 11. References

- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
- [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) (inspiration for Content-Length framing)
- `docs/adr/ADR-001-elixir-python-worker-protocol.md` - Original ADR

---

**Authors:** Code Puppy Team  
**Reviewers:** Planning Agent, Bridge Implementation Team  
**Status:** ACCEPTED
