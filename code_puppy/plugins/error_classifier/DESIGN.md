## Implementation Status

### ✅ Completed (Phase 1)

**Files Implemented:**
- `exinfo.py` - ExInfo dataclass and ErrorSeverity enum
- `registry.py` - ExceptionRegistry with class-based and pattern-based lookup
- `builtins.py` - 15+ built-in exception registrations
- `register_callbacks.py` - agent_exception and agent_run_end hooks
- `__init__.py` - Public API exports

**Features Working:**
- Class-based exception registration and lookup
- MRO-based parent class resolution
- Pattern-based fallback for string-matching
- Retry classification (True/False)
- Severity-based user messaging (emit_error/warning/info)
- Retry delay recommendations
- Built-in coverage for network, auth, filesystem, and value errors
- Callback support in ExInfo

**Tests:**
- 30 comprehensive unit tests covering all functionality
- Tests for ExInfo, ExceptionRegistry, builtins, and custom patterns

### 📋 Still To Do (Future Phases)

1. User configuration file support (~/.code_puppy/error_classifier.yaml)
2. More granular exception hierarchies with merged metadata
3. Async-specific exception handling (asyncio.TimeoutError)
4. i18n support for user-facing messages
5. Integration with structured logging (JSON output)
6. Retry orchestration helpers (exponential backoff, circuit breaker integration)

## Usage Example

```python
from code_puppy.plugins.error_classifier import ExceptionRegistry, ExInfo
from code_puppy.plugins.error_classifier.exinfo import ErrorSeverity

# Register a custom exception
ExceptionRegistry.register(
    MyAPIError,
    ExInfo(
        name="API Error",
        retry=True,
        description="My API returned an error.",
        suggestion="Check API status at https://status.example.com",
        severity=ErrorSeverity.WARNING,
        retry_after_seconds=30,
    )
)

# Classify an exception
should_retry, ex_info = ExceptionRegistry.classify(some_exception)
if should_retry:
    delay = ExceptionRegistry.get_retry_delay(some_exception)
    print(f"Retry in {delay} seconds...")
```
# Structured Exception Registry Plugin - Design Document

**Issue:** `code_puppy-eazr`  
**Status:** ✅ Implemented  
**Priority:** P2

## Overview

The Error Classifier plugin provides centralized, structured error handling for Code Puppy. It maintains a registry mapping exception classes to rich metadata (ExInfo), enabling automatic classification of errors into retryable vs permanent, with actionable guidance for users.

**Goals:**
1. ✅ Unified exception metadata registry
2. ✅ Automatic error classification via `agent_exception` hook
3. ✅ Distinguish transient (retryable) vs permanent errors
4. ✅ Provide contextual suggestions for common errors

## ExInfo Dataclass Definition

```python
from dataclasses import dataclass, field
from typing import Optional, Callable, Any
from enum import Enum

class ErrorSeverity(Enum):
    INFO = "info"        # Log only, no action needed
    WARNING = "warning"  # User should know, may auto-recover
    ERROR = "error"      # Action required, may retry
    CRITICAL = "critical"  # Fatal, no retry possible

@dataclass(frozen=True)
class ExInfo:
    """Structured metadata for an exception type."""
    
    name: str
    """Human-readable name for this error type."""
    
    retry: bool
    """Whether this error is typically transient and safe to retry."""
    
    description: str
    """Brief explanation of what this error means."""
    
    suggestion: Optional[str] = None
    """Actionable suggestion for resolving the error."""
    
    severity: ErrorSeverity = ErrorSeverity.ERROR
    """Severity level for UI display."""
    
    retry_after_seconds: Optional[int] = None
    """Recommended delay before retry (if retry=True)."""
    
    callback: Optional[Callable[[Exception], Any]] = None
    """Optional hook to run when this exception occurs."""

    def format_message(self, exc: Exception) -> str:
        """Format a user-friendly message for this exception."""
        msg = f"[{self.name}] {self.description}"
        if self.suggestion:
            msg += f"\n💡 Suggestion: {self.suggestion}"
        if self.retry:
            msg += "\n🔄 This error may be transient — retry recommended."
        return msg
```

## Registry Implementation

