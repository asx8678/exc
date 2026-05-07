# Code Puppy Performance Benchmarks

This directory contains performance benchmarks and documentation for the Python-to-Elixir migration.

## Quick Start

Run the baseline benchmark harness:

```bash
# Run all benchmarks
python scripts/bench_baseline_harness.py

# Quick mode (CI friendly)
python scripts/bench_baseline_harness.py --quick

# Tools only (no credentials needed)
python scripts/bench_baseline_harness.py --category tools

# LLM probes only (requires credentials, otherwise reports not_implemented)
python scripts/bench_baseline_harness.py --category llm

# Save results to JSON
python scripts/bench_baseline_harness.py --output results.json

# Run offline self-tests (no pytest required)
python scripts/bench_baseline_harness.py --self-test
```

## Benchmark Categories

### 1. Tool Execution Overhead (Offline Filesystem Primitives)

Benchmarks offline filesystem primitives to establish a baseline for comparison.

**IMPORTANT:** These measure raw filesystem operations (pathlib, rglob, read_text), NOT full Code Puppy tool-path overhead. Full tool-path would include:
- Permission callbacks
- Logging/telemetry
- Elixir transport serialization (when bridge connected)

**Operations measured:**
- `list_files` — Directory traversal via `pathlib.rglob()`
- `read_file` — File content reading via `pathlib.read_text()`
- `grep` — Text search via Python loops

**Metrics:**
- Mean latency (ms)
- P95/P99 latency (ms)
- Throughput (ops/sec)
- Failure count (truthful error capture)

**Run offline:** Yes (creates temporary test files)

### 2. LLM Request Latency (`llm_latency`)

Credential-gated probe for non-streaming LLM API latency. **Requires
operator-provided API keys; no live baseline numbers are committed to the
repository.**

**Status:** Implemented, credential-gated

When `PUP_ANTHROPIC_API_KEY` or `PUP_OPENAI_API_KEY` is set, runs a
minimal single-shot probe per provider:

| Operation | Provider | Model | What it measures |
|-----------|----------|-------|-----------------|
| `anthropic_ttfb` | Anthropic | claude-sonnet-4-20250514 | Time-to-first-block (non-streaming) |
| `openai_ttfb` | OpenAI | gpt-4o-mini | Time-to-first-block (non-streaming) |

Without credentials, both report `not_implemented` in JSON output and no
live API calls are made.

### 3. Streaming LLM TTFT/TBT (`llm_streaming`)

Credential-gated probe for streaming LLM metrics — time-to-first-token
(TTFT) and time-between-tokens (TBT). **Requires operator-provided API
keys; no live baseline numbers are committed to the repository.**

**Status:** Implemented, credential-gated

When `PUP_ANTHROPIC_API_KEY` or `PUP_OPENAI_API_KEY` is set, runs a
streaming probe per provider:

| Operation | Provider | Model | What it measures |
|-----------|----------|-------|-----------------|
| `anthropic_streaming_ttft_tbt` | Anthropic | claude-sonnet-4-20250514 | TTFT + inter-token TBT stats |
| `openai_streaming_ttft_tbt` | OpenAI | gpt-4o-mini | TTFT + inter-token TBT stats |

**Key distinction:**
- **TTFB** (time-to-first-block) = non-streaming metric, the harness returns a complete block
- **TTFT** (time-to-first-token) = streaming metric, first token arrival over a streaming connection
- **TBT** (time-between-tokens) = inter-token gap statistics (mean, median, p95, p99) during streaming

**Prompt fixtures:** Streaming probes use deterministic prompts from
`scripts/bench_baseline/streaming_fixtures.py` (e.g. `short_v1`,
`medium_v1`). Each fixture carries a stable `prompt_id` so benchmark
results reference the exact prompt without embedding text. See
[llm_latency.md](llm_latency.md) for fixture details.

Without credentials, the harness reports `not_implemented` and no live
API calls are made.

## Existing Benchmarks

| Script | Purpose | Status |
|--------|---------|--------|
| `scripts/bench_baseline_harness.py` | Baseline metrics (tools + LLM) | ✅ Active |
| `scripts/bench_message_transport.py` | Message processing comparison | ✅ Active |
| `benchmarks/bench_message_ops.py` | Message operations (pytest) | ✅ Active |
| `mix bench` | Native Elixir runtime benchmarks | ✅ Active |

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `PUP_BENCH_QUICK` | Enable quick mode (fewer iterations) | `0` |
| `PUP_BENCH_OUTPUT` | Output file path | stdout |
| `PUP_BENCH_CATEGORY` | Category filter (`tools` / `llm` / `all`) | `all` |
| `PUP_ANTHROPIC_API_KEY` | Anthropic API key for LLM probes | (none) |
| `PUP_OPENAI_API_KEY` | OpenAI API key for LLM probes | (none) |

Legacy variable names (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) are also
accepted as fallbacks. New code and configuration should prefer `PUP_`
prefixed variables per project convention.

## Output Format

Benchmark results are stored as JSON. Each entry in `results[]` has:
`category`, `operation`, `approach`, `latency_stats` (mean/median/min/max/p95/p99/stdev/samples),
`throughput_ops_per_sec`, `metadata`, and `notes`.

### Tool execution result example

