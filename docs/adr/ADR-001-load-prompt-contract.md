# ADR-001: load_prompt Hook Semantics

## Status

**Proposed**

## Context

The `load_prompt` callback hook (defined in `code_puppy/callbacks.py`) is intended as a layer-3 plugin extension point for the prompt assembly architecture. It allows plugins to inject additional instructions into agent system prompts.

### Current Inconsistency (UNK3)

As documented in AGENTS.md:

> **Layer 3**: `callbacks.on_load_prompt()` - Plugin additions (e.g., file mentions, pack-parallelism limits) - **Opt-in per agent** - Not all agents call this!
> 
> **Known Inconsistencies (Unresolved)**: Whether `load_prompt` should apply globally to ALL agents is **unresolved**. Currently some agents call it, others don't.

### Evidence from Codebase

**Agents that DO call `on_load_prompt()` (explicit opt-in):**
| Agent | Location | Pattern |
|-------|----------|---------|
| `CodePuppyAgent` | `code_puppy/agents/agent_code_puppy.py:93` | Called in `get_system_prompt()` |
| `PackLeaderAgent` | `code_puppy/agents/agent_pack_leader.py:413` | Called in `get_system_prompt()` |
| `AgentPlanning` | `code_puppy/agents/agent_planning.py:161` | Called in `get_system_prompt()` |
| `PromptReviewer` | `code_puppy/agents/prompt_reviewer.py:140` | Called in `get_system_prompt()` |
| Pack agents | `retriever.py`, `shepherd.py`, `watchdog.py`, `terrier.py` | Called in `get_system_prompt()` |


**Agents that do NOT call `on_load_prompt()` (missing additions):**
| Agent | Location | Issue |
|-------|----------|-------|
| `JSONAgent` | `code_puppy/agents/json_agent.py:73` | Returns raw config, no plugin additions |
| Reviewer agents | `agent_python_reviewer.py`, etc. | Missing file_mentions, prompt_store support |
| `AgentIdentity` | `code_puppy/agents/agent_identity.py` | Uses old mixin pattern |
| `AgentHelios`, `AgentScheduler`, `AgentCodeScout`, etc. | Various | No load_prompt integration |

**AgentPromptMixin behavior:**
```python
# code_puppy/agents/agent_prompt_mixin.py:103-115
def get_full_system_prompt(self) -> str:
    """Get the complete system prompt with platform info and identity."""
    prompt = self.get_system_prompt()
    prompt += "\n\n# Environment\n" + self.get_platform_info()
    prompt += self.get_identity_prompt()
    return prompt  # <-- Does NOT call on_load_prompt()!
```

### What Plugins Use load_prompt For

| Plugin | Purpose | Scope |
|--------|---------|-------|
| `file_mentions` | Inject @file mention support instructions | Universal |
| `prompt_store` | Inject user-defined custom prompts | Per-agent (uses `get_current_agent_name()`) |
| `pack_parallelism` | Inject pack parallelism limits (MAX_PARALLEL_AGENTS) | Mostly Pack agents |
| `turbo_executor` | Add delegation guidance | Agents that invoke sub-agents |
| `ttsr` | Inject triggered rules | Per-rule targeting |
| `file_permission_handler` | Add file permission guidelines | Universal |


### Merge Semantics

Per AGENTS.md:

| Hook Return Type | Merge Strategy |
|-----------------|---------------|
| `str` | Concatenation (newlines) |
| `list` | Extend (concatenate) |
| `dict` | Update (later wins on conflict) |
| `bool` | OR (any True wins) |
| `None` | Ignored |

The `load_prompt` hook expects string returns that are concatenated with newlines.

## Decision

**Adopt Option A: Global Application via AgentPromptMixin**

All agents shall receive `load_prompt` additions automatically through `AgentPromptMixin.get_full_system_prompt()`. This makes the behavior consistent and predictable.

### Rationale

1. **Principle of Least Surprise**: Plugin authors expect `load_prompt` additions to reach all agents
2. **Agent-Aware Filtering Already Exists**: Plugins that need per-agent targeting already do so internally (e.g., `prompt_store` uses `get_current_agent_name()`)
3. **Additive Semantics**: The hook is designed for additive instructions (string concatenation), not replacement
4. **Fixes Missing Coverage**: JSON agents and reviewer agents currently miss critical features like @file mention support

### Alternative Options Considered

**Option B: Opt-in (Status Quo)**
- Agents explicitly call `on_load_prompt()` when desired
- **Rejected**: Leads to inconsistent coverage and bugs where plugins don't work for some agents

**Option C: Target-Agent-Aware Callbacks**
- Pass `agent_name` through `on_load_prompt(agent_name)` to enable selective targeting
- **Rejected**: Plugins that need this already have `get_current_agent_name()`; adding a parameter breaks backward compatibility and adds complexity without clear benefit

## Worked Examples

### Direct Agents (CodePuppyAgent, Pack agents, etc.)

