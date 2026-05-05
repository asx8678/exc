defmodule CodePuppyControl.CLI.Smoke do
  @moduledoc """
  No-network local dogfood smoke runner for the Elixir CLI.

  Exercises the CLI's most fragile junctions — argv parsing, run-mode
  routing, sandboxed config/session, and the one-shot prompt path with
  a mock LLM — without making real API calls or touching the operator's
  real `~/.code_puppy_ex/` (or legacy `~/.code_puppy/`) home.

  Designed to be the thing a developer runs before claiming the Elixir
  CLI is dogfood-ready for the day.  Cheap.  Deterministic.  Loud
  about the source of every check.

  ## Usage

      iex> CodePuppyControl.CLI.Smoke.run([])
      %{status: :pass, phases: [...], sandbox_dir: "/tmp/pup_smoke_..."}

  The Mix task `mix pup_ex.smoke` is the supported entry point — this
  module returns a plain map so callers (Mix task, tests, plugins) can
  format and exit on their own terms.

  ## Phases

  Each phase returns a `t:phase_result/0` map with `:phase`, `:status`,
  `:detail`, `:metrics`.  Status is one of `:pass`, `:fail`, `:skip`.

  - `:parser` — `Parser.parse/1` returns expected tags for `--help`,
    `--version`, valid args, and invalid args.
  - `:run_mode` — `CLI.resolve_run_mode/1` routes correctly without
    side effects.
  - `:sandbox` — `Paths.home_dir/0` resolves under the sandbox tmp,
    not the real home; legacy home untouched.
  - `:one_shot` — `OneShot.run/1` succeeds end-to-end with the mock
    LLM, persists user+assistant messages into the sandbox, and the
    mock LLM was invoked exactly once.
  - `:escript` — *opt-in via `escript: true`*; spawns the built
    `pup` escript with `--version` and `--help` and asserts exit 0 +
    stable markers, then also pipes `/quit` into the escript to
    validate that interactive startup completes without erlexec
    crashes, missing ETS tables, or dead supervisors. Skipped
    automatically when the escript is missing.
  - `:burrito` — *opt-in via `burrito: true`*; locates a host-built
    Burrito binary under `burrito_out/` and runs the same
    `--version` + `--help` + interactive bootstrap probes.  Skipped
    automatically when no artifact is present (Burrito requires Zig
    and is not built by default — see `scripts/build-burrito.sh
    --host-only` and `scripts/smoke-packaged.sh --with-burrito`).

  ## No-Python mode

  When `no_python: true` is passed, the smoke runner validates that
  the CLI works without Python installed:

    - Sets `PUP_RUNTIME=elixir` for in-process phases so the executor
      boundary selects the Elixir-native executor.
    - For packaged probes (escript/burrito), sanitizes `PATH` to
      exclude `python3`/`python` and passes `PUP_RUNTIME=elixir`
      plus `PUP_SMOKE_PROBE=1` in the child environment.
    - Deletes/avoids `PUP_PYTHON_WORKER_SCRIPT` and legacy
      `PYTHON_WORKER_SCRIPT` in the probe environment.

  This proves the Python-free runtime guarantee (code-puppy-osy).

  Phase implementations live in `CodePuppyControl.CLI.Smoke.Phases`
  to keep this module under the 600-line cap.

  ## Options

    * `:phases` — `[atom()]` subset to run; defaults to `default_phases/0`.
    * `:escript` — `boolean()`; if `true`, also run the `:escript` phase
      (off by default — base smoke is pure-Elixir and fast).
    * `:burrito` — `boolean()`; if `true`, also run the `:burrito` phase
      (off by default; deterministically skips when no artifact is
      available so CI without a Zig toolchain stays green).
    * `:no_python` — `boolean()`; if `true`, run all phases with a
      sanitized PATH that excludes `python3`/`python` and set
      `PUP_RUNTIME=elixir` to validate the Python-free runtime
      guarantee (off by default; see code-puppy-osy).

  ## Determinism guarantees

  The Smoke runner:

    1. Sets `PUP_EX_HOME` to a unique tmp directory before any
       `Paths.*` call.
    2. Sets `PUP_TEST_SESSION_ROOT` and `PUP_SESSION_DIR` and flips
       the `:allow_test_session_root` Application env so
       `SessionStorage.validate_storage_dir!/1` accepts the sandbox.
    3. Injects `CodePuppyControl.CLI.Smoke.MockLLM` via the
       `:repl_llm_module` Application env for the duration of the
       one-shot phase.
    4. On teardown, restores every snapshotted env value and rm_rf's
       the sandbox.  Real `~/.code_puppy_ex/` is left untouched.

  Refs: code_puppy-baa, code_puppy-d7m
  """

  alias CodePuppyControl.CLI.Smoke.Phases

  require Logger

  @type status :: :pass | :fail | :skip
  @type phase_name :: :parser | :run_mode | :sandbox | :one_shot | :escript | :burrito
  @type phase_result :: %{
          phase: phase_name,
          status: status,
          detail: String.t(),
          metrics: map()
        }

  @type result :: %{
          status: status,
          phases: [phase_result()],
          sandbox_dir: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @default_phases [:parser, :run_mode, :sandbox, :one_shot]
  @optional_phases [:escript, :burrito]
  @all_phases @default_phases ++ @optional_phases

  @doc "Phases run when no `:phases` option is given."
  @spec default_phases() :: [phase_name()]
  def default_phases, do: @default_phases

  @doc "Every recognised phase, including opt-in ones."
  @spec all_phases() :: [phase_name()]
  def all_phases, do: @all_phases

  # ── Public entry points ───────────────────────────────────────────────

  @doc """
  Run the smoke suite (full lifecycle: setup → phases → teardown).

  Returns a result map.  Never calls `System.halt/1`.  Tests use this
  entry point because the application is already started for them.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    {sandbox, snapshot} = setup_sandbox()

    try do
      run_phases(opts, sandbox)
    after
      teardown_sandbox(sandbox, snapshot)
    end
  end

  @doc """
  Run the smoke phases against an **already-prepared** sandbox.

  The Mix task uses this so it can `setup_sandbox/0` first, start the
  OTP application, run the phases, and only then `teardown_sandbox/2`.
  Tests should call `run/1` instead, which handles the full lifecycle.

  Returns the same shape as `run/1`.
  """
  @spec run_phases(keyword(), map()) :: result()
  def run_phases(opts, sandbox) when is_map(sandbox) do
    no_python = Keyword.get(opts, :no_python, false)

    # When no_python is enabled, set PUP_RUNTIME=elixir for in-process
    # phases so the executor boundary selects the Elixir executor.
    runtime_snapshot = if no_python, do: save_no_python_env(), else: nil

    if no_python do
      apply_no_python_env()
    end

    started_at = System.monotonic_time(:millisecond)

    requested_phases = resolve_phases(opts)

    results =
      try do
        Enum.map(requested_phases, &run_phase(&1, sandbox, opts))
      after
        # Always restore PUP_RUNTIME / Python env vars even if a phase
        # raises unexpectedly, so the test/app environment does not leak.
        if no_python and runtime_snapshot do
          restore_no_python_env(runtime_snapshot)
        end
      end

    duration = System.monotonic_time(:millisecond) - started_at

    %{
      status: aggregate_status(results),
      phases: results,
      sandbox_dir: sandbox.dir,
      duration_ms: duration
    }
  end

  defp resolve_phases(opts) do
    requested = Keyword.get(opts, :phases) || @default_phases

    requested
    |> maybe_append(:escript, Keyword.get(opts, :escript, false))
    |> maybe_append(:burrito, Keyword.get(opts, :burrito, false))
  end

  defp maybe_append(list, _phase, false), do: list

  defp maybe_append(list, phase, true) do
    if phase in list, do: list, else: list ++ [phase]
  end

  defp run_phase(:parser, _sandbox, _opts), do: Phases.parser()
  defp run_phase(:run_mode, _sandbox, _opts), do: Phases.run_mode()
  defp run_phase(:sandbox, sandbox, _opts), do: Phases.sandbox(sandbox)
  defp run_phase(:one_shot, sandbox, _opts), do: Phases.one_shot(sandbox)

  defp run_phase(:escript, sandbox, opts),
    do: Phases.escript(no_python: Keyword.get(opts, :no_python, false), sandbox_dir: sandbox.dir)

  defp run_phase(:burrito, sandbox, opts),
    do: Phases.burrito(no_python: Keyword.get(opts, :no_python, false), sandbox_dir: sandbox.dir)

  defp run_phase(other, _sandbox, _opts) do
    %{
      phase: other,
      status: :fail,
      detail: "unknown phase: #{inspect(other)}",
      metrics: %{}
    }
  end

  defp aggregate_status(phases) do
    statuses = Enum.map(phases, & &1.status)

    cond do
      Enum.any?(statuses, &(&1 == :fail)) -> :fail
      Enum.all?(statuses, &(&1 == :skip)) -> :skip
      true -> :pass
    end
  end

  # ── Formatters and exit code ──────────────────────────────────────────

  @doc """
  Format a result map as a human-readable report (with ANSI-free
  status icons so output stays grep-friendly).

  Stable markers used by the smoke harness:

    * `[ok]`, `[fail]`, `[skip]` — per-phase status
    * `SMOKE PASS`, `SMOKE FAIL` — overall verdict line
  """
  @spec format_human(result()) :: String.t()
  def format_human(%{status: status, phases: phases, sandbox_dir: dir, duration_ms: ms}) do
    header = "🐶 pup-ex smoke — no-network dogfood (#{ms} ms)"

    sandbox_line =
      if dir, do: "  sandbox: #{dir} (cleaned up)", else: "  sandbox: (none)"

    phase_lines = Enum.map(phases, &format_phase_human/1)

    summary =
      case status do
        :pass -> "SMOKE PASS — all phases ok"
        :fail -> "SMOKE FAIL — at least one phase failed"
        :skip -> "SMOKE SKIP — every phase skipped"
      end

    Enum.join([header, sandbox_line, "" | phase_lines] ++ ["", summary], "\n")
  end

  @doc """
  Format a result map as a JSON object.

  Stable schema:

      {
        "status": "pass" | "fail" | "skip",
        "duration_ms": integer,
        "sandbox_dir": "...",   // never the real ~/.code_puppy_ex
        "phases": [
          {"phase": "parser", "status": "pass", "detail": "...", "metrics": {...}},
          ...
        ]
      }
  """
  @spec format_json(result()) :: String.t()
  def format_json(result) do
    Jason.encode!(
      %{
        status: result.status,
        duration_ms: result.duration_ms,
        sandbox_dir: result.sandbox_dir,
        phases:
          Enum.map(result.phases, fn phase ->
            %{
              phase: phase.phase,
              status: phase.status,
              detail: phase.detail,
              metrics: phase.metrics
            }
          end)
      },
      pretty: true
    )
  end

  @doc """
  Maps a result to a process exit code.

  - `0` — every phase passed (or was deliberately skipped)
  - `1` — at least one phase failed
  """
  @spec exit_code(result()) :: 0 | 1
  def exit_code(%{status: :pass}), do: 0
  def exit_code(%{status: :skip}), do: 0
  def exit_code(%{status: :fail}), do: 1

  defp format_phase_human(%{phase: phase, status: status, detail: detail}) do
    tag =
      case status do
        :pass -> "[ok]"
        :fail -> "[fail]"
        :skip -> "[skip]"
      end

    "  #{tag} #{phase} — #{detail}"
  end

  # ── Sandbox setup / teardown ──────────────────────────────────────────

  @doc """
  Create a unique tmp sandbox and switch the relevant env vars + the
  `:allow_test_session_root` Application env over to it.

  Returns `{sandbox_handle, snapshot}` — pass both back to
  `teardown_sandbox/2` to restore the prior environment.
  """
  @spec setup_sandbox() :: {map(), map()}
  def setup_sandbox do
    uniq = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    tmp_root = Path.join(System.tmp_dir!(), "pup_smoke_#{uniq}")
    sandbox_ex = Path.join(tmp_root, ".code_puppy_ex")
    sandbox_sessions = Path.join(sandbox_ex, "sessions")
    File.mkdir_p!(sandbox_sessions)

    snapshot = %{
      pup_ex_home: System.get_env("PUP_EX_HOME"),
      pup_test_session_root: System.get_env("PUP_TEST_SESSION_ROOT"),
      pup_session_dir: System.get_env("PUP_SESSION_DIR"),
      allow_test_session_root:
        Application.get_env(:code_puppy_control, :allow_test_session_root, false),
      repl_llm_module: Application.get_env(:code_puppy_control, :repl_llm_module)
    }

    System.put_env("PUP_EX_HOME", sandbox_ex)
    System.put_env("PUP_TEST_SESSION_ROOT", sandbox_ex)
    System.put_env("PUP_SESSION_DIR", sandbox_sessions)
    Application.put_env(:code_puppy_control, :allow_test_session_root, true)

    {%{dir: sandbox_ex, root: tmp_root, sessions: sandbox_sessions}, snapshot}
  end

  @doc """
  Restore the env / Application env values captured at `setup_sandbox/0`
  time and `rm_rf` the sandbox tmp tree.
  """
  @spec teardown_sandbox(map(), map()) :: :ok
  def teardown_sandbox(sandbox, snapshot) do
    # 1. Drain pending async session saves so they don't write to a
    #    deleted directory or read stale env vars.
    Process.sleep(200)

    # 2. Restore env vars in the order opposite of setup.
    restore_env("PUP_SESSION_DIR", snapshot.pup_session_dir)
    restore_env("PUP_TEST_SESSION_ROOT", snapshot.pup_test_session_root)
    restore_env("PUP_EX_HOME", snapshot.pup_ex_home)

    # 3. Restore Application env values.
    Application.put_env(
      :code_puppy_control,
      :allow_test_session_root,
      snapshot.allow_test_session_root
    )

    case snapshot.repl_llm_module do
      nil -> Application.delete_env(:code_puppy_control, :repl_llm_module)
      mod -> Application.put_env(:code_puppy_control, :repl_llm_module, mod)
    end

    # 4. Best-effort cleanup of the sandbox directory.
    case File.rm_rf(sandbox.root) do
      {:ok, _} -> :ok
      {:error, reason, _} -> Logger.debug("smoke teardown rm_rf: #{inspect(reason)}")
    end

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  # ── No-Python env helpers ──────────────────────────────────────────
  #
  # When --no-python is active, we set PUP_RUNTIME=elixir for in-process
  # phases and clean up Python-related env vars so the executor boundary
  # selects the Elixir-native executor.  For packaged CLI probes,
  # we also sanitize PATH in the child environment (see Phases).

  @pup_runtime_env "PUP_RUNTIME"
  @pup_python_worker_env "PUP_PYTHON_WORKER_SCRIPT"
  @legacy_python_worker_env "PYTHON_WORKER_SCRIPT"

  defp save_no_python_env do
    %{
      pup_runtime: System.get_env(@pup_runtime_env),
      pup_python_worker: System.get_env(@pup_python_worker_env),
      legacy_python_worker: System.get_env(@legacy_python_worker_env)
    }
  end

  defp apply_no_python_env do
    System.put_env(@pup_runtime_env, "elixir")
    System.delete_env(@pup_python_worker_env)
    System.delete_env(@legacy_python_worker_env)
    :ok
  end

  defp restore_no_python_env(snapshot) do
    restore_env(@pup_runtime_env, snapshot.pup_runtime)
    restore_env(@pup_python_worker_env, snapshot.pup_python_worker)
    restore_env(@legacy_python_worker_env, snapshot.legacy_python_worker)
    :ok
  end

  @doc """
  Build a sanitized environment map for packaged CLI probes in
  no-Python mode.

  Removes directories containing `python3`/`python` from PATH and
  adds `PUP_RUNTIME=elixir`, `PUP_SMOKE_PROBE=1`, a sandboxed
  `PUP_EX_HOME`, and unsets any `PUP_PYTHON_WORKER_SCRIPT` /
  `PYTHON_WORKER_SCRIPT` entries by setting them to `nil` (which
  `System.cmd/3` interprets as "unset in child process").

  Unlike the previous implementation that replaced PATH with a tiny
  directory containing only `sh`, this version filters python from
  the system PATH while preserving all other tools (erl, escript,
  etc.) needed for escript and Burrito execution.
  """
  @spec no_python_packaged_env(keyword()) :: list({String.t(), String.t() | nil})
  def no_python_packaged_env(_opts \\ []) do
    # For escript/burrito probes, we need the full OTP toolchain on PATH
    # (erl, escript, etc.) but must exclude python3/python.  Filter
    # python from the system PATH rather than using a tiny sanitized
    # directory which only has sh — that approach broke escript probes
    # which need erl and escript to be available.
    filtered_path = filter_python_from_path()

    [
      {"PATH", filtered_path},
      {"PUP_EX_HOME", System.get_env("PUP_EX_HOME") || ""},
      {"PUP_SMOKE_PROBE", "1"},
      {"PUP_RUNTIME", "elixir"},
      # nil values are interpreted by System.cmd/3 as "unset in
      # child process", so the packaged CLI never sees a stale
      # or empty-string path to a Python worker script.
      {"PUP_PYTHON_WORKER_SCRIPT", nil},
      {"PYTHON_WORKER_SCRIPT", nil}
    ]
  end

  # Filter python3/python from the system PATH by removing directories
  # that contain a python3 or python executable.  This preserves all
  # other tools (erl, escript, sh, etc.) while ensuring the packaged
  # CLI can't accidentally use Python.
  defp filter_python_from_path do
    system_path = System.get_env("PATH") || ""

    system_path
    |> String.split(":")
    |> Enum.reject(fn dir ->
      # Reject directories that contain python3 or python executables
      File.exists?(Path.join(dir, "python3")) or
        File.exists?(Path.join(dir, "python"))
    end)
    |> Enum.join(":")
  end
end
