defmodule CodePuppyControl.Config.IsolationGatesTest do
  @moduledoc """
  The 5 CI gates from ADR-003 Dual-Home Config Isolation.
  All 5 MUST pass for acceptance.

  GATE-1: No-write — full pup-ex operations write ZERO bytes to ~/.code_puppy/
  GATE-2: Guard raises — safe_write! on legacy paths raises IsolationViolation
  GATE-3: Import opt-in — no auto-copy without --confirm
  GATE-4: Doctor passes — fresh Elixir home gets ✅
  GATE-5: Paths audit — no Paths.*_dir/file function resolves under legacy home
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Paths, Isolation, Importer, Doctor, FirstRun}

  @home Path.expand("~")

  # ── Setup / Teardown ───────────────────────────────────────────────────

  setup do
    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")
      Process.delete(:isolation_sandbox)
    end)

    :ok
  end

  # ── GATE-1: No-write to legacy home under realistic operations ──────────

  describe "GATE-1: no-write to legacy home under realistic operations" do
    test "zero bytes written to legacy home after representative operations" do
      # Unique temp dirs for this test run.
      #
      # CRITICAL: The fake legacy home MUST be under the REAL ~/.code_puppy/
      # so that Isolation.in_legacy_home?/1 detects it and the guard blocks
      # writes. Using /tmp/... would bypass the guard entirely.
      test_id = :erlang.unique_integer([:positive])
      pup_ex_home = Path.join(System.tmp_dir!(), "gate1_ex_#{test_id}")
      fake_legacy = Path.join(Paths.legacy_home_dir(), "_gate1_test_#{test_id}")

      System.put_env("PUP_EX_HOME", pup_ex_home)
      File.rm_rf(pup_ex_home)
      File.rm_rf(fake_legacy)

      try do
        # ── Step 1: Populate fake legacy home with fixture files ──────────
        #
        # We use with_sandbox to lift the guard ONLY while we create the
        # fixture files inside the fake legacy home. Once populated, we
        # exit the sandbox so the guard is active again for the real test.
        Isolation.with_sandbox([fake_legacy], fn ->
          populate_legacy_fixture(fake_legacy)
        end)

        # ── Step 2: Snapshot the legacy home BEFORE operations ───────────
        before_snapshot = snapshot_directory(fake_legacy)

        # ── Step 3: Run representative pup-ex operations ─────────────────

        # 3a. FirstRun.initialize/0 — creates the Elixir home tree
        Isolation.with_sandbox([pup_ex_home], fn ->
          assert {:ok, _} = FirstRun.initialize()
        end)

        # 3b. Isolation.safe_write!/2 to a path under PUP_EX_HOME
        test_file = Path.join(pup_ex_home, "gate1_write_test.txt")

        Isolation.with_sandbox([pup_ex_home], fn ->
          assert :ok = Isolation.safe_write!(test_file, "gate1 data")
        end)

        # 3c. Isolation.safe_mkdir_p!/1 under PUP_EX_HOME
        test_dir = Path.join(pup_ex_home, "gate1_mkdir_test")

        Isolation.with_sandbox([pup_ex_home], fn ->
          assert :ok = Isolation.safe_mkdir_p!(test_dir)
        end)

        # 3d. Run Doctor — exercises path resolution + guard probing
        # Doctor itself calls safe_write! on a legacy path (probe),
        # which raises IsolationViolation — that's expected. The
        # Doctor catches the violation and reports :pass. This is a
        # realistic operation that exercises the full guard stack.
        checks = Doctor.run_checks()
        # We don't assert Doctor outcomes here — the point is that
        # Doctor must NOT write to the legacy home while running.
        _ = checks

        # 3e. Attempt a guarded write to legacy home (must raise).
        # The rescue must NOT leave a file behind.
        assert_raise Isolation.IsolationViolation, fn ->
          Isolation.safe_write!(
            Path.join(fake_legacy, "must_not_exist.txt"),
            "forbidden"
          )
        end

        # 3f. Run Importer in dry-run mode — must not write anything
        # to the fake legacy home (or anywhere).
        result = Importer.run(__legacy_home__: fake_legacy)
        assert result.mode == :dry_run

        # ── Step 4: Snapshot the legacy home AFTER operations ────────────
        after_snapshot = snapshot_directory(fake_legacy)

        # ── Step 5: Assert byte-for-byte identical ───────────────────────
        assert before_snapshot == after_snapshot,
               "GATE-1 FAILED: legacy home was mutated!\n" <>
                 "Before: #{inspect(before_snapshot)}\n" <>
                 "After: #{inspect(after_snapshot)}"
      after
        File.rm_rf(pup_ex_home)
        File.rm_rf(fake_legacy)
      end
    end

    test "guarded write attempt leaves no partial file in legacy home" do
      test_id = :erlang.unique_integer([:positive])
      # Must be under real ~/.code_puppy/ so the guard blocks it
      fake_legacy = Path.join(Paths.legacy_home_dir(), "_gate1_partial_#{test_id}")
      File.rm_rf(fake_legacy)

      try do
        # Populate a fixture using sandbox
        Isolation.with_sandbox([fake_legacy], fn ->
          populate_legacy_fixture(fake_legacy)
        end)

        before_snapshot = snapshot_directory(fake_legacy)

        # Attempt a write that should be blocked
        assert_raise Isolation.IsolationViolation, fn ->
          Isolation.safe_write!(
            Path.join(fake_legacy, "partial_file.txt"),
            "should not appear"
          )
        end

        after_snapshot = snapshot_directory(fake_legacy)

        assert before_snapshot == after_snapshot,
               "GATE-1 partial-write check FAILED: legacy home changed after blocked write"
      after
        File.rm_rf(fake_legacy)
      end
    end
  end

  # ── GATE-2: Guard raises on legacy-home writes ──────────────────────────

  describe "GATE-2: guard raises on legacy-home writes" do
    test "safe_write! to legacy home raises IsolationViolation" do
      legacy_path = Path.join(@home, ".code_puppy/gate2_test_file")

      assert_raise Isolation.IsolationViolation, fn ->
        Isolation.safe_write!(legacy_path, "gate2 data")
      end
    end

    test "safe_mkdir_p! to legacy home raises IsolationViolation" do
      legacy_path = Path.join(@home, ".code_puppy/gate2_test_dir")

      assert_raise Isolation.IsolationViolation, fn ->
        Isolation.safe_mkdir_p!(legacy_path)
      end
    end
  end

  # ── GATE-3: Import requires --confirm ──────────────────────────────────

  describe "GATE-3: import requires --confirm" do
    test "Importer.run without :confirm produces dry_run and writes zero files" do
      test_id = :erlang.unique_integer([:positive])
      pup_ex_home = Path.join(System.tmp_dir!(), "gate3_ex_#{test_id}")
      fake_legacy = Path.join(System.tmp_dir!(), "gate3_legacy_#{test_id}")

      System.put_env("PUP_EX_HOME", pup_ex_home)
      File.rm_rf(pup_ex_home)
      File.rm_rf(fake_legacy)

      try do
        # Set up a populated legacy home and an empty Elixir home
        Isolation.with_sandbox([fake_legacy], fn ->
          populate_legacy_fixture(fake_legacy)
        end)

        Isolation.with_sandbox([pup_ex_home], fn ->
          File.mkdir_p!(pup_ex_home)
        end)

        # Snapshot Elixir home before import
        ex_before = snapshot_directory(pup_ex_home)

        # Run import WITHOUT :confirm
        result = Importer.run(__legacy_home__: fake_legacy)

        # Must be dry_run mode
        assert result.mode == :dry_run

        # Elixir home must be unchanged (no files written)
        ex_after = snapshot_directory(pup_ex_home)

        assert ex_before == ex_after,
               "GATE-3 FAILED: import without --confirm wrote files to Elixir home"
      after
        File.rm_rf(pup_ex_home)
        File.rm_rf(fake_legacy)
      end
    end
  end

  # ── GATE-4: Doctor reports ISOLATED on a healthy environment ────────────

  describe "GATE-4: doctor reports ISOLATED on a healthy environment" do
    test "Doctor.run_checks/0 has no :fail statuses and exit_code is 0" do
      test_id = :erlang.unique_integer([:positive])
      pup_ex_home = Path.join(System.tmp_dir!(), "gate4_ex_#{test_id}")

      System.put_env("PUP_EX_HOME", pup_ex_home)
      File.rm_rf(pup_ex_home)

      try do
        # Set up a fresh Elixir home
        Isolation.with_sandbox([pup_ex_home], fn ->
          File.mkdir_p!(pup_ex_home)
          Paths.ensure_dirs!()

          # Write .initialized marker so FirstRun check reports cleanly
          marker = Path.join(pup_ex_home, ".initialized")
          File.write!(marker, DateTime.utc_now() |> DateTime.to_iso8601())
        end)

        checks = Doctor.run_checks()

        # No :fail statuses
        failures = Enum.filter(checks, &(&1.status == :fail))

        assert failures == [],
               "GATE-4 FAILED: doctor found failures: #{inspect(failures)}"

        # Exit code must be 0
        assert Doctor.exit_code(checks) == 0,
               "GATE-4 FAILED: doctor exit_code was not 0"
      after
        File.rm_rf(pup_ex_home)
      end
    end
  end

  # ── GATE-5: Every Paths.* function resolves under Elixir home ──────────

  describe "GATE-5: every Paths.*_dir/file function resolves under Elixir home" do
    test "all 0-arity _dir/_file functions resolve under Paths.home_dir()" do
      test_id = :erlang.unique_integer([:positive])
      pup_ex_home = Path.join(System.tmp_dir!(), "gate5_ex_#{test_id}")

      System.put_env("PUP_EX_HOME", pup_ex_home)

      try do
        elixir_home = Paths.home_dir()
        assert elixir_home == pup_ex_home

        # Explicitly enumerate every 0-arity function whose name ends in
        # _dir or _file. Skip legacy_home_dir/0 (by definition returns
        # legacy path) and project_* (resolves relative to CWD, not home).
        excluded = [:legacy_home_dir, :project_policy_file, :project_agents_dir]

        path_fns =
          Paths.__info__(:functions)
          |> Enum.filter(fn {name, arity} ->
            arity == 0 and
              (String.ends_with?(Atom.to_string(name), "_dir") or
                 String.ends_with?(Atom.to_string(name), "_file"))
          end)
          |> Enum.reject(fn {name, _arity} -> name in excluded end)

        # There must be at least a reasonable number of path functions.
        # This guards against accidentally filtering all of them out.
        assert length(path_fns) >= 10,
               "GATE-5: expected >= 10 audited path functions, got #{length(path_fns)}"

        for {name, 0} <- path_fns do
          resolved = apply(Paths, name, [])

          assert is_binary(resolved),
                 "GATE-5: Paths.#{name}/0 returned non-string: #{inspect(resolved)}"

          # The path must resolve under (or equal) the Elixir home.
          # When no XDG vars are set, some *_dir functions return the
          # home root itself (e.g. cache_dir → home_dir). Both cases are
          # valid — the key invariant is that the path is within the
          # Elixir home tree, never the legacy tree.
          assert resolved == elixir_home or
                   String.starts_with?(resolved, elixir_home <> "/"),
                 "GATE-5: Paths.#{name}/0 → #{resolved} is NOT under #{elixir_home}"

          # Must NOT resolve under the legacy home
          refute Paths.in_legacy_home?(resolved),
                 "GATE-5: Paths.#{name}/0 → #{resolved} resolves under legacy home!"
        end
      after
        File.rm_rf(pup_ex_home)
      end
    end

    test "regression tripwire: new _dir/_file functions cannot be added without this test knowing" do
      # Count all 0-arity _dir/_file functions (excluding known exceptions).
      # If someone adds a new one, this count changes and the test fails,
      # forcing them to add it to the GATE-5 audit above.
      excluded = [:legacy_home_dir, :project_policy_file, :project_agents_dir]

      audited_count =
        Paths.__info__(:functions)
        |> Enum.filter(fn {name, arity} ->
          arity == 0 and
            (String.ends_with?(Atom.to_string(name), "_dir") or
               String.ends_with?(Atom.to_string(name), "_file"))
        end)
        |> Enum.reject(fn {name, _arity} -> name in excluded end)
        |> length()

      # Update this number when you add a new audited function intentionally.
      # This test is the tripwire that catches accidental additions.
      expected_count = 21

      assert audited_count == expected_count,
             "GATE-5 tripwire: found #{audited_count} _dir/_file functions, " <>
               "expected #{expected_count}. " <>
               "If you added a new Paths.* function, update expected_count in this test."
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp populate_legacy_fixture(legacy_dir) do
    File.mkdir_p!(legacy_dir)

    # puppy.cfg — common Python pup config
    File.write!(
      Path.join(legacy_dir, "puppy.cfg"),
      "[puppy]\nmodel = gpt-4o\napi_key = sk-secret\n\n[ui]\ntheme = dark\n"
    )

    # models.json — model registry
    File.write!(
      Path.join(legacy_dir, "models.json"),
      Jason.encode!(%{"models" => [%{"id" => "gpt-4o", "provider" => "openai"}]})
    )

    # extra_models.json — user-added models
    File.write!(
      Path.join(legacy_dir, "extra_models.json"),
      Jason.encode!(%{"my-model" => %{"provider" => "anthropic"}})
    )

    # agents/ — agent definitions
    agents_dir = Path.join(legacy_dir, "agents")
    File.mkdir_p!(agents_dir)

    File.write!(
      Path.join(agents_dir, "default.json"),
      Jason.encode!(%{"name" => "default", "model" => "gpt-4o"})
    )

    # skills/ — skill definitions
    skills_dir = Path.join(legacy_dir, "skills")
    skill_dir = Path.join(skills_dir, "my_skill")
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "# My Skill\n\nA test skill for gate verification.\n"
    )

    # Forbidden files — these should never be touched or imported
    File.write!(
      Path.join(legacy_dir, "oauth_token.json"),
      Jason.encode!(%{"access_token" => "secret_token_123"})
    )

    sessions_dir = Path.join(legacy_dir, "sessions")
    File.mkdir_p!(sessions_dir)

    File.write!(
      Path.join(sessions_dir, "session_1.json"),
      Jason.encode!(%{"id" => "sess_1", "state" => "active"})
    )

    File.write!(
      Path.join(legacy_dir, "command_history.txt"),
      "help\nimport\ndoctor\n"
    )

    File.write!(
      Path.join(legacy_dir, "dbos_store.sqlite"),
      "fake_binary_sqlite_data"
    )

    :ok
  end

  # Snapshot a directory tree by hashing all file contents.
  #
  # Returns a sorted list of `{relative_path, sha256_hex}` tuples.
  # If the directory doesn't exist, returns `[]`.
  # Two snapshots are equal iff the directory is byte-for-byte identical.
  defp snapshot_directory(dir) do
    if not File.dir?(dir) do
      []
    else
      dir
      |> walk_tree("")
      |> Enum.sort()
    end
  end

  defp walk_tree(root, prefix) do
    dir = if prefix == "", do: root, else: Path.join(root, prefix)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          rel = if prefix == "", do: entry, else: "#{prefix}/#{entry}"
          full = Path.join(dir, entry)

          cond do
            File.dir?(full) ->
              walk_tree(root, rel)

            File.regular?(full) ->
              case File.read(full) do
                {:ok, content} ->
                  hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
                  [{rel, hash}]

                {:error, _} ->
                  [{rel, :unreadable}]
              end

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
