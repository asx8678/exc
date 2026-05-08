# ADR-005: Python Source Parsing Policy — KEEP as Elixir-Native Data Operation

## Status

**ACCEPTED** (2026-05-07)

## Context

The Python-to-Elixir migration (ADR-004) requires cleanly separating:

1. **Python runtime/product removal** — Removing the Python process, bridge,
   `PUP_RUNTIME=python`, `--bridge-mode`, and all Python-side agents/tools
   from the default daily-driver path.
2. **Python source parsing as data** — Statically analyzing `.py` source files
   to extract symbols (functions, classes, imports) for code context, repo
   indexing, and outline extraction — using an Elixir-native Leex/Yecc parser,
   no Python runtime required.

EPIC-H (code-puppy-3o7.3) defines the Parser Policy and Final Guard Alignment.
Issue code-puppy-3o7.3.1 (H1) specifically asks: **should Python source parsing
support in the Elixir parser be kept or removed?**

### Current State

The Python parser lives entirely in the Elixir codebase:

| File | Role | Technology |
|------|------|-----------|
| `src/python_lexer.xrl` | Leex lexer definition | Elixir-build (`:leex` compiler) |
| `src/python_lexer.erl` | Generated Erlang lexer | Auto-generated |
| `src/python_parser.yrl` | Yecc parser grammar | Elixir-build (`:yecc` compiler) |
| `src/python_parser.erl` | Generated Erlang parser | Auto-generated |
| `lib/.../lexers/python_lexer.ex` | Elixir wrapper | Pure Elixir |
| `lib/.../parsers/python_parser.ex` | Elixir parser + symbol extraction | Pure Elixir |

It is compiled alongside the Elixir, Erlang, JavaScript, TypeScript, TSX, and
Rust parsers via `[:leex, :yecc] ++ Mix.compilers()` in `mix.exs`. It requires
**zero Python runtime dependencies**.

### The Python-Free Runtime Guarantee

The [Python-Free Runtime Guarantee v0.1.x](../release/python-free-runtime-guarantee-v0.1.x.md)
explicitly lists Python parsing as a **Python-free** feature:

> Parsing / indexer (Elixir, Erlang, Python, JS, TS, Rust) — Pure Elixir
> leex/yecc parsers under `Parsing.Parser`

The `AGENTS.md` contributing guide similarly states:

> Parse operations are Elixir-owned. Do not add a Python runtime parse backend;
> narrowly scoped UI heuristics are okay only when clearly documented as
> compatibility behavior.

### What Python Parsing Enables

The Python parser powers these user-facing features (all Elixir-native):

- **Code context** — `CodeContext.explore_file/2` extracts symbols from `.py`
  files for agent context window
- **Repo indexer** — `RepoCompass` indexes Python files alongside other languages
- **Outline extraction** — `CodeContext.get_outline/2` returns structured outlines
  of Python source files
- **File explorer** — Quick symbol lookup in Python files during agent reasoning

### What Python Parsing Does NOT Enable

- Python runtime execution (`python3` subprocess)
- Python bridge mode (`PUP_RUNTIME=python`)
- Python agents (`PythonAgent`, `PythonProgrammer`, `PythonReviewer`)
- `code_puppy/` directory modules
- Any feature requiring a live Python process

### Related Downstream Issues

| Issue | Title | Depends on H1 | If KEEP | If REMOVE |
|-------|-------|---------------|---------|-----------|
| H2 (code-puppy-3o7.3.2) | Isolate/allowlist parser-language refs | ✅ | Allowlist `.py`/`.pyi` in parser tests, document runtime-free | Skip (no Python parser left) |
| H3 (code-puppy-3o7.3.3) | Delete parser/lexer modules | ✅ | Skip (keep parser) | Delete python_lexer.*, python_parser.*, tests |
| D3 (code-puppy-3o7.2.3) | Rewrite .py fixture tests | ✅ | Allowlist `.py` fixtures | Replace with non-Python fixtures |
| F4 (code-puppy-3o7.5.4) | No-Python-files CI guard | ✅ | Exclude `**/*.py` test fixture allowlist + parser source from guard | Guard can be absolute (no .py anywhere) |
| F5 (code-puppy-3o7.5.5) | No runtime/tooling refs guard | ✅ | Unchanged — targets `PUP_RUNTIME`, `--bridge-mode`, Python bridge code | Unchanged |

