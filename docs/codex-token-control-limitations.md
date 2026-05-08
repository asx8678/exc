# Codex Token Control Limitations

## Summary

The ChatGPT Codex API (used for `gpt-5.3-codex`, `gpt-5.3-codex-spark`, etc.) **does not support** standard token control parameters like `max_tokens` or `max_output_tokens`. When these parameters are included in requests, they are stripped by the `ChatGPTCodexAsyncClient` interceptor before the API call.

This is a known API limitation from OpenAI's Responses API (used by Codex/ChatGPT), not a Code Puppy bug.

## Affected Parameters

| Parameter | Status | Notes |
|-----------|--------|-------|
| `max_tokens` | ❌ Stripped | Not supported by Codex/Responses API |
| `max_output_tokens` | ❌ Stripped | Not supported by Codex/Responses API |
| `verbosity` | ❌ Stripped | Not supported at top-level (must be under `text` object) |

## Why This Happens

### 1. API Architecture Difference

The Codex API uses OpenAI's **Responses API** (`/v1/responses`), not the traditional Chat Completions API (`/v1/chat/completions`). These APIs have different parameter schemas:

- **Chat Completions API**: Supports `max_tokens`, `temperature`, `top_p`, etc.
- **Responses API**: Uses `reasoning.effort`, `text.verbosity` (nested), and different output control mechanisms

### 2. Reasoning Model Behavior

Codex models (`gpt-5.x-codex`, `o1`, `o3`, `o4` series) are "reasoning models" that:
- Dynamically allocate tokens based on problem complexity
- Don't respect fixed token limits the same way traditional models do
- Use `reasoning.effort` (minimal/low/medium/high/xhigh) instead of `max_tokens`

### 3. Store=false Requirement

The Codex API requires `store=false`, which means:
- Conversations are not persisted server-side
- Item references (like `reasoning_content`) become invalid between requests
- The API manages output length internally

## Where Token Controls Are Handled

### Core Resolution: `model_factory.py`

```python
def resolve_max_output_tokens(
    model_name: str,
    model_config: dict[str, Any],
    requested: int | None = None,
) -> int:
    """Resolve the max output tokens for a model request.

    Priority order:
    1. Explicit requested value (if provided)
    2. Model-specific max_output_tokens from config
    3. Default calculation: max(2048, min(context * 0.15, 65536))
    """
```

This function calculates tokens for providers that support it. For Codex models, the calculated value is **ignored** at the HTTP level — but it is still used for pre-flight context budget enforcement.

### Model Config Source: `models_dev_parser.py`

The `models_dev_parser.py` sets `max_output_tokens` from provider metadata:

```python
if model.max_output > 0:
    config["max_output_tokens"] = model.max_output
```

For Codex models this value comes from the provider's advertised limits but is never sent to the API.

### HTTP Interception: `chatgpt_codex_client.py`

The `ChatGPTCodexAsyncClient` intercepts all POST requests and:

1. Injects required Codex fields (`store=false`, `stream=true`)
2. Strips unsupported parameters (`max_tokens`, `max_output_tokens`, `verbosity`)
3. Adds reasoning settings for reasoning models (`gpt-5`, `o1`, `o3`, `o4`)
4. Converts streaming responses to non-streaming format when needed

When stripping params, the client emits a **log-level warning**:

```python
unsupported_params = ["max_output_tokens", "max_tokens", "verbosity"]
for param in unsupported_params:
    if param in data:
        logger.warning(
            "Removing unsupported parameter '%s' for Codex API. "
            "Token limits are not respected by the Responses API."
            " Use reasoning.effort to control output length.",
            param,
        )
```

> **Note**: This warning goes to the log file, not the user's terminal. See [Recommendations](#recommendations) below.

### Model Settings: `model_factory.py` - `make_model_settings()`

For GPT-5/Codex models, settings use `OpenAIResponsesModelSettings`:

```python
uses_responses_api = (
    model_type == "chatgpt_oauth"
    or (model_type == "openai" and "codex" in model_name)
    or (model_type == "custom_openai" and "codex" in model_name)
)

if uses_responses_api:
    model_settings_dict["openai_reasoning_summary"] = get_openai_reasoning_summary()
    if "codex" not in model_name:
        model_settings_dict["openai_text_verbosity"] = get_openai_verbosity()
    model_settings = OpenAIResponsesModelSettings(**model_settings_dict)
```

Note that `verbosity` is only set for non-Codex Responses API models — for Codex models it would be stripped anyway.

### Context Budget Enforcement: `base_agent.py`

Before every API call, `base_agent` runs a pre-flight context budget check:

```python
max_output_tokens = resolve_max_output_tokens(model_name, model_config)
projected_total = total_estimated + max_output_tokens
safe_limit = int(context_length * 0.9)

if projected_total > safe_limit:
    raise RuntimeError(
        f"Context budget exceeded for {model_name}: "
        f"estimated {total_estimated} input + {max_output_tokens} output = {projected_total} tokens "
        f"(context: {context_length}, safe: {safe_limit})."
    )
```

