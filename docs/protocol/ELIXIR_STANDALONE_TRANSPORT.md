# Elixir Standalone Transport

This document describes the standalone stdio JSON-RPC transport for Elixir file operations, which provides an alternative to the bridge mode (PythonWorker.Port) for simple use cases.

> **Note:** PythonWorker.Port is only available under explicit `PUP_RUNTIME=python` / `--bridge-mode`.
> The default native Burrito runtime does not use PythonWorker.

## Overview

The standalone transport allows Elixir file operations (`list_files`, `read_file`, `grep`, etc.) to be accessed via a simple stdio-based JSON-RPC protocol, without requiring the full Phoenix/Web application stack.

## Architecture

```
┌─────────────────┐         stdin/stdout          ┌──────────────────┐
│  Python Client  │ ◄───── newline JSON-RPC ───► │  Elixir Service  │
│                 │                                │  (StdioService)  │
└─────────────────┘                                └──────────────────┘
                                                           │
                                                           ▼
                                                  ┌──────────────────┐
                                                  │     FileOps      │
                                                  │   (pure Elixir)  │
                                                  └──────────────────┘
```

## Transport Modes Comparison

| Aspect | Bridge Mode | Standalone Mode |
|--------|-------------|-----------------|
| **Runtime** | Inside Phoenix OTP app | Independent process |
| **Communication** | Erlang Port (Port.open) | stdin/stdout pipes |
| **Framing** | Content-Length | Newline-delimited |
| **Supervision** | DynamicSupervisor | Manual/subprocess |
| **Dependencies** | Full stack (Phoenix, PubSub, Oban) | Minimal (FileOps only) |
| **Start Method** | Supervisor during app boot | CLI: `mix code_puppy.stdio_service` |
| **Use Case** | Production with events | Scripts, simple workflows |
| **Performance** | ~2-5ms overhead | ~5-10ms overhead |

## When to Use Each Mode

### Use Standalone Mode When:
- You need simple file operations without the full application stack
- You're writing standalone scripts or CLI tools
- You want minimal startup time and dependencies
- You need integration with non-Python languages (any language that can spawn processes)
- Testing and development scenarios

### Use Bridge Mode (PythonWorker.Port) When — **only under `PUP_RUNTIME=python`**:
- Running legacy Python bridge flows within the full CodePuppy application
- You need PubSub event distribution for real-time updates (bridge mode)
- You want Oban job processing and database persistence (bridge mode)
- You need full OTP supervision and fault tolerance (bridge mode)
- Production deployments with Web UI integration via legacy bridge

## Protocol Specification

### Transport Format

The standalone transport uses **newline-delimited JSON-RPC 2.0**:

```
{"jsonrpc":"2.0","id":1,"method":"file_list","params":{"directory":"."}}\n
```

### Request Format

```json
{
  "jsonrpc": "2.0",
  "id": <string|number|null>,
  "method": <string>,
  "params": <object>
}
```

### Response Format

Success:
```json
{
  "jsonrpc": "2.0",
  "id": <same as request>,
  "result": <any>
}
```

Error:
```json
{
  "jsonrpc": "2.0",
  "id": <same as request>,
  "error": {
    "code": <number>,
    "message": <string>,
    "data": <any>
  }
}
```

### Error Codes

| Code | Meaning | Description |
|------|---------|-------------|
| -32700 | Parse error | Invalid JSON was received |
| -32600 | Invalid Request | The JSON sent is not a valid Request object |
| -32601 | Method not found | The method does not exist |
| -32602 | Invalid params | Invalid method parameters |
| -32000 | Server error | Generic file operation error |

## Supported Methods

### Core File Operations

#### `file_list`
List files in a directory.

**Parameters:**
```json
{
  "directory": ".",          // Path to list
  "recursive": true,          // Whether to recurse
  "include_hidden": false,    // Include hidden files
  "ignore_patterns": [],      // Glob patterns to skip
  "max_files": 10000          // Maximum files to return
}
```

**Response:**
```json
{
  "files": [
    {
      "path": "lib/file.ex",
      "type": "file",
      "size": 1234,
      "modified": "2025-04-16T12:00:00Z"
    },
    {
      "path": "lib",
      "type": "directory",
      "size": 0,
      "modified": "2025-04-16T12:00:00Z"
    }
  ]
}
```

#### `file_read`
Read a single file's contents.

**Parameters:**
```json
{
  "path": "/path/to/file",    // Required: file path
  "start_line": 1,            // Optional: 1-based start
  "num_lines": 100            // Optional: max lines to read
}
```

**Response:**
```json
{
  "path": "/path/to/file",
  "content": "file contents...",
  "num_lines": 50,
  "size": 1234,
  "truncated": false,
  "error": null
}
```

#### `file_read_batch`
Read multiple files concurrently.

**Parameters:**
```json
{
  "paths": ["/path/1", "/path/2"],
  "start_line": 1,
  "num_lines": 100
}
```

**Response:**
```json
{
  "files": [
    {
      "path": "/path/1",
      "content": "...",
      "num_lines": 10,
      "size": 100,
      "truncated": false,
      "error": null
    },
    {
      "path": "/path/2",
      "content": null,
      "num_lines": 0,
      "size": 0,
      "truncated": false,
      "error": "File not found: /path/2"
    }
  ]
}
```

#### `grep_search`
Search for patterns in files using regex.

**Parameters:**
```json
{
  "pattern": "def ",          // Required: regex pattern
  "directory": ".",           // Directory to search
  "case_sensitive": true,     // Case sensitivity
  "max_matches": 1000,         // Maximum results
  "file_pattern": "*",         // File glob filter
  "context_lines": 0           // Context lines (not yet implemented)
}
```

