# Code Explorer — Symbol-Augmented Code Exploration

The Code Explorer module integrates `turbo_parse` symbols into code_puppy's existing code exploration flows, providing structural understanding of codebases.

## Quick Start

### Using Module-Level Functions

```python
from code_puppy.code_context import get_code_context, format_outline

# Get context for a file
context = get_code_context("src/main.py", include_content=False)
print(context.get_summary())

# Get file outline
outline = get_file_outline("src/main.py")
print(format_outline(outline))
```

### Using CodeExplorer Class

```python
from code_puppy.code_context import CodeExplorer

explorer = CodeExplorer(enable_cache=True)

# Explore single file
context = explorer.explore_file("src/main.py")
print(f"Found {context.symbol_count} symbols")

# Explore directory
contexts = explorer.explore_directory("src/", pattern="*.py")
for ctx in contexts:
    print(f"{ctx.file_path}: {ctx.symbol_count} symbols")

# Find symbol definitions
results = explorer.find_symbol_definitions("src/", "MyClass")
for file_path, symbol in results:
    print(f"Found {symbol.name} in {file_path} at line {symbol.start_line}")
```

## Features

### Symbol Extraction

Extracts symbols from Python, Rust, JavaScript, TypeScript, and Elixir files:
- Functions and methods
- Classes, structs, interfaces, traits
- Imports and modules
- Variables and constants

> **Note on Rust support:** Rust (`.rs` files) is supported for **exploring external Rust codebases** (e.g., third-party dependencies, other projects). This is separate from Code Puppy's internal native acceleration, which is now **Elixir-only** (see [ARCHITECTURE.md](../ARCHITECTURE.md#native-acceleration)).

### Hierarchical Outline

Builds parent-child relationships:
- Methods nested inside classes
- Inner classes identified
- Import groups organized

### Caching

Results are cached for repeated access:
- Automatic caching by file path
- Cache invalidation support
- Statistics tracking

## API Reference

### CodeContext

Complete context for a code file:

```python
@dataclass
class CodeContext:
    file_path: str
    content: Optional[str]
    language: Optional[str]
    outline: Optional[FileOutline]
    file_size: int
    num_lines: int
    num_tokens: int
    has_errors: bool
```

### FileOutline

Hierarchical outline with symbols:

```python
@dataclass
class FileOutline:
    language: str
    symbols: List[SymbolInfo]
    extraction_time_ms: float
    success: bool
```

Properties:
- `top_level_symbols`: Symbols without parent
- `classes`: Class/struct/trait symbols
- `functions`: Function/method symbols
- `imports`: Import symbols

Methods:
- `get_symbol_by_name(name)`: Find symbol by name
- `get_symbols_in_range(start, end)`: Get symbols in line range

### SymbolInfo

Individual symbol with metadata:

```python
@dataclass
class SymbolInfo:
    name: str
    kind: str  # function, class, method, import, etc.
    start_line: int
    end_line: int
    start_col: int
    end_col: int
    parent: Optional[str]
    docstring: Optional[str]
    children: List[SymbolInfo]
```

## CLI Usage

The plugin provides the `/explore` slash command:

```
/explore file <path>      # Get code context for a file
/explore dir <path>       # Explore a directory
/explore outline <path>   # Show hierarchical outline
/explore help             # Show help
```

### Examples

```
/explore file ./code_puppy/agents/base_agent.py
/explore dir ./code_puppy/plugins
/explore outline ./turbo_parse/src/symbols.rs
```

## Agent Tools

The plugin registers three tools for agents:

### get_code_context

Get enhanced code context with symbols:

```json
{
  "file_path": "src/main.py",
  "include_content": false,
  "with_symbols": true
}
```

Returns:
```json
{
  "file_path": "...",
  "language": "python",
  "num_lines": 100,
  "num_tokens": 500,
  "outline": {
    "symbols": [
      {"name": "MyClass", "kind": "class", "start_line": 10, ...}
    ]
  },
  "symbols_available": true
}
```

### explore_directory

Batch explore a directory:

```json
{
  "directory": "src/",
  "pattern": "*.py",
  "recursive": true,
  "max_files": 50
}
```

Returns list of code contexts with summary statistics.

### get_file_outline

Get hierarchical outline:

```json
{
  "file_path": "src/main.py",
  "max_depth": 2
}
```

Returns formatted outline with symbols.

## Integration with Existing Flows

### Enhancing read_file

The `enhance_read_file_result` helper can add symbol information to file reads:

```python
from code_puppy.code_context import enhance_read_file_result

result = enhance_read_file_result(
    file_path="src/main.py",
    content=content,
    num_tokens=tokens,
    with_symbols=True
)
# Result includes outline and symbols_available fields
```

### Using with Agents

The Code Scout agent can use these tools for efficient exploration:

```python
# In turbo_execute plan
{
  "operations": [
    {"type": "tool", "name": "explore_directory", "args": {"directory": "src/"}},
    {"type": "tool", "name": "get_file_outline", "args": {"file_path": "src/main.py"}}
  ]
}
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Code Explorer                        │
├─────────────────────────────────────────────────────┤
│  CodeContext ────► FileOutline ────► SymbolInfo[]  │
├─────────────────────────────────────────────────────┤
│  • Caching layer                                     │
│  • turbo_parse integration                           │
│  • Language detection                                │
│  • Hierarchy building                                │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│           Existing code_puppy tools                  │
│    (list_files, read_file, grep)                     │
└─────────────────────────────────────────────────────┘
```

## Performance

- Symbol extraction: ~1-5ms per file (with turbo_parse)
- File reading: Standard file I/O
- Caching: O(1) lookup by path
- Directory exploration: Parallel processing ready

## Fallback Behavior

When turbo_parse is not available:
- Files are still explored for basic metadata
- Language is detected from extension
- Symbol extraction is skipped
- Structure is available, just without detailed symbols

## Future Enhancements

- Incremental parsing for large files
- Cross-reference tracking
- Import resolution
- Semantic analysis integration