This prevents context window overflow but **does not** control actual API output length.

### Overflow Detection: `utils/overflow_detect.py`

Contains 20+ regex patterns for detecting context overflow errors across providers, including OpenAI-specific patterns like:
- `"maximum context length is \d+ tokens"`
- `"reduce the length of the messages"`
- `"input is too long for requested model"`

## Token Flow for Codex Models

```
models.json / models_dev_parser.py
    → max_output_tokens set from provider metadata (e.g., 32768)
        ↓
model_factory.py:resolve_max_output_tokens()
    → calculates effective limit (config or formula)
        ↓
model_factory.py:make_model_settings()
    → stores in settings dict as max_tokens
        ↓
base_agent.py:_check_context_budget_before_send()
    → pre-flight overflow check (raises RuntimeError if exceeded)
        ↓
[Chat Completions API]         [Codex / Responses API]
 max_tokens sent ✅              chatgpt_codex_client.py
                                 max_tokens STRIPPED ❌
                                 reasoning.effort used instead
```

**Key insight**: `resolve_max_output_tokens()` calculates a value and `base_agent.py` uses it for overflow prevention, but the Codex HTTP client strips it before the API call. The calculated value is still useful for budget enforcement — it prevents sending requests that would overflow the context window — but it does **not** control actual API output length.

## What Works Instead

For Codex/reasoning models, use these controls:

| Control | Parameter | Values | Description |
|---------|-----------|--------|-------------|
| Reasoning Depth | `reasoning.effort` | minimal, low, medium, high, xhigh | Controls how much reasoning the model does |
| Reasoning Visibility | `reasoning.summary` | auto, concise, detailed | Controls reasoning summary output |
| Response Length (non-Codex) | `text.verbosity` | low, medium, high | Controls response verbosity |

### xhigh Reasoning Effort

Only Codex models and GPT-5.4 support `reasoning_effort: "xhigh"`. Regular GPT-5 models are capped at `"high"`. This is controlled by `supports_xhigh_reasoning` in model config.

### Codex Model Registry

Default Codex models and their context lengths (from `plugins/chatgpt_oauth/utils.py`):

| Model | Context Length |
|-------|---------------|
| `gpt-5.4` | 272,000 (default) |
| `gpt-5.3-instant` | 192,000 |
| `gpt-5.3-codex-spark` | 131,000 |
| `gpt-5.3-codex` | 272,000 (default) |

## User Impact

### What Users See

1. **No error**: Requests succeed — unsupported params are stripped before sending
2. **Warning in logs only**: The `ChatGPTCodexAsyncClient` emits a `logger.warning()` when stripping params. This appears in Code Puppy's log file but is **not** surfaced to the user's terminal via `emit_warning()`.
3. **Unexpected output length**: Responses may be longer or shorter than expected since there's no client-side limit

### Context Budget Enforcement

Code Puppy does enforce context budgets *before* sending requests (in `base_agent.py`). This prevents context window overflow, but doesn't control actual output length from the API.

## Recommendations

### For Users

1. **Use `reasoning_effort` instead of `max_tokens`** for Codex models
   - Lower effort = faster, shorter responses
   - Higher effort = more thorough, longer responses

2. **Monitor token usage** via the token ledger (visible in session summaries)

3. **Understand output length is model-controlled** for reasoning models

### For Developers

1. **Warning visibility**: The current `logger.warning()` when stripping params only goes to logs. Consider upgrading to `emit_warning()` so users see it in the terminal on first use of a Codex model with token limits configured.
2. **UI clarity**: Model settings menu could indicate which controls apply to which models (e.g., graying out `max_tokens` for Codex models).
3. **Documentation**: Keep this doc updated as OpenAI's API evolves.

## Related Code

| File | Purpose |
|------|---------|
| `code_puppy/chatgpt_codex_client.py` | HTTP interceptor that strips unsupported params and logs warnings |
| `code_puppy/model_factory.py` | Token resolution (`resolve_max_output_tokens`) and model settings creation |
| `code_puppy/agents/base_agent.py` | Context budget enforcement before API calls (`_check_context_budget_before_send`) |
| `code_puppy/models_dev_parser.py` | Parses model metadata; sets `max_output_tokens` from provider data |
| `code_puppy/utils/overflow_detect.py` | Regex patterns for detecting context overflow across providers |
| `code_puppy/command_line/model_settings_menu.py` | UI for configuring model settings (reasoning_effort, verbosity, etc.) |
| `code_puppy/plugins/chatgpt_oauth/utils.py` | Codex model registry, context lengths, and xhigh reasoning support |
| `tests/test_chatgpt_codex_client.py` | Tests for param stripping behavior |

## References

- OpenAI Responses API documentation
- OpenAI Reasoning models guide
- Issue: token-control-limitations