**Registry Class:**
```python
from typing import Type, Dict, List, Optional
import logging

logger = logging.getLogger(__name__)

class ExceptionRegistry:
    """Central registry for exception metadata."""
    
    _registry: Dict[Type[Exception], ExInfo] = {}
    _patterns: List[tuple[str, ExInfo]] = []  # Regex patterns for string matching
    
    @classmethod
    def register(
        cls,
        exc_class: Type[Exception],
        ex_info: ExInfo,
    ) -> None:
        """Register ExInfo for an exception class."""
        cls._registry[exc_class] = ex_info
        logger.debug(f"Registered {exc_class.__name__} -> {ex_info.name}")
    
    @classmethod
    def register_pattern(
        cls,
        pattern: str,
        ex_info: ExInfo,
    ) -> None:
        """Register ExInfo for exceptions matching a pattern (fallback)."""
        import re
        cls._patterns.append((re.compile(pattern, re.IGNORECASE), ex_info))
    
    @classmethod
    def get_ex_info(cls, exc: Exception) -> Optional[ExInfo]:
        """Look up ExInfo for an exception instance."""
        exc_class = type(exc)
        
        # Direct lookup
        if exc_class in cls._registry:
            return cls._registry[exc_class]
        
        # MRO lookup (check parent classes)
        for parent in exc_class.__mro__[1:]:  # Skip self
            if parent in cls._registry:
                return cls._registry[parent]
        
        # Pattern fallback for string exceptions
        exc_str = str(exc)
        for regex, ex_info in cls._patterns:
            if regex.search(exc_str):
                return ex_info
        
        return None
    
    @classmethod
    def classify(cls, exc: Exception) -> tuple[bool, Optional[ExInfo]]:
        """Classify an exception. Returns (should_retry, ex_info)."""
        ex_info = cls.get_ex_info(exc)
        if ex_info:
            return ex_info.retry, ex_info
        # Default: unknown errors are not retryable
        return False, None
```

## Built-in Registry Entries

```python
def _register_builtin_exceptions():
    """Register known exception types with metadata."""
    
    # Network / Transient Errors (Retryable)
    registry = ExceptionRegistry
    
    registry.register(
        ConnectionError,
        ExInfo(
            name="Connection Failed",
            retry=True,
            description="Could not establish connection to remote service.",
            suggestion="Check network connectivity and retry.",
            retry_after_seconds=5,
        )
    )
    
    registry.register(
        TimeoutError,
        ExInfo(
            name="Request Timeout",
            retry=True,
            description="The operation timed out waiting for a response.",
            suggestion="The service may be slow — retry with backoff.",
            retry_after_seconds=10,
        )
    )
    
    # Auth Errors (Not retryable without action)
    registry.register(
        PermissionError,
        ExInfo(
            name="Permission Denied",
            retry=False,
            description="Insufficient permissions to perform this action.",
            suggestion="Check file permissions or run with elevated privileges.",
            severity=ErrorSeverity.WARNING,
        )
    )
    
    # Pattern-based fallbacks
    registry.register_pattern(
        r"rate.?limit|429|too many requests",
        ExInfo(
            name="Rate Limited",
            retry=True,
            description="API rate limit exceeded.",
            suggestion="Wait and retry with exponential backoff.",
            retry_after_seconds=60,
        )
    )
    
    registry.register_pattern(
        r"quota|billing|payment",
        ExInfo(
            name="Account Quota",
            retry=False,
            description="Account quota or billing issue.",
            suggestion="Check your account billing and quota settings.",
            severity=ErrorSeverity.WARNING,
        )
    )
```

## Hook Integration

Uses `agent_exception` and `agent_run_end` hooks for automatic classification.

```python
from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_error, emit_warning, emit_info

def _on_agent_exception(exception, *args, **kwargs):
    """Classify and handle agent exceptions."""
    registry = ExceptionRegistry
    ex_info = registry.get_ex_info(exception)
    
    if ex_info is None:
        # Unknown exception - log generically
        logger.exception("Unhandled exception in agent")
        return
    
    # Emit formatted message based on severity
    message = ex_info.format_message(exception)
    
    if ex_info.severity == ErrorSeverity.CRITICAL:
        emit_error(f"🚨 {message}")
    elif ex_info.severity == ErrorSeverity.ERROR:
        emit_error(f"❌ {message}")
    elif ex_info.severity == ErrorSeverity.WARNING:
        emit_warning(f"⚠️ {message}")
    else:
        emit_info(f"ℹ️ {message}")
    
    # Run callback if registered
    if ex_info.callback:
        try:
            ex_info.callback(exception)
        except Exception as cb_exc:
            logger.error(f"ExInfo callback failed: {cb_exc}")

register_callback("agent_exception", _on_agent_exception)
```

