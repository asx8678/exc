defmodule CodePuppyControl.CLI.Smoke.BurritoArtifactTest do
  @moduledoc """
  Isolated regression test for the Burrito-artifact selector in
  `CodePuppyControl.CLI.Smoke.Phases`.

  The contract being locked in (regression code_puppy-d7m):

    * `find_burrito_artifact/0` MUST NOT fall back to an arbitrary
      `burrito_out/code_puppy_control_*` regular file.  Probing a
      cross-compiled sibling that cannot exec on the smoke host produces
      a confusing `:fail` (or, on Linux trying to exec a Mach-O, a
      hang) when the correct outcome is `:skip` with a remediation hint.

    * Only artifacts in `host_compatible_targets/0` are considered
      runnable.  If `burrito_out/` exists but contains only stale or
      cross-compiled siblings, the phase MUST skip cleanly.

    * Linux glibc hosts MAY accept a statically-linked musl artifact
      as a secondary fallback; pure-musl hosts (Alpine) accept ONLY
      the musl artifact.

  These tests exercise `Phases.probe_burrito_dir/2` directly with a
  synthetic `burrito_out/` so they are deterministic on every CI host
  and never depend on whether the real project has Burrito artifacts
  built.

  Refs: code_puppy-d7m
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.CLI.Smoke.Phases

  # Factory for a unique tmp `burrito_out/` populated with whatever
  # fake artifact filenames the caller wants.  We deliberately write
  # tiny payloads (not executables) — the selector must care about
  # name + regular-file-ness, never about exec bits, and must NEVER
  # actually try to run these files.
  defp setup_burrito_out(filenames, ctx) do
    tmp = Path.join(System.tmp_dir!(), "pup_burrito_d7m_#{ctx}_#{unique()}")
    burrito_out = Path.join(tmp, "burrito_out")
    File.mkdir_p!(burrito_out)

    for name <- filenames do
      File.write!(Path.join(burrito_out, name), "fake-burrito-payload-#{name}")
    end

    on_exit(fn -> File.rm_rf(tmp) end)
    burrito_out
  end

  defp unique, do: Integer.to_string(:erlang.unique_integer([:positive]))

  describe "probe_burrito_dir/2" do
    test "skips with a hint when burrito_out/ does not exist" do
      missing_dir =
        Path.join(System.tmp_dir!(), "pup_burrito_d7m_missing_#{unique()}")

      refute File.exists?(missing_dir)

      assert {:skip, reason, metrics} =
               Phases.probe_burrito_dir(missing_dir, ["macos_arm64"])

      assert reason =~ "no `burrito_out/` directory"
      assert reason =~ "build host-only"
      assert metrics.burrito_dir == missing_dir
    end

    test "skips with a hint when host detection produced an empty candidate list" do
      burrito_out = setup_burrito_out(["code_puppy_control_macos_arm64"], "empty_cands")

      assert {:skip, reason, metrics} =
               Phases.probe_burrito_dir(burrito_out, [])

      assert reason =~ "could not detect a host-compatible Burrito target"
      assert reason =~ "build host-only"
      assert metrics.burrito_dir == burrito_out
      assert metrics.candidates == []
    end

    # The headline regression: this is exactly the failure the shepherd
    # flagged.  `burrito_out/` exists, contains only NON-host artifacts
    # (e.g. a stale linux_x86_64 build on a macOS smoke runner), and the
    # OLD behaviour would happily pick it up via `list_any_burrito_binary/1`
    # and then either fail or hang trying to exec it.  The new contract
    # requires :skip with a clear remediation hint.
    test "skips when burrito_out/ contains ONLY non-host / stale artifacts (regression code_puppy-d7m)" do
      # Plant a Linux x86_64 artifact and a Linux arm64 artifact, then
      # ask only for macOS targets — none of the planted files match.
      burrito_out =
        setup_burrito_out(
          [
            "code_puppy_control_linux_x86_64",
            "code_puppy_control_linux_arm64"
          ],
          "stale"
        )

      assert {:skip, reason, metrics} =
               Phases.probe_burrito_dir(burrito_out, ["macos_arm64"])

      assert reason =~ "no host-compatible",
             "skip reason should explain why no artifact was selected; got: #{reason}"

      assert reason =~ "macos_arm64",
             "skip reason should list what we looked for; got: #{reason}"

      assert reason =~ "build host-only",
             "skip reason should give a remediation hint; got: #{reason}"

      assert metrics.candidates == ["macos_arm64"]
      assert metrics.burrito_dir == burrito_out
    end

    test "does not pick up a foreign code_puppy_control_* file even if it is the only artifact" do
      # The OLD `list_any_burrito_binary/1` fallback would happily return
      # this single file regardless of host.  The new selector must NOT.
      burrito_out =
        setup_burrito_out(["code_puppy_control_windows_x86_64"], "single_foreign")

      assert {:skip, _reason, metrics} =
               Phases.probe_burrito_dir(burrito_out, ["macos_arm64", "macos_x86_64"])

      assert metrics.candidates == ["macos_arm64", "macos_x86_64"]
    end

    test "ignores files whose names do not start with the code_puppy_control_ prefix" do
      # Defence in depth: even if a candidate target's name happened to
      # collide with an unrelated file, the selector only constructs the
      # canonical `code_puppy_control_<target>` path and probes that.
      burrito_out =
        setup_burrito_out(
          [
            "README.md",
            "code_puppy_control_macos_arm64.bak",
            "macos_arm64"
          ],
          "junk"
        )

      assert {:skip, _reason, _metrics} =
               Phases.probe_burrito_dir(burrito_out, ["macos_arm64"])
    end

    test "selects the matching host artifact when present" do
      burrito_out =
        setup_burrito_out(["code_puppy_control_macos_arm64"], "match_host")

      expected = Path.join(burrito_out, "code_puppy_control_macos_arm64")

      assert {:ok, ^expected} =
               Phases.probe_burrito_dir(burrito_out, ["macos_arm64", "macos_x86_64"])
    end

    test "prefers the primary candidate when multiple compatible artifacts exist" do
      # Linux glibc x86_64: candidates are [linux_x86_64, linux_musl_x86_64].
      # When BOTH are present, we must pick the glibc one (primary) so
      # we exercise the same artifact operators get on a glibc system.
      burrito_out =
        setup_burrito_out(
          [
            "code_puppy_control_linux_x86_64",
            "code_puppy_control_linux_musl_x86_64"
          ],
          "prefer_primary"
        )

      expected = Path.join(burrito_out, "code_puppy_control_linux_x86_64")

      assert {:ok, ^expected} =
               Phases.probe_burrito_dir(
                 burrito_out,
                 ["linux_x86_64", "linux_musl_x86_64"]
               )
    end

    test "falls back to musl artifact on a glibc Linux host when glibc artifact is missing" do
      # Linux glibc x86_64 host with only the musl build present — the
      # musl static binary is runnable on glibc systems, so accept it
      # rather than skipping.
      burrito_out =
        setup_burrito_out(["code_puppy_control_linux_musl_x86_64"], "musl_fallback")

      expected = Path.join(burrito_out, "code_puppy_control_linux_musl_x86_64")

      assert {:ok, ^expected} =
               Phases.probe_burrito_dir(
                 burrito_out,
                 ["linux_x86_64", "linux_musl_x86_64"]
               )
    end

    test "skips a candidate path that exists but is a directory (not a regular file)" do
      tmp = Path.join(System.tmp_dir!(), "pup_burrito_d7m_dir_#{unique()}")
      burrito_out = Path.join(tmp, "burrito_out")
      File.mkdir_p!(Path.join(burrito_out, "code_puppy_control_macos_arm64"))
      on_exit(fn -> File.rm_rf(tmp) end)

      assert {:skip, _reason, _metrics} =
               Phases.probe_burrito_dir(burrito_out, ["macos_arm64"])
    end

    # Headline regression for the shepherd note on code_puppy-d7m:
    # Burrito emits `code_puppy_control_windows_x86_64.exe` (with the
    # `.exe` suffix) on Windows builds.  The OLD selector probed only
    # the bare `code_puppy_control_windows_x86_64` path, which meant a
    # host-Windows smoke runner could NEVER select the real artifact
    # and would silently `:skip` the burrito phase.  This test plants
    # the actual on-disk filename and asserts the selector finds it.
    #
    # NOTE: we never `System.cmd` the planted file — `probe_burrito_dir/2`
    # only inspects via `File.regular?`, so a tiny non-executable payload
    # is sufficient and there is no risk of executing an invalid binary.
    test "selects the .exe artifact for a windows_* target (regression code_puppy-d7m)" do
      burrito_out =
        setup_burrito_out(["code_puppy_control_windows_x86_64.exe"], "windows_exe")

      expected = Path.join(burrito_out, "code_puppy_control_windows_x86_64.exe")

      assert {:ok, ^expected} =
               Phases.probe_burrito_dir(burrito_out, ["windows_x86_64"]),
             "probe_burrito_dir/2 must match the `.exe`-suffixed Burrito artifact " <>
               "for windows_* targets so host-Windows smoke runs do not silently skip"
    end

    # Defensive lock-in: do NOT regress to a permissive bare-name
    # fallback for Windows targets.  If a stray non-`.exe` file with the
    # canonical prefix appears in `burrito_out/` (a stale rename, an
    # editor swap file, anything), the selector must keep skipping rather
    # than handing a non-Burrito payload to `probe_packaged_cli/2`.
    test "does NOT match a bare-name file when probing a windows_* target (regression code_puppy-d7m)" do
      burrito_out =
        setup_burrito_out(["code_puppy_control_windows_x86_64"], "windows_bare_only")

      assert {:skip, reason, metrics} =
               Phases.probe_burrito_dir(burrito_out, ["windows_x86_64"])

      assert reason =~ "no host-compatible",
             "skip reason should explain why no `.exe` artifact was found; got: #{reason}"

      assert reason =~ "windows_x86_64",
             "skip reason should list the requested target; got: #{reason}"

      assert metrics.candidates == ["windows_x86_64"]
    end

    # Cohabitation case: when both the real `.exe` and a stray bare-name
    # file are present, the selector picks the `.exe` (the actual Burrito
    # output), not whichever one happens to sort first on disk.
    test "prefers the .exe artifact over a bare-name sibling for a windows_* target" do
      burrito_out =
        setup_burrito_out(
          [
            "code_puppy_control_windows_x86_64",
            "code_puppy_control_windows_x86_64.exe"
          ],
          "windows_both"
        )

      expected = Path.join(burrito_out, "code_puppy_control_windows_x86_64.exe")

      assert {:ok, ^expected} =
               Phases.probe_burrito_dir(burrito_out, ["windows_x86_64"])
    end

    # Negative parity: non-Windows targets must NOT match a `.exe`-
    # suffixed file even if one is planted.  This guards against an
    # over-permissive selector that probes `.exe` for every target.
    test "does NOT match a .exe sibling when probing a non-windows target" do
      burrito_out =
        setup_burrito_out(["code_puppy_control_macos_arm64.exe"], "macos_exe_only")

      assert {:skip, _reason, metrics} =
               Phases.probe_burrito_dir(burrito_out, ["macos_arm64"])

      assert metrics.candidates == ["macos_arm64"]
    end
  end

  describe "candidate_filenames/1" do
    test "appends `.exe` for windows_* targets" do
      assert Phases.candidate_filenames("windows_x86_64") ==
               ["code_puppy_control_windows_x86_64.exe"]
    end

    test "returns the bare name for non-windows targets" do
      for target <- [
            "macos_arm64",
            "macos_x86_64",
            "linux_arm64",
            "linux_x86_64",
            "linux_musl_arm64",
            "linux_musl_x86_64"
          ] do
        assert Phases.candidate_filenames(target) == ["code_puppy_control_#{target}"],
               "non-windows target #{inspect(target)} must NOT receive a .exe suffix"
      end
    end
  end

  describe "host_compatible_targets/0" do
    test "returns a non-empty list of recognised target names on supported hosts" do
      targets = Phases.host_compatible_targets()
      assert is_list(targets)

      # Every returned target must be one of the names configured in
      # mix.exs.  Hardcoded here on purpose so a typo in the selector
      # is caught immediately.
      known =
        MapSet.new([
          "macos_arm64",
          "macos_x86_64",
          "linux_arm64",
          "linux_x86_64",
          "linux_musl_arm64",
          "linux_musl_x86_64",
          "windows_x86_64"
        ])

      for target <- targets do
        assert target in known,
               "host_compatible_targets/0 returned unknown target #{inspect(target)}; " <>
                 "must be one of #{inspect(MapSet.to_list(known))}"
      end

      # Most CI hosts we care about are recognised.  An empty list is
      # only valid on truly exotic hosts; if a smoke runner ever returns
      # [] we want the selector to skip cleanly (covered above).
      case :os.type() do
        {:unix, _} -> assert targets != [], "expected unix host detection to succeed"
        {:win32, _} -> assert targets == ["windows_x86_64"]
      end
    end

    test "primary candidate matches the host family" do
      [primary | _] = Phases.host_compatible_targets()

      case :os.type() do
        {:win32, _} ->
          assert primary == "windows_x86_64"

        {:unix, _} ->
          arch = :erlang.system_info(:system_architecture) |> List.to_string()

          cond do
            String.contains?(arch, "apple") ->
              assert String.starts_with?(primary, "macos_")

            String.contains?(arch, "-musl") ->
              assert String.starts_with?(primary, "linux_musl_")

            true ->
              assert String.starts_with?(primary, "linux_")
              refute String.starts_with?(primary, "linux_musl_")
          end
      end
    end
  end
end
