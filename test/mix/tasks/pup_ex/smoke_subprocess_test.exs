defmodule Mix.Tasks.PupEx.SmokeSubprocessTest do
  @moduledoc """
  Subprocess-level regression for `mix pup_ex.smoke`.

  Verifies that the Mix task, when actually spawned as a child
  `mix` process (i.e. the way operators and CI run it), both:

    1. Exits 0 on the success JSON path; AND
    2. **Cleans up the tmp sandbox before halting.**

  Background — code_puppy-baa
  ----------------------------

  `Mix.Tasks.PupEx.Smoke.execute/1` originally called
  `System.halt/1` *inside* the `try` body, with sandbox teardown in
  the `after` block.  `System.halt/1` terminates the BEAM
  immediately, so `after` never ran and `pup_smoke_*/.code_puppy_ex/`
  directories piled up under `$TMPDIR`.

  This regression catches that defect by:

    * Setting `TMPDIR` to a controlled, deterministic test-owned
      directory.
    * Invoking the real `mix pup_ex.smoke --json` as a subprocess
      (in-process `Mix.Task.run/2` would not exercise
      `System.halt/1` and would happily run the `after` block).
    * Asserting the sandbox path reported in the JSON no longer
      exists on disk after the subprocess exits, and that no
      `pup_smoke_*` siblings were left behind under the controlled
      tmp root.

  We intentionally run the lightest phases (`parser`, `run_mode`,
  `sandbox`) — the cleanup invariant is task-shaped, not
  phase-shaped, and we do not want to pay the `one_shot` startup
  cost in a regression that exists to catch a 4-line bug.

  Refs: code_puppy-baa
  """

  use ExUnit.Case, async: false

  # Cold `mix` boot + compile check + app start can take a few
  # seconds on CI; give the case room without being silly about it.
  @moduletag timeout: 120_000

  @phases ["--phase", "parser", "--phase", "run_mode", "--phase", "sandbox"]

  describe "mix pup_ex.smoke (subprocess)" do
    setup do
      # __DIR__ = test/mix/tasks/pup_ex/  →  up 4 = project root
      project_root = Path.expand(Path.join(__DIR__, "../../../.."))

      unless File.exists?(Path.join(project_root, "mix.exs")) do
        flunk(
          "could not locate mix.exs from #{__DIR__} " <>
            "(resolved project_root=#{project_root})"
        )
      end

      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "pup_smoke_subproc_#{:erlang.unique_integer([:positive])}_#{System.system_time(:millisecond)}"
        )

      File.mkdir_p!(tmp_root)

      on_exit(fn ->
        # Belt-and-suspenders: the task should clean its own sandbox,
        # but always rm_rf the controlled root so test runs do not
        # accumulate noise on the developer's machine.
        File.rm_rf(tmp_root)
      end)

      {:ok, project_root: project_root, tmp_root: tmp_root}
    end

    test "success JSON path exits 0 and cleans up the sandbox", %{
      project_root: project_root,
      tmp_root: tmp_root
    } do
      args = ["pup_ex.smoke", "--json"] ++ @phases

      {output, exit_code} =
        System.cmd("mix", args,
          cd: project_root,
          env: [
            {"TMPDIR", tmp_root},
            # Share the test build dir so the subprocess does not
            # have to recompile from scratch.
            {"MIX_ENV", "test"},
            # (code_puppy-i1n) Give the subprocess its own SQLite DB.
            # The main test process holds an Ecto Sandbox lock on the
            # default test DB, so the subprocess would fail with
            # "database is locked" during its own application startup.
            # A unique DB per subprocess invocation avoids the lock
            # contention entirely.  The smoke test only needs the DB
            # to exist (for Repo startup); it does not query sessions.
            {"PUP_TEST_DB",
             Path.join(tmp_root, "smoke_subproc_#{:erlang.unique_integer([:positive])}.db")}
          ],
          # Keep stderr off stdout — Mix/Logger noise belongs there
          # and we want a clean stdout to parse as JSON.
          stderr_to_stdout: false
        )

      assert exit_code == 0, """
      mix pup_ex.smoke --json exited with #{exit_code}; expected 0.
      stdout was:
      #{output}
      """

      json_blob = extract_json_object(output)

      report =
        case Jason.decode(json_blob) do
          {:ok, decoded} ->
            decoded

          {:error, reason} ->
            flunk("""
            could not decode JSON from mix pup_ex.smoke output.
            reason: #{inspect(reason)}
            json_blob:
            #{json_blob}
            full stdout:
            #{output}
            """)
        end

      assert report["status"] == "pass", """
      expected JSON status \"pass\", got #{inspect(report["status"])}.
      report: #{json_blob}
      """

      sandbox_dir = report["sandbox_dir"]

      assert is_binary(sandbox_dir),
             "sandbox_dir was missing/non-string in JSON report: #{inspect(report)}"

      assert String.starts_with?(sandbox_dir, tmp_root), """
      sandbox_dir (#{sandbox_dir}) did not honour TMPDIR=#{tmp_root}.
      Likely cause: the smoke task is not using System.tmp_dir!() to
      pick the sandbox root, so this regression cannot reliably
      assert cleanup.
      """

      refute File.exists?(sandbox_dir), """
      sandbox_dir #{sandbox_dir} still exists on disk after the
      subprocess exited.  This is the code_puppy-baa regression:
      System.halt/1 is being called inside the try body, skipping
      the `after` block that should run Smoke.teardown_sandbox/2.
      """

      leftovers =
        tmp_root
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "pup_smoke_"))

      assert leftovers == [], """
      expected zero `pup_smoke_*` leftovers under #{tmp_root},
      found: #{inspect(leftovers)}.
      The smoke task halted before its sandbox teardown ran.
      """
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # `Mix.shell().info/1` writes the pretty-printed JSON object
  # produced by `Jason.encode!(..., pretty: true)` to stdout.  The
  # subprocess will *also* print Logger output (e.g. inline maps
  # like `%{api_calls: 2, ...}`) to the same stream, so a naive
  # greedy `{...}` regex would slurp Logger noise too.
  #
  # Pretty-printed JSON has a structural property we can lean on:
  # the outer `{` sits on a line by itself, and so does the outer
  # `}`.  We enumerate every (start, end) pair of such lines and
  # take the latest one that `Jason.decode/1` accepts as a map.
  # Latest-first because the smoke report is the LAST thing the
  # task prints; Logger noise comes earlier.
  defp extract_json_object(output) do
    lines = String.split(output, "\n", trim: false)

    starts = collect_indexes(lines, "{")
    ends = collect_indexes(lines, "}")

    pairs =
      for s <- starts, e <- ends, s < e, do: {s, e}

    # Largest end first, then largest start within: tries the
    # tail-most JSON object first.
    pairs = Enum.sort_by(pairs, fn {s, e} -> {-e, -s} end)

    block =
      Enum.find_value(pairs, fn {s, e} ->
        candidate = lines |> Enum.slice(s..e) |> Enum.join("\n")

        case Jason.decode(candidate) do
          {:ok, decoded} when is_map(decoded) -> candidate
          _ -> nil
        end
      end)

    if is_binary(block) do
      block
    else
      flunk("""
      no decodable pretty-printed JSON object found in mix pup_ex.smoke stdout.
      full stdout was:
      #{output}
      """)
    end
  end

  defp collect_indexes(lines, marker) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _idx} -> String.trim(line) == marker end)
    |> Enum.map(fn {_line, idx} -> idx end)
  end
end
