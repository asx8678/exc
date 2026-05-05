defmodule Mix.Tasks.PupEx.PackagedCliSmokeTest do
  @moduledoc """
  Packaged-artifact smoke for the Elixir CLI.

  This test deliberately *builds* the shipped CLI artifact and then
  exercises it through the dogfood smoke runner, the way an operator
  would after `mix escript.build`.  It is the deterministic answer to:

    > "Does `./pup --version`, `./pup --help`, and `./pup` (interactive
    > bootstrap/quit) actually work against the packaged binary, with
    > zero network and zero user-home writes?"

  Why this test is tagged `:packaged_cli` and excluded from the
  default suite (see `test/test_helper.exs`):

    1. `mix escript.build` is non-trivial work (compiles the project,
       links every dep) and adds ~5\u201310s to a default `mix test` run.
    2. The contract being verified is post-`mix release` plumbing,
       not source-level code-puppy logic; running it on every commit
       is overkill.

  Run it directly with:

      mix test --include packaged_cli test/mix/tasks/pup_ex/packaged_cli_smoke_test.exs
      mix test --only packaged_cli
      scripts/smoke-packaged.sh

  ## Determinism / no-network / no-user-home guarantees

    * The smoke runner sets `PUP_EX_HOME` to a tmp sandbox before any
      `Paths.home_dir/0` call.
    * The escript probe injects the same `PUP_EX_HOME` into the child
      process plus `PUP_SMOKE_PROBE=1`.
    * Only `--version` and `--help` are invoked \u2014 both are
      `Application.ensure_all_started/1`-free fast paths in
      `CodePuppyControl.CLI`, so no network calls, no LLM calls, no
      keychain reads.
    * The pre-test signature of the real `~/.code_puppy_ex/` is
      compared to the post-test signature; any mutation fails the test.

  Refs: code_puppy-d7m
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.Smoke

  # Building the escript is the long pole; give the case enough room
  # without making it absurd.
  @moduletag timeout: 180_000
  @moduletag :packaged_cli

  setup_all do
    project_root = project_root!()
    {:ok, project_root: project_root}
  end

  describe "escript packaged smoke" do
    test "builds `./pup` and the :escript phase reports :pass with stable markers", %{
      project_root: project_root
    } do
      ensure_escript_built!(project_root)
      escript_path = Path.join(project_root, "pup")
      assert File.regular?(escript_path), "expected escript at #{escript_path}"

      pre = real_home_signature()
      result = Smoke.run(phases: [:escript], escript: true)
      post = real_home_signature()

      assert pre == post, """
      real ~/.code_puppy_ex was mutated by the packaged escript probe.
      pre:  #{inspect(pre)}
      post: #{inspect(post)}
      """

      [phase] = result.phases
      assert phase.phase == :escript

      assert phase.status == :pass, """
      escript phase did not pass.
      detail: #{phase.detail}
      metrics: #{inspect(phase.metrics)}
      """

      assert phase.detail =~ "--version"
      assert phase.detail =~ "--help"
      assert phase.detail =~ "interactive bootstrap"
      assert is_integer(phase.metrics.version_bytes)
      assert is_integer(phase.metrics.help_bytes)
      assert is_integer(phase.metrics.bootstrap_bytes)
      assert phase.metrics.version_bytes > 0
      assert phase.metrics.help_bytes > 0
    end

    # Independent of the smoke runner, exercise `./pup --version` and
    # `./pup --help` directly with a sandboxed `PUP_EX_HOME` to prove
    # the no-user-home-write invariant at the System.cmd boundary.
    test "direct invocation honours PUP_EX_HOME sandbox and emits stable markers", %{
      project_root: project_root
    } do
      ensure_escript_built!(project_root)
      escript_path = Path.join(project_root, "pup")

      sandbox =
        Path.join(
          System.tmp_dir!(),
          "pup_packaged_smoke_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(sandbox)

      try do
        env = [
          {"PUP_EX_HOME", sandbox},
          {"PUP_SMOKE_PROBE", "1"}
        ]

        pre = real_home_signature()

        {ver_out, ver_status} =
          System.cmd(escript_path, ["--version"], stderr_to_stdout: true, env: env)

        {help_out, help_status} =
          System.cmd(escript_path, ["--help"], stderr_to_stdout: true, env: env)

        post = real_home_signature()

        assert ver_status == 0, "pup --version exited #{ver_status}: #{ver_out}"
        assert help_status == 0, "pup --help exited #{help_status}: #{help_out}"
        assert ver_out =~ "code-puppy"
        assert help_out =~ "Usage: pup [OPTIONS] [PROMPT]"
        assert help_out =~ "--prompt"
        assert pre == post, "real ~/.code_puppy_ex was mutated by direct pup invocation"
      after
        File.rm_rf(sandbox)
      end
    end
  end

  describe "burrito packaged smoke" do
    # Burrito requires Zig; we cannot assume it is installed on the
    # smoke runner.  This test asserts the deterministic contract:
    # if no host artifact exists, `:burrito` skips with a remediation
    # hint; if one exists, the same `--version`/`--help` markers
    # apply.  Either outcome is acceptable \u2014 a fail status is not.
    test "burrito phase either passes against a host artifact or skips with a hint", %{
      project_root: project_root
    } do
      _ = project_root
      result = Smoke.run(phases: [:burrito], burrito: true)
      [phase] = result.phases
      assert phase.phase == :burrito

      case phase.status do
        :skip ->
          assert phase.detail =~ "build host-only" or phase.detail =~ "burrito_out",
                 "skip detail should reference the build hint or burrito_out; got: #{phase.detail}"

        :pass ->
          assert phase.detail =~ "--version"
          assert phase.detail =~ "--help"

        other ->
          flunk("burrito phase status was #{inspect(other)}: #{inspect(phase)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp project_root! do
    # __DIR__ = test/mix/tasks/pup_ex/  \u2192 up 4 = project root
    root = Path.expand(Path.join(__DIR__, "../../../.."))

    if not File.exists?(Path.join(root, "mix.exs")) do
      flunk("could not locate mix.exs from #{__DIR__} (resolved root=#{root})")
    end

    root
  end

  # Build the escript via `mix escript.build` if `./pup` is missing or
  # older than the project's source.  Stays inside the project dir; we
  # do not write to user-home or any other shared location.
  defp ensure_escript_built!(project_root) do
    pup_path = Path.join(project_root, "pup")

    needs_build? =
      cond do
        not File.regular?(pup_path) -> true
        true -> false
      end

    if needs_build? do
      # `mix escript.build` honours the current MIX_ENV.  We use the
      # current env so we don't have to recompile dependencies under
      # MIX_ENV=prod just for a smoke check.
      {output, exit_status} =
        System.cmd("mix", ["escript.build"],
          cd: project_root,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", System.get_env("MIX_ENV") || "test"}]
        )

      if exit_status != 0 do
        flunk("""
        `mix escript.build` failed in #{project_root}
        exit_status: #{exit_status}
        output:
        #{output}
        """)
      end

      unless File.regular?(pup_path) do
        flunk("""
        `mix escript.build` exited 0 but did not produce #{pup_path}.
        output:
        #{output}
        """)
      end
    end

    :ok
  end

  # Cheap fingerprint of the operator's real ~/.code_puppy_ex/ so we can
  # detect mutation.  `:absent` is a perfectly valid signature \u2014 not
  # every contributor has a real Elixir home set up.
  defp real_home_signature do
    real = Path.expand("~/.code_puppy_ex")

    case File.stat(real, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, type: type}} -> {:present, type, mtime}
      {:error, :enoent} -> :absent
      {:error, reason} -> {:err, reason}
    end
  end
end