## Decision

**KEEP** Python source parsing support in the Elixir parser.

### D1: Python source parsing is data, not runtime

The critical architectural distinction:

| Concern | What it is | Python Required? | Decision |
|---------|-----------|-----------------|----------|
| Python source parsing | Static `.py` → symbol extraction via Leex/Yecc | **No** — pure BEAM | **KEEP** |
| Python runtime | `python3` subprocess, bridge, agent execution | **Yes** | **REMOVE** (separate EPICs) |

Python source parsing in the Elixir parser is architecturally identical to
parsing Elixir, Erlang, JavaScript, TypeScript, or Rust source code. All are
compiled via the same `[:leex, :yecc]` pipeline. Removing it because "Python"
is in the name conflates two separate concerns.

### D2: Python is a commonly encountered source language

Code Puppy operates on user codebases that frequently contain Python files:
- Project build scripts, data pipelines, ML notebooks
- Open-source repositories that mix languages
- User-provided code snippets in `.py` format
- Test fixtures for tools that must handle polyglot repositories

Removing the parser would degrade the agent's ability to understand these
codebases, producing empty outlines and no symbol extraction for `.py` files.

### D3: Zero maintenance burden

The Python parser is:
- ~250 lines of Elixir (PythonParser) + ~400 lines of Leex/Yecc grammar
- Compiled via existing `[:leex, :yecc]` pipeline — no extra deps
- Tested by ~200 lines of test code (lexer + parser tests)
- Part of the same `ParserBehaviour` contract as all other parsers
- Already listed as Python-free in the runtime guarantee

There is no ongoing Python-dependency cost. Keeping it means zero savings
from removal, but also zero ongoing Python-related maintenance.

### D4: Removing would break existing functionality

These tests and features directly depend on Python parser availability:

- `python_parser_test.exs` — 12 test cases
- `python_lexer_test.exs` — 30+ test cases
- `code_context_test.exs` — 15+ test cases using `.py` fixtures
- `repo_compass_test.exs` — Python file index verification
- `parser_test.exs` — Python language/extension registration tests
- All agent features that use `CodeContext` on Python files

Removing would require rewriting all these tests and degrading agent
capabilities for Python file understanding.

### D5: Naming clarity going forward

The relevant modules should be documented as "Python source parsing support"
rather than "Python parser" to emphasize that they parse Python as data, not
to run Python. This distinction should be reflected in docs, comments, and
H2's allowlist/guard comments.

## Implementation Specification

### H1 Artifact (this ADR)

1. ✅ This ADR documents the keep decision
2. ✅ Beads issue updated with decision notes
3. ✅ Downstream issues annotated with decision impact

### H2: Isolate/allowlist parser-language references

- Add a comment/doc in `parsers.ex` that PythonParser is a data-only parser
  (no runtime dependency)
- In the parser test suite, ensure Python parser tests are allowlisted as
  "Python source parsing" tests, not "Python runtime" tests
- Update `code_context_test.exs` `.py` fixture setup to note it tests
  Python-as-data parsing

### H3: No deletion needed

Since H1 is KEEP, H3 scope is **void**. Python parser/lexer modules,
tests, and agents (the Elixir-side `python_programmer`/`python_reviewer`)
are implementation tasks for other EPICs, not EPIC-H.

### D3: Allowlist .py fixtures (not replace)

Tests that create `.py` fixtures for parser/indexer testing should be
allowlisted with a clear comment that they exercise Python-as-data parsing,
not Python runtime. No fixture replacement needed.

