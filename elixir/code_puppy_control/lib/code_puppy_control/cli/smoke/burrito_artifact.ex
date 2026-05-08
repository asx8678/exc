defmodule CodePuppyControl.CLI.Smoke.BurritoArtifact do
  @moduledoc """
  Burrito artifact-selection helpers for the packaged-CLI smoke runner.

  Split out of `CodePuppyControl.CLI.Smoke.Phases` to keep that module
  under the 600-line cap.  All public functions here preserve their
  previous behaviour exactly; `Phases` re-exports the public ones via
  `defdelegate/2` so existing callers (and the regression test in
  `test/code_puppy_control/cli/smoke/burrito_artifact_test.exs`) keep
  working unchanged.

  The contract being locked in (regression code_puppy-d7m):

    * `find_burrito_artifact/0` MUST NOT fall back to an arbitrary
      `burrito_out/code_puppy_control_*` regular file.  Probing a
      cross-compiled sibling that cannot exec on the smoke host
      produces a confusing `:fail` (or, on Linux trying to exec a
      Mach-O, a hang) when the correct outcome is `:skip` with a
      remediation hint.

    * Only artifacts in `host_compatible_targets/0` are considered
      runnable.  Linux glibc hosts MAY accept the matching musl
      artifact as a secondary fallback; pure-musl hosts (Alpine)
      accept ONLY the musl artifact.

    * Windows targets resolve to `<release>_<target>.exe` — the actual
      filename Burrito emits.  Non-Windows targets resolve to the
      bare `<release>_<target>` filename.  No bare-name fallback for
      Windows; no `.exe` match for non-Windows.

  Refs: code_puppy-d7m
  """

  @typedoc """
  Outcome of `probe_burrito_dir/2` / `find_burrito_artifact/0`.

  * `{:ok, path}`        — verified host-compatible regular file
  * `{:skip, reason, m}` — no compatible artifact; phase should skip
  """
  @type probe_result :: {:ok, String.t()} | {:skip, String.t(), map()}

  # ── find_burrito_artifact/0 ────────────────────────────────────────────

  @doc """
  Locate a Burrito-built binary that is **runnable on the smoke host**.

  Inspects the project-relative `burrito_out/` directory and returns
  the first artifact whose target name appears in
  `host_compatible_targets/0`.  Returns `{:skip, reason, metrics}`
  with an operator-friendly remediation hint when no compatible
  artifact is present, so the `:burrito` smoke phase can skip
  deterministically on hosts without a Zig toolchain.

  IMPORTANT (regression code_puppy-d7m): we MUST NOT fall back to an
  arbitrary `burrito_out/code_puppy_control_*` regular file.  Only
  artifacts in `host_compatible_targets/0` are probed.
  """
  @spec find_burrito_artifact() :: probe_result()
  def find_burrito_artifact do
    burrito_dir = Path.join(File.cwd!(), "burrito_out")
    probe_burrito_dir(burrito_dir, host_compatible_targets())
  end

  # ── probe_burrito_dir/2 ────────────────────────────────────────────────

  @doc """
  Public-but-undocumented entry point so the regression test can drive
  the artifact-selection logic with a synthetic `burrito_out/` and a
  fixed candidate list, without changing the working directory or
  assuming anything about the test runner's host.

  Refs: code_puppy-d7m
  """
  @spec probe_burrito_dir(String.t(), [String.t()]) :: probe_result()
  def probe_burrito_dir(burrito_dir, candidate_targets)
      when is_binary(burrito_dir) and is_list(candidate_targets) do
    cond do
      not File.dir?(burrito_dir) ->
        {:skip,
         "no `burrito_out/` directory — build host-only with " <>
           "`scripts/build-burrito.sh --host-only` (requires Zig)", %{burrito_dir: burrito_dir}}

      candidate_targets == [] ->
        {:skip,
         "could not detect a host-compatible Burrito target for #{host_id()} — " <>
           "phase requires one of the targets configured in mix.exs; " <>
           "build host-only with `scripts/build-burrito.sh --host-only`",
         %{burrito_dir: burrito_dir, candidates: candidate_targets}}

      true ->
        case probe_candidates(burrito_dir, candidate_targets) do
          {:ok, path} ->
            {:ok, path}

          :none ->
            {:skip,
             "no host-compatible `code_puppy_control_*` artifact in #{burrito_dir} " <>
               "(looked for: #{Enum.join(candidate_targets, ", ")}) — " <>
               "build host-only with `scripts/build-burrito.sh --host-only`",
             %{burrito_dir: burrito_dir, candidates: candidate_targets}}
        end
    end
  end

  # Walk `candidate_targets` in priority order; return the first path that
  # exists as a regular file under `burrito_dir`.
  defp probe_candidates(_burrito_dir, []), do: :none

  defp probe_candidates(burrito_dir, [target | rest]) do
    case probe_target(burrito_dir, target) do
      {:ok, _path} = ok -> ok
      :none -> probe_candidates(burrito_dir, rest)
    end
  end

  # Probe the on-disk filename(s) Burrito actually produces for `target`
  # under `burrito_dir`.  Returns the first matching regular file or
  # `:none`.
  #
  # Refs: code_puppy-d7m
  defp probe_target(burrito_dir, target) do
    target
    |> candidate_filenames()
    |> Enum.find_value(:none, fn name ->
      path = Path.join(burrito_dir, name)
      if File.regular?(path), do: {:ok, path}, else: nil
    end)
  end

  # ── candidate_filenames/1 ──────────────────────────────────────────────

  @doc """
  On-disk filenames Burrito emits for `target` under `burrito_out/`.

  Burrito names the produced binary `<release>_<target>` on Unix and
  appends a `.exe` suffix for Windows targets — see
  `docs/burrito-release.md` ("Output Layout") and `mix.exs`.  We probe
  the `.exe` variant for `windows_*` targets so a host-Windows smoke
  run can actually find the artifact instead of silently skipping.

  We deliberately do NOT add a bare-name fallback for Windows targets:
  the strict host-compat contract (regression code_puppy-d7m) requires
  us to match only what Burrito actually emits, never an unrelated
  planted file with a colliding name.

  Refs: code_puppy-d7m
  """
  @spec candidate_filenames(String.t()) :: [String.t()]
  def candidate_filenames(target) when is_binary(target) do
    base = "code_puppy_control_#{target}"

    if String.starts_with?(target, "windows_") do
      [base <> ".exe"]
    else
      [base]
    end
  end

  # ── host_compatible_targets/0 ──────────────────────────────────────────

  @doc """
  Map the running BEAM host to an ordered list of Burrito target names
  (as configured in `mix.exs`) that are **runnable on this host**.

  First entry is the preferred match; later entries are acceptable
  fallbacks.  An empty list means we do not recognise the host and the
  phase MUST skip rather than guess.

  Linux musl handling: a glibc Linux host can typically execute a
  statically-linked musl Burrito binary, so we list the musl artifact
  as a secondary candidate after the matching glibc artifact.  A pure
  musl host (e.g. Alpine) cannot run glibc binaries, so we list ONLY
  the musl artifact for that case.

  Refs: code_puppy-d7m
  """
  @spec host_compatible_targets() :: [String.t()]
  def host_compatible_targets do
    {os_family, _os_name} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> List.to_string()
    musl? = String.contains?(arch, "-musl")

    case {os_family, arch, musl?} do
      {:win32, _, _} -> ["windows_x86_64"]
      {:unix, "aarch64-apple" <> _, _} -> ["macos_arm64"]
      {:unix, "arm64-apple" <> _, _} -> ["macos_arm64"]
      {:unix, "x86_64-apple" <> _, _} -> ["macos_x86_64"]
      {:unix, "aarch64" <> _, true} -> ["linux_musl_arm64"]
      {:unix, "x86_64" <> _, true} -> ["linux_musl_x86_64"]
      {:unix, "aarch64" <> _, false} -> ["linux_arm64", "linux_musl_arm64"]
      {:unix, "x86_64" <> _, false} -> ["linux_x86_64", "linux_musl_x86_64"]
      _ -> []
    end
  end

  # Short, log-friendly identifier for the current host, used only in
  # skip reasons so operators know why detection failed.
  defp host_id do
    {os_family, _} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> List.to_string()
    "#{os_family}/#{arch}"
  end
end