**Response:**
```json
{
  "matches": [
    {
      "file": "lib/file.ex",
      "line_number": 1,
      "line_content": "defmodule MyApp do",
      "match_start": 0,
      "match_end": 3
    }
  ]
}
```

### Utility Methods

#### `ping`
Health check ping.

**Response:**
```json
{
  "pong": true,
  "timestamp": "2025-04-16T12:00:00Z"
}
```

#### `health_check`
Detailed health status.

**Response:**
```json
{
  "status": "healthy",
  "version": "0.1.0",
  "elixir_version": "1.17.0",
  "otp_version": "27",
  "timestamp": "2025-04-16T12:00:00Z"
}
```

## Usage Examples

### Command Line

Start the service interactively:
```bash
cd elixir/code_puppy_control
mix code_puppy.stdio_service
```

Send a request:
```
{"jsonrpc":"2.0","id":1,"method":"ping"}
```

Response:
```
{"jsonrpc":"2.0","id":1,"result":{"pong":true,"timestamp":"..."}}
```

Pipe mode:
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"file_list","params":{"directory":"."}}' | \
  mix code_puppy.stdio_service
```

### Python Client

```python
from code_puppy.elixir_transport import ElixirTransport

# Using context manager (recommended)
with ElixirTransport() as transport:
    # List files
    files = transport.list_files(".", recursive=True)
    for f in files:
        print(f"{f['path']} ({f['type']})")

    # Read a file
    result = transport.read_file("README.md")
    print(result["content"][:1000])

    # Search in files
    matches = transport.grep("TODO", "src/", case_sensitive=False)
    for m in matches:
        print(f"{m['file']}:{m['line_number']}: {m['line_content']}")

# Manual lifecycle management
transport = ElixirTransport()
transport.start()
try:
    files = transport.list_files(".")
finally:
    transport.stop()
```

### Module-Level Convenience Functions

```python
from code_puppy import elixir_transport_helpers as et

# Simple operations without managing transport lifecycle
files = et.list_files(".", recursive=True)
content = et.read_file("config.yaml")
matches = et.grep("api_key", ".")

# Cleanup when done
et.shutdown()
```

## Security

The standalone transport uses the same security validations as the bridge mode:

- **Sensitive paths blocked**: SSH keys, cloud credentials, system secrets
- **Path validation**: Null bytes rejected, paths normalized
- **No file writing**: Read-only operations only
- **No path traversal**: `..` components normalized

See `CodePuppyControl.FileOps.sensitive_path?/1` for the complete list of blocked paths.

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PUP_ELIXIR_PATH` | Path to elixir/mix executables | Auto-detected |
| `PUP_ELIXIR_SERVICE_CMD` | Override service command | `mix code_puppy.stdio_service` |
| `PUP_LOG_LEVEL` | Elixir service log level | `info` |

### Elixir Application Config

In `config/runtime.exs`:
```elixir
config :code_puppy_control, :stdio_service,
  log_level: :info,
  max_list_files: 10_000,
  max_grep_matches: 1_000
```

## Testing

### Run Elixir Tests

```bash
cd elixir/code_puppy_control
mix test test/code_puppy_control/transport/stdio_service_test.exs
```

### Run Python Integration Tests

```bash
# Run all integration tests
pytest tests/integration/test_elixir_stdio_transport.py -v

# Skip integration tests
pytest tests/ -v --ignore=tests/integration/

# Or use marker
pytest tests/integration/test_elixir_stdio_transport.py -v -m "not integration"
```

## Performance Considerations

### Startup Time
- Standalone: ~1-2 seconds (Elixir VM boot + FileOps load)
- Bridge mode: ~0ms (already running in supervised app)

### Per-Operation Latency
- Standalone: ~5-10ms (IPC via pipes)
- Bridge mode: ~2-5ms (Erlang Port)

### Throughput
- Standalone: ~100-200 ops/sec (limited by JSON serialization)
- Bridge mode: ~500+ ops/sec (with batching support)

For high-throughput scenarios, consider:
1. Using the bridge mode with batch operations
2. Caching results at the Python level
3. Implementing connection pooling (TODO)

## Implementation Notes

### Why Stdio Instead of Sockets?

We chose stdio for simplicity:
- **No port binding**: No network configuration required
- **Process isolation**: Clean separation between Python and Elixir
- **Universally supported**: Works on all platforms without special networking
- **Easy debugging**: Can test via `echo | mix run`

Future enhancements could add Unix socket or TCP options for lower latency.

### Why Newline-Delimited Instead of Content-Length?

The bridge mode uses Content-Length framing (LSP-style), but we chose newline-delimited for the standalone transport because:
- **Human-readable**: Easy to debug and test interactively
- **Line-buffered**: Works well with stdio pipes
- **Widely supported**: Standard format for many JSON-RPC implementations
- **Simpler**: No need to calculate content lengths

### Future Enhancements

- [ ] Unix socket transport for lower latency
- [ ] Connection pooling for concurrent operations
- [ ] Streaming responses for large files
- [ ] Binary protocol option for efficiency
- [ ] Escript distribution for easier deployment

## References

- `CodePuppyControl.Transport.StdioService` - Elixir service implementation
- `CodePuppyControl.FileOps` - File operation logic
- `CodePuppyControl.Protocol` - JSON-RPC encoding/decoding
- `code_puppy/elixir_transport.py` - Python client adapter
- ADR-001: Elixir-Python Worker Protocol (see docs/adr/)
