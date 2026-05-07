defmodule CodePuppyControl.CLI.SmokeTest do
  @moduledoc """
  Tests for the dogfood smoke runner that backs `mix pup_ex.smoke`.

  Focus:

    * Each phase returns the expected status under happy + injected-fail
      conditions.
    * Sandbox setup does not leak into the real `~/.code_puppy_ex/`.
    * Format helpers emit the documented stable markers (`[ok]`,
      `[fail]`, `SMOKE PASS`, etc.) and produce parseable JSON.
    * `exit_code/1` maps result statuses to the documented codes.

  Refs: code_puppy-baa
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.Smoke
  alias CodePuppyControl.CLI.Smoke.MockLLM

  # ---------------------------------------------------------------------------
  # default_phases / all_phases
  # ---------------------------------------------------------------------------

  describe "default_phases/0 and all_phases/0" do
    test "default_phases is a strict subset of all_phases" do
      defaults = Smoke.default_phases()
      all = Smoke.all_phases()

      assert defaults -- all == [], "every default phase must appear in all_phases"
      assert :escript in all, "escript phase must exist (opt-in)"
      assert :escript not in defaults, "escript must be opt-in, not default"
    end

    test "default_phases contains the four core dogfood phases" do
      assert :parser in Smoke.default_phases()
      assert :run_mode in Smoke.default_phases()
      assert :sandbox in Smoke.default_phases()
      assert :one_shot in Smoke.default_phases()
    end

    # Refs: code_puppy-d7m
    test "burrito is an opt-in phase, not a default" do
      assert :burrito in Smoke.all_phases(), "burrito phase must exist (opt-in)"
      assert :burrito not in Smoke.default_phases(), "burrito must be opt-in, not default"
    end
  end

  # ---------------------------------------------------------------------------
  # parser phase
  # ---------------------------------------------------------------------------

  describe "phase: parser" do
    test "passes against the real Parser/CLI modules" do
      result = Smoke.run(phases: [:parser])

      [phase] = result.phases
      assert phase.phase == :parser
      assert phase.status == :pass, "parser phase should pass; got #{inspect(phase)}"
      assert phase.metrics.cases > 0
      refute Map.has_key?(phase.metrics, :failed)
    end
  end

  # ---------------------------------------------------------------------------
  # run_mode phase
  # ---------------------------------------------------------------------------

  describe "phase: run_mode" do
    test "passes against CLI.resolve_run_mode/1" do
      result = Smoke.run(phases: [:run_mode])

      [phase] = result.phases
      assert phase.phase == :run_mode
      assert phase.status == :pass
      assert phase.metrics.cases >= 5
    end
  end

  # ---------------------------------------------------------------------------
  # sandbox phase
  # ---------------------------------------------------------------------------

  describe "phase: sandbox" do
    test "PUP_EX_HOME points at the tmp sandbox during the run" do
      result = Smoke.run(phases: [:sandbox])

      [phase] = result.phases
      assert phase.status == :pass, "sandbox phase failed: #{phase.detail}"
      assert phase.metrics.checks >= 4

      # sandbox_dir is set in the result and must look like a tmp path
      assert is_binary(result.sandbox_dir)
      assert String.starts_with?(result.sandbox_dir, System.tmp_dir!())
    end

    test "sandbox dir is rm_rf'd after the run" do
      result = Smoke.run(phases: [:sandbox])
      refute File.dir?(result.sandbox_dir), "sandbox dir #{result.sandbox_dir} was not cleaned up"
    end

    test "PUP_EX_HOME / PUP_TEST_SESSION_ROOT are restored after teardown" do
      pre_pup_ex_home = System.get_env("PUP_EX_HOME")
      pre_test_root = System.get_env("PUP_TEST_SESSION_ROOT")
      pre_session_dir = System.get_env("PUP_SESSION_DIR")

      _ = Smoke.run(phases: [:sandbox])

      assert System.get_env("PUP_EX_HOME") == pre_pup_ex_home
      assert System.get_env("PUP_TEST_SESSION_ROOT") == pre_test_root
      assert System.get_env("PUP_SESSION_DIR") == pre_session_dir
    end

    test "real ~/.code_puppy_ex is not touched (existence + mtime preserved)" do
      real = Path.expand("~/.code_puppy_ex")
      pre = real_dir_signature(real)

      _ = Smoke.run(phases: [:sandbox])

      post = real_dir_signature(real)
      assert pre == post, "real ~/.code_puppy_ex was mutated by the smoke run"
    end
  end

  # ---------------------------------------------------------------------------
  # one_shot phase
  # ---------------------------------------------------------------------------

  describe "phase: one_shot" do
    setup do
      # Ensure the application is started for one_shot's full pipeline.
      {:ok, _} = Application.ensure_all_started(:code_puppy_control)
      :ok
    end

    test "succeeds end-to-end with the deterministic mock LLM" do
      result = Smoke.run(phases: [:one_shot])

      [phase] = result.phases
      assert phase.phase == :one_shot
      assert phase.status == :pass, "one_shot phase failed: #{inspect(phase)}"
      assert phase.metrics.invocation_count == 1
      assert phase.metrics.captured_bytes > 0
      assert is_binary(phase.metrics.session_id)
    end

    test ":repl_llm_module Application env is restored after the run" do
      pre = Application.get_env(:code_puppy_control, :repl_llm_module)
      _ = Smoke.run(phases: [:one_shot])
      post = Application.get_env(:code_puppy_control, :repl_llm_module)
      assert pre == post
    end

    test "MockLLM responds with the canned reply (overridable via PUP_SMOKE_MOCK_REPLY)" do
      original = System.get_env("PUP_SMOKE_MOCK_REPLY")

      try do
        System.put_env("PUP_SMOKE_MOCK_REPLY", "custom-smoke-marker-7777")
        assert MockLLM.canned_reply() == "custom-smoke-marker-7777"
      after
        case original do
          nil -> System.delete_env("PUP_SMOKE_MOCK_REPLY")
          v -> System.put_env("PUP_SMOKE_MOCK_REPLY", v)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # escript phase (opt-in)
  # ---------------------------------------------------------------------------

  describe "phase: escript" do
    test "skips when no built escript is found" do
      # In a normal test run we have NOT built `pup`, so this phase
      # should report :skip with a remediation hint, not :fail.
      result = Smoke.run(phases: [:escript], escript: true)

      [phase] = result.phases
      assert phase.phase == :escript

      case phase.status do
        :skip ->
          assert phase.detail =~ "no `pup` escript found"

        :pass ->
          # Surprise: someone built pup before running tests.  That's
          # fine — just assert the canonical pass detail shape produced
          # by the shared probe helper (refs: code_puppy-d7m).
          assert phase.detail =~ "--version"
          assert phase.detail =~ "--help"
          assert phase.detail =~ "interactive bootstrap"

        other ->
          flunk("unexpected escript phase status #{inspect(other)}: #{inspect(phase)}")
      end
    end

    test "is excluded from default phases" do
      result = Smoke.run([])
      escript_phase = Enum.find(result.phases, &(&1.phase == :escript))
      assert escript_phase == nil
    end
  end

  # ---------------------------------------------------------------------------
  # burrito phase (opt-in) — code_puppy-d7m
  # ---------------------------------------------------------------------------

  describe "phase: burrito" do
    # The default test environment never builds Burrito artifacts (Zig is
    # not part of `mix deps.get`), so the contract this exercises is the
    # deterministic skip path: if `burrito_out/` is missing or empty,
    # the phase reports `:skip` with a build hint — it does NOT fail and
    # does NOT crash the smoke runner.
    test "skips deterministically when no burrito artifact is present" do
      result = Smoke.run(phases: [:burrito], burrito: true)

      [phase] = result.phases
      assert phase.phase == :burrito

      case phase.status do
        :skip ->
          # All three probe_burrito_dir/2 skip paths must reference
          # either the directory, the artifact prefix, or the target
          # detection failure — plus a remediation hint.
          assert phase.detail =~ "burrito_out" or
                   phase.detail =~ "code_puppy_control_" or
                   phase.detail =~ "host-compatible",
                 "skip reason should reference burrito_out, the artifact prefix, " <>
                   "or host-compatible target detection; got: #{phase.detail}"

          assert phase.detail =~ "build host-only",
                 "skip reason should give a remediation hint; got: #{phase.detail}"

        :pass ->
          # If burrito_out happens to exist with a host artifact (e.g. a
          # developer ran `scripts/build-burrito.sh --host-only` before
          # tests), the phase still has to honour its contract: pass
          # markers must be stable.
          assert phase.detail =~ "--version"
          assert phase.detail =~ "--help"
          assert phase.detail =~ "interactive bootstrap"

        other ->
          flunk("unexpected burrito phase status #{inspect(other)}: #{inspect(phase)}")
      end
    end

    test "is excluded from default phases" do
      result = Smoke.run([])
      burrito_phase = Enum.find(result.phases, &(&1.phase == :burrito))
      assert burrito_phase == nil
    end

    # Sanity check on the runner-level opt: requesting `:burrito` via
    # the keyword opt should produce a phase entry, identical to passing
    # it via `:phases`.
    test "burrito: true keyword opt appends the phase" do
      result = Smoke.run(burrito: true, phases: [:parser])
      assert Enum.any?(result.phases, &(&1.phase == :burrito))
      assert Enum.any?(result.phases, &(&1.phase == :parser))
    end
  end

  # ---------------------------------------------------------------------------
  # aggregate status / exit_code
  # ---------------------------------------------------------------------------

  describe "status aggregation" do
    test "all-pass result aggregates to :pass and exit_code 0" do
      result = Smoke.run(phases: [:parser, :run_mode])

      assert result.status == :pass
      assert Smoke.exit_code(result) == 0
    end

    test "all-skip result aggregates to :skip and exit_code 0" do
      # synthesise an all-skip result; the runner won't naturally produce
      # one without :one_shot being skipped, so we fabricate it for the
      # exit_code mapping.
      synthetic = %{
        status: :skip,
        phases: [%{phase: :escript, status: :skip, detail: "skipped", metrics: %{}}],
        sandbox_dir: nil,
        duration_ms: 0
      }

      assert Smoke.exit_code(synthetic) == 0
    end

    test "any-fail result maps to exit_code 1" do
      synthetic = %{
        status: :fail,
        phases: [%{phase: :parser, status: :fail, detail: "boom", metrics: %{}}],
        sandbox_dir: nil,
        duration_ms: 0
      }

      assert Smoke.exit_code(synthetic) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # format_human / format_json
  # ---------------------------------------------------------------------------

  describe "format_human/1" do
    test "uses the documented stable markers" do
      result = Smoke.run(phases: [:parser, :run_mode])
      text = Smoke.format_human(result)

      assert text =~ "pup-ex smoke"
      assert text =~ "[ok]"
      assert text =~ "SMOKE PASS"
    end

    test "labels failures with [fail] and SMOKE FAIL" do
      synthetic = %{
        status: :fail,
        phases: [
          %{phase: :parser, status: :pass, detail: "ok", metrics: %{}},
          %{phase: :run_mode, status: :fail, detail: "broken", metrics: %{}}
        ],
        sandbox_dir: "/tmp/sb",
        duration_ms: 12
      }

      text = Smoke.format_human(synthetic)
      assert text =~ "[ok] parser"
      assert text =~ "[fail] run_mode"
      assert text =~ "SMOKE FAIL"
    end
  end

  describe "format_json/1" do
    test "emits valid JSON with the documented keys" do
      result = Smoke.run(phases: [:parser])
      json = Smoke.format_json(result)

      decoded = Jason.decode!(json)
      assert decoded["status"] == "pass"
      assert is_integer(decoded["duration_ms"])
      assert is_list(decoded["phases"])
      assert hd(decoded["phases"])["phase"] == "parser"
      assert hd(decoded["phases"])["status"] == "pass"
    end

    test "JSON is stable enough for harness consumption" do
      synthetic = %{
        status: :fail,
        phases: [
          %{phase: :sandbox, status: :fail, detail: "boom", metrics: %{checks: 5, failed: 1}}
        ],
        sandbox_dir: "/tmp/sandbox-x",
        duration_ms: 42
      }

      decoded = synthetic |> Smoke.format_json() |> Jason.decode!()
      assert decoded["status"] == "fail"
      assert decoded["sandbox_dir"] == "/tmp/sandbox-x"
      assert hd(decoded["phases"])["metrics"]["checks"] == 5
    end
  end

  # ---------------------------------------------------------------------------
  # full default-phases run (smoke meta-test)
  # ---------------------------------------------------------------------------

  describe "default-phases run" do
    setup do
      {:ok, _} = Application.ensure_all_started(:code_puppy_control)
      :ok
    end

    test "default invocation passes all four phases" do
      result = Smoke.run([])

      assert result.status == :pass, """
      Smoke.run([]) did not pass.
      result: #{inspect(result, pretty: true)}
      """

      phases_seen = Enum.map(result.phases, & &1.phase)

      for expected <- [:parser, :run_mode, :sandbox, :one_shot] do
        assert expected in phases_seen, "expected phase #{expected} to run"
      end

      # sandbox_dir is set, then cleaned up
      assert is_binary(result.sandbox_dir)
      refute File.dir?(result.sandbox_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # MockLLM contract
  # ---------------------------------------------------------------------------

  describe "Smoke.MockLLM" do
    test "implements Agent.LLM behaviour" do
      # `function_exported?/3` returns false on a not-yet-loaded module;
      # ensure the module is loaded before introspecting (test seed order
      # otherwise leaves this depending on whether an earlier test happened
      # to invoke MockLLM first).
      assert Code.ensure_loaded?(MockLLM)
      assert function_exported?(MockLLM, :stream_chat, 4)
    end

    test "reset/0 zeroes the invocation counter" do
      MockLLM.reset()
      assert MockLLM.invocation_count() == 0

      collector = self()

      MockLLM.stream_chat([], [], [model: "stub"], fn event ->
        send(collector, {:event, event})
      end)

      assert MockLLM.invocation_count() == 1
      assert_received {:event, {:text, _}}
      assert_received {:event, {:done, :complete}}

      MockLLM.reset()
      assert MockLLM.invocation_count() == 0
    end

    test "last_opts/0 returns the last keyword opts the mock saw" do
      MockLLM.reset()

      MockLLM.stream_chat([], [], [model: "claude-sonnet-x", system_prompt: "y"], fn _ -> :ok end)

      opts = MockLLM.last_opts()
      assert is_list(opts)
      assert Keyword.get(opts, :model) == "claude-sonnet-x"
    end

    test "canned_reply/0 honours PUP_SMOKE_MOCK_REPLY override" do
      prev = System.get_env("PUP_SMOKE_MOCK_REPLY")

      try do
        System.put_env("PUP_SMOKE_MOCK_REPLY", "alt-canned-7")
        assert MockLLM.canned_reply() == "alt-canned-7"

        # Empty string falls back to default
        System.put_env("PUP_SMOKE_MOCK_REPLY", "")
        assert MockLLM.canned_reply() == "smoke ok — no network"
      after
        case prev do
          nil -> System.delete_env("PUP_SMOKE_MOCK_REPLY")
          v -> System.put_env("PUP_SMOKE_MOCK_REPLY", v)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # No-Python mode (code-puppy-osy)
  # ---------------------------------------------------------------------------

  describe "no-python mode" do
    setup do
      {:ok, _} = Application.ensure_all_started(:code_puppy_control)
      :ok
    end

    test "passes in-process phases with no_python: true" do
      result = Smoke.run(phases: [:parser, :run_mode, :sandbox, :one_shot], no_python: true)

      assert result.status == :pass, """
      Smoke.run(no_python: true) did not pass.
      result: #{inspect(result, pretty: true)}
      """
    end

    test "no_python_packaged_env includes PUP_SMOKE_PROBE" do
      env = Smoke.no_python_packaged_env()
      assert List.keyfind(env, "PUP_SMOKE_PROBE", 0) == {"PUP_SMOKE_PROBE", "1"}
    end

    test "no_python_packaged_env filters python from PATH" do
      env = Smoke.no_python_packaged_env(sandbox_dir: nil)

      {"PATH", path} = List.keyfind(env, "PATH", 0)

      # PATH should NOT contain directories with python3/python
      path_dirs = String.split(path, ":")

      for dir <- path_dirs do
        refute File.exists?(Path.join(dir, "python3")),
               "no_python PATH should not include python3 in #{dir}"

        refute File.exists?(Path.join(dir, "python")),
               "no_python PATH should not include python in #{dir}"
      end
    end

    test "no_python mode does not corrupt env when a phase fails" do
      # Pass an unknown phase that will produce a :fail result.
      # The smoke runner should still complete without crashing.
      result =
        Smoke.run_phases([no_python: true, phases: [:unknown_phase_xyz]], %{
          dir: "/tmp/fake_sandbox"
        })

      # Result should be a map with :fail status
      assert is_map(result)
      assert result.status == :fail
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A cheap fingerprint of the real ~/.code_puppy_ex directory so we can
  # detect whether the smoke run mutated it.  We deliberately do NOT
  # create the dir if it doesn't exist (operators may not have a real
  # home yet) — `:absent` is a perfectly valid fingerprint.
  defp real_dir_signature(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, type: type}} ->
        {:present, type, mtime}

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:err, reason}
    end
  end
end
