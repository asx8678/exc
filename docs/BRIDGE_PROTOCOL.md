# Python↔Elixir Bridge Protocol Specification

Version: 1.0.0
Last Updated: 2026-04-14

## Overview

The Code Puppy bridge enables communication between the Python runtime and the Elixir control plane using JSON-RPC 2.0 over stdio with Content-Length framing.

## Wire Format

### Framing

Messages use HTTP-style Content-Length framing:

```
Content-Length: <byte-length>\r\n
\r\n
<json-body>
```

### JSON-RPC 2.0

All messages follow JSON-RPC 2.0 specification:

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "unique-id",
  "method": "method_name",
  "params": {}
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": "unique-id",
  "result": {}
}
```

**Notification (no response expected):**
```json
{
  "jsonrpc": "2.0",
  "method": "method_name",
  "params": {}
}
```

## Methods (Elixir → Python)

| Method | Description | Params |
|--------|-------------|--------|
| `invoke_agent` | Start an agent run | `{agent_name, prompt, session_id?, run_id?}` |
| `run_shell` | Execute shell command | `{command, cwd?, timeout?}` |
| `file_list` | List directory contents | `{directory, recursive?}` |
| `file_read` | Read file contents | `{path, start_line?, num_lines?}` |
| `file_write` | Write file contents | `{path, content}` |
| `grep_search` | Search in files | `{pattern, directory}` |
| `get_status` | Get bridge status | `{}` |
| `ping` | Health check | `{}` |

## Events (Python → Elixir)

Python emits all events using a generic `event` method:

```json
{
  "jsonrpc": "2.0",
  "method": "event",
  "params": {
    "event_type": "<type>",
    "run_id": "<run-id>",
    "session_id": "<session-id>",
    "timestamp": "<iso-8601>",
    "payload": {}
  }
}
```

### Event Types

| event_type | Description | Payload |
|------------|-------------|---------|
| `bridge_ready` | Bridge initialized | `{}` |
| `bridge_closing` | Bridge shutting down | `{}` |
| `run_started` | Agent run started | `{agent_name}` |
| `agent_response` | Text from agent | `{text, finished}` |
| `tool_call` | Tool invocation | `{tool_name, tool_args}` |
| `tool_result` | Tool completed | `{tool_name, result}` |
| `status_update` | Status change | `{status}` |
| `run_completed` | Run finished successfully | `{result}` |
| `run_failed` | Run failed | `{error}` |

## Error Codes

| Code | Meaning |
|------|---------|
| -32700 | Parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32000 to -32099 | Server errors |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CODE_PUPPY_BRIDGE` | Enable bridge mode | `0` |
| `CODE_PUPPY_BRIDGE_PROTOCOL` | Framing protocol | `content-length` |
| `CODE_PUPPY_BRIDGE_LOG` | Log file path | None |

## Version History

- **1.0.0** (2026-04-14): Initial specification after protocol alignment
