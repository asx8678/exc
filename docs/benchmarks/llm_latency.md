# LLM Latency & Streaming Benchmarks

**Status:** 🔑 Implemented, credential-gated — requires operator API keys to run live probes
**Issues:** code_puppy-xmx (TTFB probe), code_puppy-sgc (streaming schema/fixtures), code_puppy-axx (streaming probes)
**Category:** Performance Baseline

## Summary

LLM latency benchmarks are implemented in the harness as credential-gated
probes. They execute live API calls only when `PUP_ANTHROPIC_API_KEY` or
`PUP_OPENAI_API_KEY` is set. Without credentials, the harness reports
`not_implemented` in JSON output and continues.

**No live baseline numbers are committed to the repository.** Baseline
measurements depend on operator-provided credentials and network
conditions, so they are not reproducible in CI. Operators who run the
probes should record results locally.

## Probe Operations

### Non-Streaming TTFB (`llm_latency`)

Single-shot requests measuring time-to-first-block — the wall-clock time
from request dispatch to receipt of a complete response block.

| Operation | Provider | Model | Credential env var |
|-----------|----------|-------|--------------------|
| `anthropic_ttfb` | Anthropic | claude-sonnet-4-20250514 | `PUP_ANTHROPIC_API_KEY` |
| `openai_ttfb` | OpenAI | gpt-4o-mini | `PUP_OPENAI_API_KEY` |

Legacy env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) are accepted as
fallbacks.

### Streaming TTFT/TBT (`llm_streaming`)

Streaming requests measuring time-to-first-token and inter-token gaps.

| Operation | Provider | Model | Credential env var |
|-----------|----------|-------|--------------------|
| `anthropic_streaming_ttft_tbt` | Anthropic | claude-sonnet-4-20250514 | `PUP_ANTHROPIC_API_KEY` |
| `openai_streaming_ttft_tbt` | OpenAI | gpt-4o-mini | `PUP_OPENAI_API_KEY` |

## Definitions

### TTFT (Time-to-First-Token)

Wall-clock time from request dispatch to arrival of the very first token
over a streaming connection. This is **distinct** from TTFB: TTFT measures
when the first token *arrives*, not when a complete block is returned.

Measured with `time.perf_counter()` (monotonic, sub-μs resolution).

### TBT (Time-Between-Tokens)

Inter-token latency computed from consecutive token arrival timestamps.
Reported as `LatencyStats` (mean, median, p95, p99) across all successful
iterations. Gaps are never computed across iteration boundaries — each
iteration's gaps are computed independently, then aggregated.

Empty-string deltas (e.g. initial role-only chunks from OpenAI) are
**not** token arrivals and are filtered out. Whitespace-only deltas
(`" "`, `"\n"`) **are** token arrivals.

### TTFB (Time-to-First-Block)

Wall-clock time from request dispatch to receipt of a complete response
block (non-streaming, single-shot). Approximates TTFT but includes
server-side generation time for the entire first block.

## Prompt Fixtures

Streaming probes use deterministic prompts from
`scripts/bench_baseline/streaming_fixtures.py`. Each fixture carries a
stable `prompt_id` (format: `<name>_v<n>`) so benchmark results can
reference the exact prompt without embedding text.

| Fixture ID | Description | Expected min tokens |
|------------|-------------|-------------------|
| `short_v1` | Minimal prompt; ~1 sentence of code | 10 |
| `medium_v1` | Multi-paragraph explanatory prompt; sustained generation | 80 |

Lookup:

```python
from scripts.bench_baseline.streaming_fixtures import get_fixture

fixture = get_fixture("short_v1")
# fixture.prompt_id == "short_v1"
# fixture.text == "Write a one-sentence Python function that adds two numbers."
```

**Convention:** Never reuse a `prompt_id` when the prompt text changes.
Bump the version suffix instead (e.g. `short_v2`).

## Running the Probes

```bash
# Set credentials
export PUP_ANTHROPIC_API_KEY="sk-ant-..."
export PUP_OPENAI_API_KEY="sk-..."

# Run LLM probes only (non-streaming + streaming)
python scripts/bench_baseline_harness.py --category llm

# Run full suite (tools + LLM)
python scripts/bench_baseline_harness.py

# Quick mode (1 iteration per probe instead of 3)
python scripts/bench_baseline_harness.py --category llm --quick

# Without credentials: reports "not_implemented", no live calls made
env -u PUP_ANTHROPIC_API_KEY -u PUP_OPENAI_API_KEY \
  -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
  python scripts/bench_baseline_harness.py --category llm --quick
```

## Output Shape

### Non-streaming result (`llm_latency`)

`latency_stats` contains TTFB statistics across iterations.
`metadata` includes `model`, `max_tokens`, `prompt_chars`, `failures`.

### Streaming result (`llm_streaming`)

`latency_stats` contains **TTFT** statistics across iterations.
`metadata` includes:

| Field | Description |
|-------|-------------|
| `ttft_ms` | TTFT from the last iteration (ms) |
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

### Without credentials

Both probe categories append to the `not_implemented` list in the JSON
output (e.g. `"llm_latency_no_credentials"`,
`"llm_streaming_no_credentials"`). No API calls are made.

## Tool Execution Baseline (Always Available)

Tool execution overhead benchmarks run offline without credentials:

```bash
python scripts/bench_baseline_harness.py --category tools
```

These establish baseline metrics for `list_files`, `read_file`, and
`grep`. See [README.md](README.md) for full details.

## Policy

1. We do **NOT** invent synthetic LLM latency numbers
2. We do **NOT** mock provider responses (not representative of real latency)
3. We do **NOT** include API keys in the repository
4. We do **NOT** commit live baseline numbers (not reproducible in CI)
5. We **DO** run live probes when credentials are available
6. We **DO** report `not_implemented` truthfully when credentials are absent
7. We **DO** capture and report failures honestly (never as successful latency)

## Implementation Modules

| Module | Purpose |
|--------|---------|
| `scripts/bench_baseline/llm.py` | Non-streaming TTFB probes (`LLMLatencyBenchmarks`) |
| `scripts/bench_baseline/streaming_probes.py` | Streaming TTFT/TBT probes (`StreamingProbes`) |
| `scripts/bench_baseline/streaming.py` | `StreamingMetrics` dataclass, `compute_streaming_metrics()`, inter-token gap computation |
| `scripts/bench_baseline/streaming_fixtures.py` | Deterministic prompt definitions (`short_v1`, `medium_v1`) |
| `scripts/bench_baseline/streaming_self_test.py` | Offline self-test coverage for streaming schema/computation |
| `scripts/bench_baseline/streaming_probes_self_test.py` | Offline self-test coverage for streaming probe extraction logic |
| `scripts/bench_baseline_harness.py` | Harness entry point — orchestrates all categories |

## References

- [ROADMAP.md](../../ROADMAP.md) — Migration tracking
- [Benchmarks README](README.md) — Overview and quick start
- [ADR-004: Migration Strategy](../adr/ADR-004-python-to-elixir-migration-strategy.md)
