# supervisor_review plugin

**Status**: Stable
**Adopted from**: [orion-multistep-analysis](../../../../) — `supervisor/orchestrator.py:582-742`

Registers a single tool, `supervisor_review_loop`, that any code_puppy agent can call to run a quality-gated multi-agent review iteration.

## What it does

Given a list of worker agents, a supervisor agent, and a task, this tool:

1. Runs each worker agent sequentially on the task
2. Feeds all worker outputs into the supervisor agent for review
3. Checks whether the supervisor is satisfied
4. If not satisfied, appends the supervisor's feedback to the task prompt and loops
5. Terminates when the supervisor is satisfied or `max_iterations` is hit

This is a **Python-level loop**, not an LLM-driven pattern — meaning an agent cannot "forget" to iterate. The framework enforces the cap, cancellation, and feedback accumulation.

## When to use it

- You have a task where one agent writes and another reviews (code + reviewer)
- You want a hard cap on iterations (no runaway loops)
- You need structured feedback accumulation across iterations
- You want partial results on failure, not a whole-loop crash

## When NOT to use it

- You need parallel worker execution (this loop is sequential per iteration)
- Your task is one-shot and doesn't benefit from review
- You want the LLM to decide whether to iterate (use the pack-leader pattern instead)

## Tool signature

```python
supervisor_review_loop(
    worker_agents: list[str],
    supervisor_agent: str,
    task_prompt: str,
    max_iterations: int = 3,
    satisfaction_mode: str = "structured",
    session_prefix: str | None = None,
) -> dict
```

### Parameters

| Name | Type | Default | Description |
|---|---|---|---|
| `worker_agents` | `list[str]` | required | Agent names to run sequentially each iteration |
| `supervisor_agent` | `str` | required | Agent name that reviews worker output |
| `task_prompt` | `str` | required | Initial task description |
| `max_iterations` | `int` | `3` | Hard cap on iterations |
| `satisfaction_mode` | `str` | `"structured"` | How to detect satisfaction |
| `session_prefix` | `str \| None` | `None` | Per-iteration session prefix |

### Satisfaction modes

- **`structured`** (default) — supervisor must emit JSON with a `verdict`, `satisfied`, or `aligned` field. Most reliable.
- **`keyword`** — Orion-compatible keyword heuristic. Supervisor must say "fully met" / "fully satisfied" for approval or "needs work" / "not met" for rejection. Brittle but zero-config.
- **`llm_judge`** — uses a second LLM call to judge the supervisor output. Currently stubbed (delegates to structured with degraded confidence); full implementation is a follow-up.

### Return value

```python
{
    "success": bool,                 # True if supervisor was satisfied
    "iterations_run": int,
    "max_iterations": int,
    "final_worker_outputs": dict,    # Last iteration's worker outputs
    "final_supervisor_output": str,  # Last supervisor response
    "feedback_history": [...],       # Per-iteration feedback
    "iterations": [...],             # Full per-iteration snapshots
    "error": str | None,             # Set if an agent failed
    "artifacts_dir": str | None,     # Path to written transcripts
}
```

## Examples

### Single-worker review with a code reviewer supervisor

```python
result = await supervisor_review_loop(
    worker_agents=["code-puppy"],
    supervisor_agent="shepherd",
    task_prompt="Write a function to validate email addresses per RFC 5322",
    max_iterations=3,
    satisfaction_mode="structured",
)
if result["success"]:
    print(f"Done in {result['iterations_run']} iterations")
    print(result["final_worker_outputs"]["code-puppy"])
else:
    print(f"Not satisfied after {result['iterations_run']} iterations")
    print(f"Last feedback: {result['final_supervisor_output']}")
```

### Multi-worker pipeline (writer + tester + reviewer)

```python
result = await supervisor_review_loop(
    worker_agents=["code-puppy", "terrier"],  # code writer, then test writer
    supervisor_agent="shepherd",               # reviews both
    task_prompt="Implement a binary search tree with insert/search/delete",
    max_iterations=3,
)
```

### Keyword mode (Orion-compatible)

```python
result = await supervisor_review_loop(
    worker_agents=["code-puppy"],
    supervisor_agent="reviewer",
    task_prompt="Refactor the config loader",
    satisfaction_mode="keyword",
)
```

## Design notes

- **Feedback injection**: on iteration N, the worker prompt includes all prior supervisor feedback under a "Previous supervisor feedback to address" header. Ported from Orion's `_format_feedback_history()`.
- **Session isolation**: when `session_prefix` is set, each agent invocation per iteration gets a unique session ID (e.g. `myprefix_code-puppy_iter2`), preventing cross-iteration context bleed.
- **Error handling**: an exception from any worker aborts the loop with a structured partial-result (`success=False`, `error=...`). This is an improvement over Orion, which crashes the entire workflow.
- **Artifacts**: when `artifacts_root` is set at the orchestrator level, per-iteration transcripts are written to `supervisor_review/<session>/iter{N}_<agent>.log` with a `summary.json`.

## References

- Feature: supervisor review loop
- Orion source: `orion-multistep-analysis/src/research_agent/supervisor/orchestrator.py:582-742`
- Orion constant: `MAX_SUPERVISOR_REVIEW_LOOPS = 3` at `orchestrator.py:32`
- Keyword mode inspiration: Orion's `_supervisor_satisfied()` at `orchestrator.py:179-187`