### F4: .py file guard needs allowlist

The CI guard "fail if .py files in repo" must exclude:
- `src/python_lexer.{xrl,erl}`
- `src/python_parser.{yrl,erl}`
- `test/**/*python_parser*`
- `test/**/*python_lexer*`
- Test fixtures under `test/support/` or `test/**/fixtures/` that use `.py`
  for parser testing

### F5: No runtime/tooling references guard — unchanged

The F5 guard targets `PUP_RUNTIME`, `--bridge-mode`, Python bridge code, and
Python runtime references. It does **not** target parser grammar files or
Python-as-data parsing modules. No change needed based on H1 decision.

## Alternatives Considered

### A1: REMOVE — delete all Python parser modules

**Rejected.** Conflates Python-as-runtime with Python-as-data. Would:
- Degrade agent capability on Python files with zero runtime savings
- Require rewriting ~60 test cases
- Break repo indexer, code context, and outline extraction for Python files
- Create confusion when users ask "why can't Code Puppy understand .py files?"
- Provide no meaningful maintenance reduction (parser is BEAM-native)

### A2: REMOVE — but keep parser files as inert source

**Rejected.** Keeping the grammar files without registering them adds metadata
bloat, test confusion, and maintenance ambiguity without any benefit.

### A3: REMOVE — only for non-Python-first installations

**Rejected.** Conditional compilation of Leex/Yecc grammars adds build
complexity (custom compiler, feature flags) for no user-visible benefit.
The parser is ~2 KB of compiled BEAM — negligible for any installation.

## Consequences

### Positive

- **No regression** — code context, repo indexer, outline extraction, and all
  parser-dependent features continue working for Python files
- **Clean architectural boundary** — Python-runtime removal (other EPICs)
  stays separate from Python-as-data parsing (EPIC-H)
- **Zero extra maintenance** — parser is already BEAM-native, uses existing
  compiler pipeline, has no Python dependency
- **Users benefit immediately** — agent can understand Python files without
  a Python runtime
- **Downstream issues clarified** — H3 voided, D3 simplified to allowlist,
  F4 gets an allowlist scope

### Negative

- **Naming confusion persists** — "Python parser" sounds like it depends on
  Python. Mitigated by documentation and the H2 allowlist annotations.
- **F4 guard cannot be fully absolute** — must allowlist parser source files
  and test fixtures. This is a minor grep-pattern maintainability cost.

### Risk Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Future dev confuses parser with runtime | Low | Medium | H2 doc + comments in `parsers.ex` and `python_parser.ex` |
| F4 guard misses a new .py file | Low | Low | F4 should use git-tracked patterns, not repo-global grep |
| Python grammar falls behind language changes | Low | Low | Same risk for all parsers; symbol extraction is best-effort |

## References

- [ADR-004](ADR-004-python-to-elixir-migration-strategy.md) — Overall migration strategy
- [Python-Free Runtime Guarantee v0.1.x](../release/python-free-runtime-guarantee-v0.1.x.md)
- EPIC-H [code-puppy-3o7.3] — Parser Policy and Final Guard Alignment
- H1 [code-puppy-3o7.3.1] — This decision (KEEP)
- H2 [code-puppy-3o7.3.2] — Isolate/allowlist (if KEEP)
- H3 [code-puppy-3o7.3.3] — Delete modules (voided by H1=KEEP)
- D3 [code-puppy-3o7.2.3] — .py fixture policy
- F4 [code-puppy-3o7.5.4] — .py file CI guard
- F5 [code-puppy-3o7.5.5] — Runtime/tooling refs guard
- [AGENTS.md](../../AGENTS.md) — Contributing guide with parser ownership
- [CONTRIBUTING.md](../../CONTRIBUTING.md) — Project conventions

---

**Decision Date**: 2026-05-07
**Decision Maker**: Code Puppy Migration Team (via planning coordination)
**Issue**: code-puppy-3o7.3.1
**Status**: Accepted
