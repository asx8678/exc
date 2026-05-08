# Elixir Test Triage — Action Plan

**Date:** 2026-04-24
**Initial branch:** `fix/security-regression-and-test-triage`
**Cleanup branch:** `fix/elixir-triage-quarantine-cleanup`
**Fast-suite command:** `mix test --include triage_pending --exclude slow --exclude integration --max-failures 20`

## Current validation status

**Refreshed on 2026-04-25** on base branch `fix/security-regression-and-test-triage`.

The fast Elixir suite is green with the former quarantine included:

```text
9 doctests, 89 properties, 5184 tests, 0 failures (105 excluded)
```

There are currently **no active test-level or module-level `:triage_pending` quarantines** in `elixir/code_puppy_control/test`.

The global `:triage_pending` exclusion remains in `test_helper.exs` as an explicit safety rail for future quarantine work, but no tests are currently tagged with it.

## Resolved quarantine items

| Scope | File/Test | Original Reason | Resolution |
|---|---|---|---|
| Module | `CodePuppyControl.Transport.StdioServiceTest` | JSON-RPC stdio subprocess harness returned empty/non-JSON responses in the test environment | Fixed stdio subprocess stdout/stderr separation and JSON-RPC response parsing; removed module tag |
| Module | `CodePuppyControl.Transport.ModelServicesRpcTest` | Same subprocess/stdio pattern as `StdioServiceTest` | Reused fixed stdio helper, passed subprocess model fixture env explicitly, and removed module tag |
| Individual test | `CodePuppyControlWeb.TerminalChannelTest` — `close uses pty_session_id, not topic session_id` | Non-deterministic PTY teardown (`:pty_exit`) in channel close path | Unsubscribed the terminating channel before closing the PTY session; removed test tag |

## Historical failure snapshot

The initial triage snapshot found 125 full-suite failures / 126 fast-suite failures. The main buckets were:

| Root Cause | Historical Count | Bucket | Current Status |
|---|---:|---|---|
| `F_ENV: StdioService` subprocess harness | 71 | Environment / harness | Resolved; transport subprocess tests are active in the default suite |
| `C_SECURITY: sensitive_path?` regression | 17 | Production bug | Fixed in `file_ops/security.ex` |
| `C_REPL: mock dispatch / command state` | 18 | Test isolation / contract | Fixed/narrowed; REPL tests are active again |
| `C_API`, `C_LLM`, `C_CONFIG`, `C_MIGRATOR`, `D_OUTDATED` | 19 | Contract drift / stale tests | Fixed or updated in tests |

## Fixes included in the triage workstream

### Security and runtime fixes

- Restored the direct sensitive-path check in `CodePuppyControl.FileOps.Security.sensitive_path?/1`; the previous mangled comment accidentally hid `path_is_sensitive?(expanded) or`.
- Hardened `CodePuppyControl.Auth.ChatGptOAuth.load_stored_tokens/0` so missing files, invalid JSON, and non-map decoded data return `nil` instead of leaking unexpected shapes.
- Added a defensive REPL agent-catalogue fallback in `REPL.Loop` for tests/partial boot states where the primary catalogue lookup is unavailable.
- Adjusted scheduler history lookup for the current SQLite JSON behavior.
- Fixed `Concurrency.Limiter` timeout cleanup so timed-out waiters are removed instead of poisoning later release wakeups, and exposed a reset hook for test isolation.

### Test fixes and isolation improvements

- Added global `:triage_pending` exclusion in `test_helper.exs` as a future quarantine safety rail.
- Re-enabled REPL test modules by removing broad module tags and making `LoopTest` initialize the slash-command registry deterministically per test.
- Re-enabled `AddModelInteractiveTest` by giving it a per-test isolated models.dev fixture file instead of relying on the mutable shared `test/support/models_dev_parser_test_data.json` path.
- Re-enabled limiter, sessions controller, schema property, and most terminal-channel coverage after fixing deterministic flake sources (limiter waiter cleanup, sessions-controller sandbox ownership, and non-castable integer property generation).
- Fixed stdio/model-services subprocess harness coverage and removed the remaining transport-module quarantines.
- Fixed the terminal-channel PTY close teardown feedback loop and removed the remaining per-test quarantine.
- Updated stale assertions in OAuth, scheduler, model factory, migrator, create-file, and worker tests.

## Future quarantine policy

- Do not add broad module-level tags without recording the exact reason in bd and in the companion CSV.
- Prefer fixing deterministic contract drift over tagging.
- Any new `:triage_pending` tag must include a follow-up owner/issue in bd.
- If a new quarantine is added, run the fast suite both with and without `--include triage_pending` and document the result.

## Verification commands

```bash
cd elixir/code_puppy_control
mix test test/code_puppy_control/transport/stdio_service_test.exs --trace
mix test test/code_puppy_control/transport/model_services_rpc_test.exs --trace
mix test test/code_puppy_control/transport/stdio_service_test.exs test/code_puppy_control/transport/model_services_rpc_test.exs --trace
mix test test/code_puppy_control_web/channels/terminal_channel_test.exs --trace
mix test --include triage_pending --exclude slow --exclude integration --max-failures 20
```

Current result for the full fast-suite command with former quarantines included:

```text
9 doctests, 89 properties, 5184 tests, 0 failures (105 excluded)
```
