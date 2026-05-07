# CodePuppy Control Test Helper
#
# Integration tests:
# mix test --exclude integration # Skip integration tests (default)
# mix test --only integration # Run only integration tests
# mix test --exclude e2e # Skip E2E tests (default)
# mix test --only e2e # Run only E2E tests
# mix test # Run all tests
#
# E2E tests:
# mix test.e2e # Run E2E tests via custom task
# SKIP_E2E=1 mix test # Skip E2E tests
# E2E_TIMEOUT=60000 mix test.e2e # Override timeout (60s)

# .ex files in test/support are compiled automatically via elixirc_paths.
# Only use Code.require_file for .exs files that are not compiled.

# Support .ex files in test/support are automatically loaded via compilation
# This includes: test_reset.ex, stateful_case.ex, stdio_test_helper.ex

# Start parser registry for tests (: pure Elixir parsers)
# Registry may already be started by the application supervision tree
case CodePuppyControl.Parsing.ParserRegistry.start_link(
       name: CodePuppyControl.Parsing.ParserRegistry
     ) do
  {:ok, _registry} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Start callback registry for tests
case CodePuppyControl.Callbacks.Registry.start_link(name: CodePuppyControl.Callbacks.Registry) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Start provider registry for tests
case CodePuppyControl.ModelFactory.ProviderRegistry.start_link() do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

CodePuppyControl.Parsing.Parsers.register_all()

# Configure ExUnit with integration and E2E tests excluded by default.
# `:eval` tests are ALSO excluded unless RUN_EVALS=1 is set, mirroring the
# Python `evals/conftest.py` gate.
#
# `:packaged_cli` tests build the escript and probe the shipped artifact;
# they are deterministic and no-network but pay a `mix escript.build` cost
# (~5–10s) so they are excluded from the default fast suite.  Run via:
#
#     mix test --include packaged_cli
#     mix test --only packaged_cli
#     scripts/smoke-packaged.sh        # builds + runs the full packaged smoke
#
# `:property` tests (StreamData/ExUnitProperties) are NOT excluded from the
# default `mix test` run — they form part of the full suite.  The pre-push
# hook no longer runs tests (code-puppy-c1r); run `mix test` explicitly or
# rely on CI / release-gate.sh.  Property tests can be isolated via:
#
#     mix test --only property
#     mix test --include property   # when combined with other excludes
#
# Refs: code-puppy-63y, code_puppy-d7m, code-puppy-c1r
exclude_tags =
  if System.get_env("RUN_EVALS") == "1" do
    [:integration, :e2e, :skip, :triage_pending, :packaged_cli, :phase_c_e2e]
  else
    [:integration, :e2e, :skip, :eval, :triage_pending, :packaged_cli, :phase_c_e2e]
  end

# ---------------------------------------------------------------------------
# ExUnit concurrency: laptop-friendly defaults with profile support
# ---------------------------------------------------------------------------
#
# On a fanless M4 Air (10 schedulers), running all 10 cases simultaneously
# causes thermal throttling. These profiles let you pick a comfort level:
#
# PUP_TEST_PROFILE=gentle => ~3 cases (cool / quiet)
# PUP_TEST_PROFILE=balanced => ~6 cases (default, good trade-off)
# PUP_TEST_PROFILE=burst => ~9-10 cases (fast / CI-style)
#
# Override with an exact number:
# PUP_TEST_MAX_CASES=2 mix test
#
# Explicit CLI flags always win: --trace, --max-cases, --max-cases=N
# ---------------------------------------------------------------------------

ex_unit_opts = [
  exclude: exclude_tags,
  formatters: [ExUnit.CLIFormatter],
  timeout: 30_000
]

# Detect whether the user passed --trace or --max-cases on the command line.
# If so, we must NOT set max_cases — let ExUnit handle it.
cli_args = System.argv()

cli_overrides_max_cases =
  Enum.any?(cli_args, fn
    "--trace" -> true
    arg when is_binary(arg) -> String.starts_with?(arg, "--max-cases")
    _ -> false
  end)

# Read env var once — used in the cond below
env_max = System.get_env("PUP_TEST_MAX_CASES")

max_cases =
  cond do
    # 1. Explicit CLI flag → don't override, let ExUnit decide
    cli_overrides_max_cases ->
      nil

    # 2. Exact numeric override via env var
    env_max != nil and env_max != "" ->
      case Integer.parse(env_max) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end

    # 3. Profile-based heuristic (clamped to 1..schedulers to avoid
    # oversubscribing tiny machines/containers)
    true ->
      schedulers = System.schedulers_online()
      profile = System.get_env("PUP_TEST_PROFILE", "balanced")

      raw_max_cases =
        case profile do
          "gentle" -> max(div(schedulers, 3), 2)
          "balanced" -> max(round(schedulers * 0.6), 2)
          "burst" -> schedulers
          _ -> max(round(schedulers * 0.6), 2)
        end

      # Clamp to valid range: at least 1, at most schedulers
      raw_max_cases |> max(1) |> min(schedulers)
  end

ex_unit_opts =
  if max_cases do
    Keyword.put(ex_unit_opts, :max_cases, max_cases)
  else
    ex_unit_opts
  end

ExUnit.configure(ex_unit_opts)

# Use deterministic random for reproducible tests
:rand.seed(:exsss, {1, 2, 3})

ExUnit.start()
