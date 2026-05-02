# Event Schema Analysis for Elixir Wire Protocol

> **Status**: Draft  
> **Purpose**: Document gaps between current message schema and Elixir wire protocol requirements  
> **Date**: 2026-04-14

## Elixir Wire Protocol Requirements

Per `docs/architecture/python-singleton-audit.md`, the Elixir wire protocol requires events with:

| Field | Type | Purpose | Status |
|-------|------|---------|--------|
| `event_type` | string | Message classification for routing | ⚠️ PARTIAL (`category` exists) |
| `run_id` | string | Run/execution identifier | ❌ MISSING |
| `session_id` | string | Session grouping | ✅ EXISTS |
| `timestamp` | int | Unix timestamp (ms) | ⚠️ PARTIAL (datetime object) |
| `payload` | object | Event data | ⚠️ PARTIAL (whole message IS payload) |

## Current State (messages.py)

### BaseMessage Structure
```python
class BaseMessage(BaseModel):
    id: str                          # ✅ Unique message ID
    timestamp: datetime            # ⚠️ Datetime, not Unix timestamp
    category: MessageCategory      # ⚠️ Not named "event_type"
    session_id: str | None         # ✅ Session grouping
```

### Gaps Identified

#### 1. Missing `run_id` Field
**Impact**: HIGH - Needed for Elixir GenServer run tracking  
**Current**: No run-level identifier exists  
**Required**: Add `run_id` to BaseMessage for correlating messages to specific execution runs

#### 2. Timestamp Format
**Impact**: MEDIUM - Elixir expects Unix timestamp  
**Current**: `datetime` object in UTC  
**Required**: Either add `timestamp_unix_ms` or convert in serialization

#### 3. Event Type Naming
**Impact**: LOW - Cosmetic/convention  
**Current**: `category` field with `MessageCategory` enum  
**Required**: May need `event_type` alias for wire protocol compatibility

#### 4. Payload Structure
**Impact**: MEDIUM - Serialization format  
**Current**: Whole message is serialized as JSON object  
**Required**: Elixir protocol expects `{"event_type": "...", "payload": {...}}` wrapper

## Migration Path

### Phase 1: Add Missing Fields
Add to `BaseMessage`:
- `run_id: str | None` - Run identifier for execution tracking
- `timestamp_unix_ms: int` - Unix timestamp for Elixir compatibility

### Phase 2: Wire Protocol Serialization
Create wire format converter:
```python
def to_wire_protocol(message: BaseMessage) -> dict:
    return {
        "event_type": message.category.value,
        "run_id": message.run_id,
        "session_id": message.session_id,
        "timestamp": message.timestamp_unix_ms,
        "payload": message.model_dump(exclude={"run_id", "session_id", "timestamp"})
    }
```

### Phase 3: Backward Compatibility
- Keep existing fields for internal use
- Add new fields as optional with defaults
- Use migration period before removing old format

## Elixir Mapping

```elixir
# Expected incoming format from Python
%{
  "event_type" => "tool_output",
  "run_id" => "run-abc123",
  "session_id" => "session-xyz789",
  "timestamp" => 1713123456789,
  "payload" => %{
    # Event-specific data
  }
}

# Elixir struct representation
defmodule CodePuppyControl.Events.WireEvent do
  @enforce_keys [:event_type, :run_id, :timestamp, :payload]
  defstruct [
    :event_type,
    :run_id,
    :session_id,
    :timestamp,
    :payload
  ]
end
```

## Action Items

| Priority | Task | Issue |
|----------|------|-------|
| P0 | Add `run_id` field to BaseMessage | — |
| P1 | Add `timestamp_unix_ms` field | — |
| P1 | Create wire protocol serializer | — |
| P2 | Implement event_type alias | — |
| P2 | Test Elixir interop | — |

## Schema Compatibility Notes

### Current → Wire Protocol (One Way)
```python
# Current internal format
text_msg = TextMessage(
    id="msg-1",
    category=MessageCategory.SYSTEM,
    session_id="session-1",
    timestamp=datetime.now(UTC),
    level=MessageLevel.INFO,
    text="Hello"
)

# Wire protocol format
{
    "event_type": "system",
    "run_id": None,  # Would be populated in practice
    "session_id": "session-1",
    "timestamp": 1713123456789,
    "payload": {
        "id": "msg-1",
        "level": "info",
        "text": "Hello"
    }
}
```

### Breaking Changes
None for Phase 1 - all additions are optional fields.

### Performance Considerations
- Unix timestamp calculation: negligible overhead
- run_id generation: UUID4 or short hash
- Wire serialization: ~10-20% larger JSON due to wrapper structure
