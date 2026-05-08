defmodule CodePuppyControl.Config.DoctorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Doctor, Paths}

  setup do
    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")
      Process.delete(:isolation_sandbox)
    end)

    :ok
  end

  # ── Check struct ────────────────────────────────────────────────────────

  describe "check struct" do
    test "all checks return a map with name, status, detail" do
      # Ensure home exists for doctor checks
      tmp_home = Path.join(System.tmp_dir!(), "doctor_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.mkdir_p!(tmp_home)
      Paths.ensure_dirs!()

      checks = Doctor.run_checks()

      for check <- checks do
        assert Map.has_key?(check, :name)
        assert Map.has_key?(check, :status)
        assert Map.has_key?(check, :detail)
        assert check.status in [:pass, :warn, :fail, :info]
        assert is_binary(check.name)
        assert is_binary(check.detail)
      end

      File.rm_rf(tmp_home)
    end
  end

  # ── Healthy environment ────────────────────────────────────────────────

  describe "healthy environment" do
    test "run_checks/0 returns all :pass or :info when healthy" do
      tmp_home = Path.join(System.tmp_dir!(), "doctor_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.mkdir_p!(tmp_home)
      Paths.ensure_dirs!()

      # Write .initialized marker so FirstRun check reports info
      marker = Path.join(tmp_home, ".initialized")
      File.write!(marker, DateTime.utc_now() |> DateTime.to_iso8601())

      checks = Doctor.run_checks()

      # No checks should :fail in a healthy environment
      failures = Enum.filter(checks, &(&1.status == :fail))
      assert failures == [], "Unexpected failures: #{inspect(failures)}"

      # All should be :pass or :info (warnings are advisory)
      for check <- checks do
        assert check.status in [:pass, :info, :warn],
               "Check #{check.name} has unexpected status #{check.status}: #{check.detail}"
      end

      File.rm_rf(tmp_home)
    end
  end

  # ── Isolation probe ────────────────────────────────────────────────────

  describe "isolation probe" do
    test "correctly reports :pass (the guard raises as expected)" do
      tmp_home = Path.join(System.tmp_dir!(), "doctor_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.mkdir_p!(tmp_home)
      Paths.ensure_dirs!()

      checks = Doctor.run_checks()

      guard_check = Enum.find(checks, &String.contains?(&1.name, "Isolation guard"))
      assert guard_check != nil
      assert guard_check.status == :pass

      File.rm_rf(tmp_home)
    end
  end

  # ── Paths audit ────────────────────────────────────────────────────────

  describe "paths audit" do
    test "correctly iterates every Paths.* function" do
      tmp_home = Path.join(System.tmp_dir!(), "doctor_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.mkdir_p!(tmp_home)
      Paths.ensure_dirs!()

      checks = Doctor.run_checks()

      paths_check = Enum.find(checks, &String.contains?(&1.name, "Paths.*"))
      assert paths_check != nil

      # Extract the count from the name (e.g., "All 15 Paths.* functions...")
      assert paths_check.status == :pass

      # Verify the count matches the module's public API
      excluded = [:legacy_home_dir, :project_policy_file, :project_agents_dir, :ensure_dirs!]

      expected_count =
        Paths.__info__(:functions)
        |> Enum.filter(fn {_name, arity} -> arity == 0 end)
        |> Enum.reject(fn {name, _arity} -> name in excluded end)
        |> length()

      # The check name should contain the count
      assert paths_check.name =~ Integer.to_string(expected_count)

      File.rm_rf(tmp_home)
    end

    test "audit count assertion" do
      # Explicitly verify we're discovering all the path functions
      excluded = [:legacy_home_dir, :project_policy_file, :project_agents_dir, :ensure_dirs!]

      zero_arity_fns =
        Paths.__info__(:functions)
        |> Enum.filter(fn {_name, arity} -> arity == 0 end)

      audited_fns =
        zero_arity_fns
        |> Enum.reject(fn {name, _arity} -> name in excluded end)

      # We should have a reasonable number of path functions
      # (as of this writing: ~17, but the exact count may grow)
      assert length(audited_fns) >= 10,
             "Expected at least 10 path functions, got #{length(audited_fns)}"

      # None of the excluded functions should be in the audit
      audited_names = Enum.map(audited_fns, fn {n, _} -> n end)
      refute :legacy_home_dir in audited_names
      refute :project_policy_file in audited_names
      refute :project_agents_dir in audited_names
      refute :ensure_dirs! in audited_names
    end
  end

  # ── exit_code/1 ────────────────────────────────────────────────────────

  describe "exit_code/1" do
    test "returns 0 when all checks are :pass or :info" do
      checks = [
        %{name: "test1", status: :pass, detail: ""},
        %{name: "test2", status: :info, detail: "note"}
      ]

      assert Doctor.exit_code(checks) == 0
    end

    test "returns 1 when any check is :fail" do
      checks = [
        %{name: "test1", status: :pass, detail: ""},
        %{name: "test2", status: :fail, detail: "broken"}
      ]

      assert Doctor.exit_code(checks) == 1
    end

    test "returns 0 when checks have :warn but no :fail" do
      checks = [
        %{name: "test1", status: :pass, detail: ""},
        %{name: "test2", status: :warn, detail: "advisory"}
      ]

      assert Doctor.exit_code(checks) == 0
    end
  end

  # ── format_report/1 ────────────────────────────────────────────────────

  describe "format_report/1" do
    test "output contains ✅ for :pass checks" do
      checks = [%{name: "Good check", status: :pass, detail: "all good"}]
      report = Doctor.format_report(checks)
      assert report =~ "✅"
      assert report =~ "Good check"
    end

    test "output contains ℹ️ for :info checks" do
      checks = [%{name: "Info check", status: :info, detail: "fyi"}]
      report = Doctor.format_report(checks)
      assert report =~ "ℹ️"
      assert report =~ "Info check"
    end

    test "output contains ❌ for :fail checks" do
      checks = [%{name: "Bad check", status: :fail, detail: "broken"}]
      report = Doctor.format_report(checks)
      assert report =~ "❌"
      assert report =~ "COMPROMISED"
    end

    test "output shows ISOLATED when no failures" do
      checks = [%{name: "OK", status: :pass, detail: ""}]
      report = Doctor.format_report(checks)
      assert report =~ "ISOLATED ✅"
    end
  end

  # ── Failure detection ──────────────────────────────────────────────────

  describe "failure detection" do
    test "detects missing Elixir home" do
      nonexistent =
        Path.join(System.tmp_dir!(), "no_such_doctor_#{:erlang.unique_integer([:positive])}")

      System.put_env("PUP_EX_HOME", nonexistent)
      File.rm_rf(nonexistent)

      checks = Doctor.run_checks()
      home_check = Enum.find(checks, &String.contains?(&1.name, "Elixir home exists"))

      assert home_check != nil
      assert home_check.status == :fail

      File.rm_rf(nonexistent)
    end
  end
end