**Current (opt-in pattern):**
```python
def get_system_prompt(self) -> str:
    result = "...base prompt..."
    prompt_additions = callbacks.on_load_prompt()  # Manual call
    if prompt_additions:
        result += "\n".join(prompt_additions)
    return result
```

**After ADR (global via mixin):**
```python
def get_system_prompt(self) -> str:
    return "...base prompt..."  # No manual on_load_prompt call

# get_full_system_prompt() now adds:
# 1. Base prompt from get_system_prompt()
# 2. Environment info (platform, shell, date)
# 3. Identity prompt
# 4. Plugin additions from on_load_prompt()
```

### invoke_agent Temporary Builders

**Location**: `code_puppy/tools/agent_tools.py:676-693`, `:973-982`

**Current:**
```python
instructions = agent_config.get_full_system_prompt()
# ... add puppy_rules ...
prompt_additions = callbacks.on_load_prompt()
if prompt_additions:
    instructions += "\n" + "\n".join(prompt_additions)
```

**After ADR:**
```python
instructions = agent_config.get_full_system_prompt()
# Plugin additions already included by AgentPromptMixin
```

### invoke_agent_headless

**Pattern**: Same as temporary builders

**Key requirement**: Temporary agent builders should continue to receive the same load_prompt additions as direct agents, ensuring consistent behavior regardless of how an agent is invoked.

### Chained get_model_system_prompt Handlers

**Location**: `code_puppy/callbacks.py:900-936`

The `get_model_system_prompt` hook is a **separate** layer-5 extension point that transforms the final system prompt dict. It operates AFTER `load_prompt` and receives:
- `model_name`: Target model identifier
- `default_system_prompt`: Fully built system prompt (now including load_prompt additions)
- `user_prompt`: User's message

This hook returns `dict | None` and uses dict-update merge semantics (later wins). It is designed for model-type plugins that need final transformation control.

**Relationship to load_prompt:**
```
Layer 1: get_system_prompt()                    → Base instructions
Layer 2: AgentPromptMixin adds platform + id      → + Environment + Identity
Layer 3: on_load_prompt()                         → + Plugin additions (NOW GLOBAL)
Layer 4: prepare_prompt_for_model()             → Model-specific adaptation
Layer 5: on_get_model_system_prompt()           → Final dict transformation
```

## Consequences

### Required Changes

1. **Modify `AgentPromptMixin.get_full_system_prompt()`** (1 location)
   - Add call to `callbacks.on_load_prompt()` before returning
   - Filter None values from results
   - Concatenate string additions with newlines

2. **Remove redundant `on_load_prompt()` calls** (~7-8 locations)
   - `code_puppy/agents/agent_code_puppy.py:93`
   - `code_puppy/agents/agent_pack_leader.py:413`
   - `code_puppy/agents/agent_planning.py:161`
   - `code_puppy/agents/prompt_reviewer.py:140`
   - `code_puppy/agents/pack/*.py` (5 pack agents)

3. **Update `agent_tools.py` temporary builders** (2 locations)
   - Remove explicit `on_load_prompt()` calls from `invoke_agent` subagent construction
   - The `get_full_system_prompt()` call already includes plugin additions

### Verification

After implementation, all agents should receive load_prompt additions:

```python
# Test: JSON agents now get file_mentions support
from code_puppy.agents.json_agent import JSONAgent
from code_puppy.callbacks import register_callback

def test_addition():
    return "TEST_ADDITION"

register_callback("load_prompt", test_addition)

agent = JSONAgent("path/to/agent.json")
full_prompt = agent.get_full_system_prompt()
assert "TEST_ADDITION" in full_prompt  # Should pass after ADR
```

### Backward Compatibility

- **Positive**: JSON agents and review agents gain missing functionality
- **Neutral**: Agents that already called `on_load_prompt()` will no longer need to (cleanup opportunity)
- **Risk**: Low - load_prompt handlers are additive and designed to gracefully handle being called multiple times

### Migration Path

1. Implement global load_prompt in `AgentPromptMixin`
2. Remove redundant calls from explicit opt-in agents (cleanup phase)
3. Update documentation in AGENTS.md to mark UNK3 as **Resolved**
4. Add test coverage for JSON agents receiving load_prompt additions

## Related Work

- **M5**: Implementation of this ADR
- **AGENTS.md**: Update Layer 3 description
- **Plugins**: File mentions, prompt_store, pack_parallelism will now work for all agents
- **Issue UNK3**: Can be closed as resolved after M5

## References

- `code_puppy/callbacks.py`: `on_load_prompt()` definition and merge semantics
- `code_puppy/agents/agent_prompt_mixin.py`: `get_full_system_prompt()` implementation
- `AGENTS.md`: Prompt Assembly Architecture documentation
- `code_puppy/plugins/file_mentions/register_callbacks.py`: Example load_prompt handler
- `code_puppy/plugins/prompt_store/commands.py`: Agent-aware load_prompt handler