```json
{
  "category": "tool_execution",
  "operation": "list_files",
  "approach": "python_offline_primitive",
  "latency_stats": {
    "mean_ms": 5.234, "median_ms": 4.891,
    "min_ms": 3.456, "max_ms": 12.345,
    "p95_ms": 8.901, "p99_ms": 11.234,
    "stdev_ms": 1.567, "samples": 50
  },
  "throughput_ops_per_sec": 191.2,
  "metadata": {"file_count": 20, "failures": 0},
  "notes": "Offline filesystem primitive (pathlib.rglob) - not full Code Puppy tool-path"
}
```

### LLM latency result (`llm_latency`)

`latency_stats` contains TTFB statistics across iterations.
`metadata` includes `model`, `max_tokens`, `prompt_chars`, `failures`.

```json
{
  "category": "llm_latency",
  "operation": "anthropic_ttfb",
  "approach": "live_api",
  "latency_stats": {
    "mean_ms": 0, "median_ms": 0, "min_ms": 0, "max_ms": 0,
    "p95_ms": 0, "p99_ms": 0, "stdev_ms": 0, "samples": 0
  },
  "throughput_ops_per_sec": 0,
  "metadata": {
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 50,
    "prompt_chars": 55,
    "failures": 0
  },
  "notes": "Time to first block (approximates TTFT). Paid API call."
}
```

> **Note:** All numeric values are zero placeholders; live runs produce measured
> values. The `prompt_chars` value of 55 corresponds to the non-streaming
> probe's default prompt (`"Write a one-line Python function that adds two numbers."`).

### Streaming LLM result (`llm_streaming`)

`latency_stats` contains TTFT statistics across iterations.
`metadata` includes streaming-specific fields:

| Field | Description |
|-------|-------------|
| `ttft_ms` | Time-to-first-token from the last iteration (ms) |
| `tbt_mean_ms` | Mean inter-token gap, aggregated across all successful iterations |
| `tbt_median_ms` | Median inter-token gap |
| `tbt_p95_ms` | P95 inter-token gap |
| `tbt_p99_ms` | P99 inter-token gap |
| `total_duration_ms` | Wall-clock from dispatch to last token |
| `token_count` | Tokens received in the last iteration |
| `chunk_count` | Chunks/events received in the last iteration |
| `model` | Provider model identifier |
| `prompt_id` | Fixture prompt id (e.g. `short_v1`) |
| `failures` | Error count during streaming |
| `successful_iterations` | Iterations that collected token timestamps |
| `timeout` | Whether the streaming response hit a timeout before completing (bool) |
| `metric_names` | Ordered list of metric field names included in metadata, for schema discoverability |

```json
{
  "category": "llm_streaming",
  "operation": "anthropic_streaming_ttft_tbt",
  "approach": "live_api",
  "latency_stats": {
    "mean_ms": 0, "median_ms": 0, "min_ms": 0, "max_ms": 0,
    "p95_ms": 0, "p99_ms": 0, "stdev_ms": 0, "samples": 0
  },
  "throughput_ops_per_sec": 0,
  "metadata": {
    "ttft_ms": 0, "tbt_mean_ms": 0, "tbt_median_ms": 0,
    "tbt_p95_ms": 0, "tbt_p99_ms": 0,
    "total_duration_ms": 0, "token_count": 0, "chunk_count": 0,
    "model": "claude-sonnet-4-20250514",
    "prompt_id": "short_v1",
    "failures": 0, "successful_iterations": 1,
    "timeout": false,
    "metric_names": [
      "ttft_ms", "tbt_mean_ms", "tbt_median_ms",
      "tbt_p95_ms", "tbt_p99_ms", "total_duration_ms",
      "token_count", "chunk_count"
    ]
  },
  "notes": "TTFT from last iteration; TBT aggregated across 1 successful iteration(s)."
}
```

> **Note:** All numeric values are zero placeholders; live runs produce measured
> values.

### Top-level suite fields

| Field | Description |
|-------|-------------|
| `timestamp` | ISO 8601 UTC timestamp |
| `version` | Harness version |
| `mode` | `quick` or `full` |
| `results` | Array of benchmark result objects |
| `pending_benchmarks` | Names of benchmarks not yet implemented |
| `not_implemented` | Reasons why a benchmark was skipped (e.g. `llm_latency_no_credentials`) |
| `failed_benchmarks` | Benchmarks that errored out |

## CI Integration

The benchmark harness is designed for CI:

```yaml
# Example GitHub Actions step
- name: Run self-tests
  run: python scripts/bench_baseline_harness.py --self-test

- name: Run benchmarks
  run: python scripts/bench_baseline_harness.py --quick --output benchmark-results.json

- name: Upload results
  uses: actions/upload-artifact@v4
  with:
    name: benchmark-results
    path: benchmark-results.json
```

## Migration Baseline

These benchmarks establish the performance baseline for the Python-to-Elixir migration tracked in [ROADMAP.md](../../ROADMAP.md).

See also:
- [LLM Latency Details](llm_latency.md) — Probe operations, fixtures, TTFT/TBT definitions, and policy
- [ADR-004: Migration Strategy](../adr/ADR-004-python-to-elixir-migration-strategy.md)
- [Native Acceleration](../acceleration.md)
