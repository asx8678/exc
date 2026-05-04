defmodule Mix.Tasks.PupEx.Smoke do
  @shortdoc "No-network local dogfood smoke for the Elixir CLI"

  @moduledoc """
  Run the Elixir CLI dogfood smoke suite.

  Exercises the CLI's argv parsing, run-mode routing, sandboxed
  config/session storage, and the one-shot prompt path with a
  deterministic mock LLM.  Makes **no network calls** and **never**
  touches the operator's real `~/.code_puppy_ex/` (or legacy
  `~/.code_puppy/`).

  Intended to be run before daily-driver use of the Elixir CLI:

      mix pup_ex.smoke

  ## Usage

      mix pup_ex.smoke                # run default phases (fast)
      mix pup_ex.smoke --json         # emit a JSON report
      mix pup_ex.smoke --phase parser # run only the parser phase
      mix pup_ex.smoke --phase parser --phase run_mode
      mix pup_ex.smoke --escript      # also probe the built escript
      mix pup_ex.smoke --burrito      # also probe the built Burrito binary
      mix pup_ex.smoke --escript --burrito --json
      mix pup_ex.smoke --no-python          # validate Python-free runtime
      mix pup_ex.smoke --no-python --escript # no-Python + escript probe

  ## Phases

  - `parser`    — argv parsing + help-text invariants
  - `run_mode`  — `CLI.resolve_run_mode/1` routes deterministically
  - `sandbox`   — `Paths.home_dir/0` resolves under the tmp sandbox
  - `one_shot`  — `OneShot.run/1` end-to-end with `Smoke.MockLLM`
  - `escript`   — opt-in via `--escript`; spawns `pup --version` and
                  `pup --help` against the built escript
  - `burrito`   — opt-in via `--burrito`; spawns the host-built
                  Burrito binary with `--version` and `--help`
                  (auto-skips if `burrito_out/<host>` is missing)

  ## No-Python mode

  When `--no-python` is passed, the smoke runner validates the
  Python-free runtime guarantee: in-process phases run with
  `PUP_RUNTIME=elixir`, and packaged probes (escript/burrito)
  are spawned with a sanitized `PATH` that excludes `python3`/
  `python`.  This proves the packaged CLI starts and shows
  help/version without Python installed.

  Refs: code-puppy-osy

  ## Exit codes

  - `0` — all selected phases passed (or were deliberately skipped)
  - `1` — at least one phase failed
  - `2` — invalid args to this Mix task

  ## Why this is a Mix task and not a runtime command

  The smoke suite is a pre-flight check operators run **before**
  delegating real work to the CLI.  It needs to set sandbox env vars
  before the OTP application starts, which is something only a Mix
  task wrapping the boot sequence can do reliably.

  Refs: code_puppy-baa, code_puppy-d7m
  """

  use Mix.Task

  alias CodePuppyControl.CLI.Smoke

  @switches [
    json: :boolean,
    phase: :keep,
    escript: :boolean,
    burrito: :boolean,
    no_python: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        execute(opts)

      {_opts, positional, []} ->
        Mix.shell().error(
          "mix pup_ex.smoke takes no positional arguments (got: #{inspect(positional)})"
        )

        usage()
        System.halt(2)

      {_opts, _, invalid} ->
        Mix.shell().error("invalid flag(s): #{inspect(invalid)}")
        usage()
        System.halt(2)
    end
  end

  defp execute(opts) do
    runner_opts = build_runner_opts(opts)

    # Set sandbox env vars BEFORE the OTP application starts so any
    # eager Paths.* resolution at boot lands inside the tmp sandbox
    # rather than against the real ~/.code_puppy_ex/.
    {sandbox, env_snapshot} = Smoke.setup_sandbox()

    # IMPORTANT (code_puppy-baa): `System.halt/1` terminates the BEAM
    # immediately and SKIPS `after` blocks.  Calling it inside the
    # try body leaks the tmp sandbox (`pup_smoke_*/.code_puppy_ex/`).
    #
    # Pattern:
    #   1. Compute exit_code inside try/rescue.
    #   2. Always run teardown in the `after` block (BEAM still alive).
    #   3. Halt OUTSIDE the try, once cleanup has guaranteed-run.
    exit_code =
      try do
        ensure_application_started()

        result = Smoke.run_phases(runner_opts, sandbox)

        output =
          if Keyword.get(opts, :json, false) do
            Smoke.format_json(result)
          else
            Smoke.format_human(result)
          end

        Mix.shell().info(output)
        Smoke.exit_code(result)
      rescue
        e ->
          Mix.shell().error(
            "mix pup_ex.smoke aborted: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          1
      after
        Smoke.teardown_sandbox(sandbox, env_snapshot)
      end

    System.halt(exit_code)
  end

  defp build_runner_opts(opts) do
    phases =
      opts
      |> Keyword.get_values(:phase)
      |> Enum.map(&normalize_phase/1)

    runner_opts = []

    runner_opts =
      if phases != [], do: Keyword.put(runner_opts, :phases, phases), else: runner_opts

    runner_opts =
      if Keyword.get(opts, :escript, false),
        do: Keyword.put(runner_opts, :escript, true),
        else: runner_opts

    runner_opts =
      if Keyword.get(opts, :burrito, false),
        do: Keyword.put(runner_opts, :burrito, true),
        else: runner_opts

    runner_opts =
      if Keyword.get(opts, :no_python, false),
        do: Keyword.put(runner_opts, :no_python, true),
        else: runner_opts

    runner_opts
  end

  defp normalize_phase(value) when is_binary(value) do
    case value do
      "parser" -> :parser
      "run_mode" -> :run_mode
      "run-mode" -> :run_mode
      "sandbox" -> :sandbox
      "one_shot" -> :one_shot
      "one-shot" -> :one_shot
      "escript" -> :escript
      "burrito" -> :burrito
      other -> raise_invalid_phase(other)
    end
  end

  defp normalize_phase(other), do: raise_invalid_phase(other)

  defp raise_invalid_phase(value) do
    Mix.shell().error(
      "unknown phase #{inspect(value)} — expected one of: " <>
        Enum.map_join(CodePuppyControl.CLI.Smoke.all_phases(), ", ", &Atom.to_string/1)
    )

    System.halt(2)
  end

  defp ensure_application_started do
    case Application.ensure_all_started(:code_puppy_control) do
      {:ok, _started} -> :ok
      {:error, {app, reason}} -> raise "failed to start #{app}: #{inspect(reason)}"
    end
  end

  defp usage do
    Mix.shell().info("""

    Usage:
      mix pup_ex.smoke [--json] [--phase NAME ...] [--escript] [--burrito] [--no-python]

    Phases (default if none given): #{Enum.map_join(Smoke.default_phases(), ", ", &Atom.to_string/1)}
    All phases:                     #{Enum.map_join(Smoke.all_phases(), ", ", &Atom.to_string/1)}
    """)
  end
end