**Retry Decision Helper:**
```python
def _should_retry_agent(exception) -> tuple[bool, int]:
    """Determine if agent should retry after exception.
    
    Returns: (should_retry, delay_seconds)
    """
    registry = ExceptionRegistry
    ex_info = registry.get_ex_info(exception)
    
    if ex_info is None:
        return False, 0
    
    return ex_info.retry, ex_info.retry_after_seconds or 0
```

## Public API

**Module exports:**
```python
# error_classifier/__init__.py
from .registry import ExceptionRegistry, ExInfo, ErrorSeverity
from .builtins import register_builtin_exceptions

__all__ = [
    "ExceptionRegistry",
    "ExInfo", 
    "ErrorSeverity",
    "register_builtin_exceptions",
    "classify_exception",
]

# Convenience function
def classify_exception(exc: Exception) -> tuple[bool, Optional[ExInfo]]:
    """Quick classify an exception."""
    return ExceptionRegistry.classify(exc)
```

## Configuration Schema

**`config.py`:**
```python
from dataclasses import dataclass, field
from typing import Dict, Any

@dataclass
class ErrorClassifierConfig:
    enabled: bool = True
    log_all_exceptions: bool = True
    default_retry: bool = False  # Conservative default
    custom_patterns: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    
    @classmethod
    def from_code_puppy_config(cls) -> "ErrorClassifierConfig":
        # Load from ~/.code_puppy/config.yaml
        pass
```

**User Config:**
```yaml
error_classifier:
  enabled: true
  log_all_exceptions: true
  custom_patterns:
    "my_custom_error":
      retry: true
      description: "My custom API error"
      suggestion: "Check API key configuration"
```

## File Structure

```
code_puppy/plugins/error_classifier/
├── __init__.py           # Public API exports
├── register_callbacks.py # Hook registrations
├── config.py             # Configuration
├── registry.py           # ExceptionRegistry class
├── exinfo.py             # ExInfo dataclass & ErrorSeverity
├── builtins.py           # Built-in exception registrations
├── patterns.py           # Pattern-based classification
├── retry_logic.py        # Retry decision helpers
└── DESIGN.md             # This document
```

## Integration with Other Plugins

**Error Logger Plugin:**
The error_classifier can enhance error_logger by providing structured metadata before logging.

**Shell Safety Plugin:**
Can mark shell command errors (CommandNotFound, etc.) with specific retry/retry-not guidance.

**Future: Retry Orchestrator:**
A future plugin could consume ExInfo.retry to implement automatic retry with backoff.

## Testing Approach

**Unit Tests:**
1. Test registry lookups (direct, MRO, pattern)
2. Test ExInfo formatting
3. Test classification logic
4. Test custom pattern registration

**Integration Tests:**
1. Test hook integration with mock exceptions
2. Test with real network errors (mocked)
3. Verify severity-based messaging

**Test Fixtures:**
```python
TEST_EXCEPTIONS = {
    ConnectionError: ExInfo(name="Connection", retry=True, description="..."),
    PermissionError: ExInfo(name="Permission", retry=False, description="..."),
    ValueError: None,  # Should return default
}
```

## Implementation Phases

**Phase 1: Core Registry (MVP)**
- ExInfo dataclass
- ExceptionRegistry with MRO lookup
- Basic built-in registrations
- agent_exception hook integration

**Phase 2: Pattern Matching & Config**
- Pattern-based fallback classification
- User configuration support
- More built-in exception types

**Phase 3: Advanced Features**
- Callback support in ExInfo
- Retry orchestration helpers
- Integration with observability tools

## Open Questions

1. Should we support exception hierarchies with merged metadata?
2. How to handle async-specific exceptions (asyncio.TimeoutError vs TimeoutError)?
3. Should ExInfo support i18n for user-facing messages?
4. How to integrate with structured logging (JSON output)?
