# Elixir Application Naming Decision

## Status

**DECIDED** (2026-04-24) — Documented inline, no code changes required.

## Context

The Elixir codebase currently uses `code_puppy_control` as the OTP application name. The ROADMAP flagged this as needing a final decision, with concerns that:

1. The name `code_puppy_control` feels provisional ("control" is semantically vague)
2. User-facing terminology (`pup_ex`, `pup`) already diverges from the internal app name
3. Renaming an OTP application has ripple effects (config keys, module prefixes, escript, releases)

## Decision

**KEEP `code_puppy_control` as the internal OTP app name.**

The naming hierarchy is intentionally layered:

| Layer | Name | Purpose | Stability |
|-------|------|---------|-----------|
| **User binary** | `pup` | The escript / Burrito single-binary that users run | Stable |
| **User runtime** | `pup-ex` / `pup_ex` | The user-facing name for the Elixir runtime (ADR-003) | Stable |
| **OTP app** | `code_puppy_control` | Internal supervision tree, config keys, module namespace | **Keep as-is** |
| **Project** | `code_puppy` | The overall codebase (Python + Elixir) | Stable |

### Rationale

1. **Separation of concerns is clean** — Users never interact with `:code_puppy_control` directly; they run `pup` or `mix pup_ex.*` tasks.

2. **Renaming cost exceeds benefit** — Changing the OTP app name would require:
   - Updating 50+ `config :code_puppy_control` entries
   - Renaming 100+ `CodePuppyControl.*` modules
   - Changing file paths under `elixir/code_puppy_control/`
   - Updating all references in documentation, Python transport code, and CI
   - Zero functional improvement for users

3. **Established terminology already works** — ADR-003 and the CLI docs (`mix pup_ex.*`) already use `pup_ex` consistently for user-facing contexts. No user confusion has been reported.

4. **Future optionality preserved** — If the Elixir port becomes the *only* runtime (post-cutover), we can revisit naming. Until then, churn is unjustified.

## Consequences

### Positive

- No code churn, no risk of breakage
- Existing documentation remains valid
- Clear separation: internal (`code_puppy_control`) vs. external (`pup`, `pup-ex`)

### Negative

- Slight cognitive overhead for contributors ("why `code_puppy_control` not `pup_ex`?" → answered by this doc)
- The name doesn't convey the "Elixir-ness" of the implementation (minor concern)

## When to Revisit

Revisit this decision if:
1. The Python runtime is fully deprecated (post-Phase H cutover)
2. The Elixir app becomes a standalone hex.pm package (unbundled from `code_puppy` repo)
3. User confusion is reported between `code_puppy_control` and `pup_ex` terminology

## References

- ROADMAP.md Phase 0: "Choose final naming for the Elixir umbrella app"
- ADR-003: Dual-Home Config Isolation for Elixir pup-ex (establishes `pup_ex` user terminology)
- `elixir/code_puppy_control/mix.exs` — OTP app definition
- `docs/ELIXIR_CLI_QUICKSTART.md` — `pup_ex` CLI naming

## Related

- ADR-001: Elixir ↔ Python Worker Communication Protocol
- ADR-002: Python → Elixir Event Protocol
- ADR-003: Dual-Home Config Isolation for Elixir pup-ex
- ADR-004: *[RESERVED for Python-to-Elixir migration strategy per ROADMAP]*
